"Repository rule for scanning and generating .bzl files from .csproj/.fsproj projects"

load("@bazel_lib//lib:glob_match.bzl", "glob_match")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":generator.bzl", "generate_defs_bzl", "generate_project_bzl", "generate_root_build_bazel", "generate_subdir_build_bazel")
load(":nuget_collector.bzl", "create_nuget_collector", "generate_nuget_packages_bzl", "generate_paket_dependencies")
load(":parser.bzl", "parse_project_file")
load(":path_utils.bzl", "resolve_relative_path")
load(":tfm_utils.bzl", "find_best_toolchain_for_tfms")

def _find_project_files(repository_ctx, workspace_dir, exclude_patterns):
    """Find all .csproj and .fsproj files in the workspace.

    Args:
        repository_ctx: The repository context.
        workspace_dir: Path to the workspace root.
        exclude_patterns: List of glob patterns to exclude.

    Returns:
        List of project file paths relative to workspace root.
    """

    project_files = []
    workspace_str = str(workspace_dir)
    pending_dirs = [repository_ctx.path(workspace_dir)]

    # Starlark does not support while loops, so we emulate a queue walk with
    # a bounded for-loop and break once all discovered directories are visited.
    for next_dir_index in range(1000000):
        if next_dir_index >= len(pending_dirs):
            break
        current_dir = pending_dirs[next_dir_index]
        entries = _sorted_path_entries(current_dir.readdir())
        for entry in entries:
            child = _as_path_obj(current_dir, entry)
            child_str = str(child)
            rel_raw = child_str[len(workspace_str):] if child_str.startswith(workspace_str) else child_str
            rel_path = _normalize_relative_path(rel_raw)
            if not rel_path:
                continue
            if _matches_exclude(rel_path, exclude_patterns):
                continue

            name = _path_entry_name(child)
            is_dir = hasattr(child, "is_dir") and child.is_dir
            if is_dir:
                if _is_pruned_dir_name(name):
                    continue
                pending_dirs.append(child)
                continue

            lower_name = name.lower()
            if lower_name.endswith(".csproj") or lower_name.endswith(".fsproj"):
                project_files.append(rel_path)

    return sorted(project_files)

def _normalize_relative_path(path):
    normalized = paths.normalize(path.replace("\\", "/"))
    if normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized.startswith("/"):
        normalized = normalized[1:]
    if not normalized or normalized == "." or normalized.startswith("../"):
        return None
    return normalized

def _path_entry_name(path_obj):
    if hasattr(path_obj, "basename"):
        return path_obj.basename
    text = str(path_obj).replace("\\", "/")
    if "/" in text:
        return text.rsplit("/", 1)[1]
    return text

def _as_path_obj(parent, entry):
    if type(entry) == "string":
        return parent.get_child(entry)
    return entry

def _sorted_path_entries(entries):
    by_key = {}
    keys = []
    for entry in entries:
        path_obj = _as_path_obj(None, entry) if type(entry) != "string" else entry
        key = str(path_obj if type(entry) != "string" else entry)
        by_key[key] = entry
        keys.append(key)
    sorted_entries = []
    for key in sorted(keys):
        sorted_entries.append(by_key[key])
    return sorted_entries

def _is_pruned_dir_name(name):
    return name in ["bin", "obj", ".git", ".jj"] or name.startswith("bazel-")

def _matches_exclude(path, patterns):
    """Check if a path matches any exclude pattern.

    Uses glob_match from bazel_lib for proper glob pattern matching.

    Args:
        path: The path to check.
        patterns: List of glob patterns.

    Returns:
        True if the path should be excluded.
    """
    for pattern in patterns:
        if glob_match(pattern, path):
            return True
    return False

def _project_dir(project_path):
    if "/" not in project_path:
        return ""
    return "/".join(project_path.split("/")[:-1])

def _project_stem(project_path):
    filename = project_path.split("/")[-1]
    return paths.split_extension(filename)[0]

def _project_path_to_label(project_path):
    project_dir = _project_dir(project_path)
    stem = _project_stem(project_path)
    if project_dir:
        return "//{}:{}".format(project_dir, stem)
    return ":{}".format(stem)

def _parse_paket_references_content(content):
    """Parse paket.references content into package IDs."""
    package_ids = []
    for raw_line in content.split("\n"):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        # Support either "Package.Id" or "nuget Package.Id ...".
        lower = line.lower()
        if lower.startswith("nuget "):
            tokens = [t for t in line.split(" ") if t]
            if len(tokens) >= 2:
                package_ids.append(tokens[1])
            continue

        if " " in line:
            # Ignore unsupported directives while keeping parser resilient.
            continue
        package_ids.append(line)
    return sorted(package_ids)

def _merge_package_references(package_refs, paket_ids):
    """Merge package references with paket.references package IDs."""
    by_id = {}
    for pkg in package_refs:
        normalized = pkg.id.lower()
        by_id[normalized] = struct(id = pkg.id, version = pkg.version)

    for paket_id in paket_ids:
        normalized = paket_id.lower()
        if normalized not in by_id:
            by_id[normalized] = struct(id = paket_id, version = "")

    merged = []
    for normalized in sorted(by_id.keys()):
        merged.append(by_id[normalized])
    return merged

def _normalize_assembly_name(name):
    if not name:
        return ""
    cleaned = name.strip()
    if not cleaned:
        return ""
    if "," in cleaned:
        cleaned = cleaned.split(",", 1)[0].strip()
    return cleaned.lower()

def _validate_diagnostics_mode(attr_name, mode):
    """Validate diagnostics mode.

    Args:
        attr_name: Attribute name for error messages.
        mode: Mode value from repository attrs.

    Returns:
        A validated diagnostics mode string.
    """
    if mode in ["off", "warn", "strict"]:
        return mode
    fail("{} must be one of: off, warn, strict (got: {})".format(attr_name, mode))

def _add_diagnostic(diagnostics, category, severity, message, project_path = "", remediation = ""):
    diagnostics.append({
        "category": category,
        "severity": severity,
        "project_path": project_path,
        "message": message,
        "remediation": remediation,
    })

def _record_policy_diagnostic(
        diagnostics,
        strict_failures,
        mode,
        category,
        message,
        project_path = "",
        remediation = "",
        strict_prefix = ""):
    """Record diagnostics according to policy mode."""
    if mode == "off":
        return

    severity = "error" if mode == "strict" else "warning"
    _add_diagnostic(diagnostics, category, severity, message, project_path, remediation)

    if mode == "strict":
        if strict_prefix:
            strict_failures.append("{}: {}".format(strict_prefix, message))
        else:
            strict_failures.append(message)
    elif mode == "warn":
        # buildifier: disable=print
        print("WARNING: {}".format(message))

def _diag_sort_key(diag):
    return "{}|{}|{}|{}".format(
        diag.get("project_path", ""),
        diag.get("category", ""),
        diag.get("severity", ""),
        diag.get("message", ""),
    )

def _sorted_diagnostics(diagnostics):
    """Return a deterministically sorted copy of diagnostics."""
    result = list(diagnostics)
    for i in range(len(result)):
        for j in range(i + 1, len(result)):
            if _diag_sort_key(result[i]) > _diag_sort_key(result[j]):
                result[i], result[j] = result[j], result[i]
    return result

def _render_diagnostics_markdown(sorted_diags):
    """Render human-readable diagnostics markdown."""
    md = [
        "# Diagnostics Report",
        "",
        "Generated by @dotnet_projects repository rule.",
        "",
    ]
    if not sorted_diags:
        md.extend([
            "No diagnostics.",
            "",
        ])
    else:
        for diag in sorted_diags:
            location = diag["project_path"] if diag["project_path"] else "(workspace)"
            md.append("- [{}] [{}] {}: {}".format(
                diag["severity"],
                diag["category"],
                location,
                diag["message"],
            ))
            if diag["remediation"]:
                md.append("  - remediation: {}".format(diag["remediation"]))
        md.append("")
    return "\n".join(md)

def _render_diagnostics_outputs(diagnostics):
    """Render deterministic diagnostics outputs.

    Returns:
        struct(json_content, markdown_content, sorted_diagnostics)
    """
    sorted_diags = _sorted_diagnostics(diagnostics)
    return struct(
        json_content = json.encode(sorted_diags),
        markdown_content = _render_diagnostics_markdown(sorted_diags),
        sorted_diagnostics = sorted_diags,
    )

def _apply_parser_errors(diagnostics, strict_failures, parser_mode, project_path, parse_errors):
    """Apply parser errors to diagnostics according to parser mode."""
    if parser_mode == "off":
        return
    severity = "error" if parser_mode == "strict" else "warning"
    for parse_error in parse_errors:
        if parser_mode == "warn":
            # buildifier: disable=print
            print("WARNING: Errors parsing {}: {}".format(project_path, parse_error))
        _add_diagnostic(
            diagnostics,
            "parser",
            severity,
            parse_error,
            project_path,
            "Fix malformed XML or unsupported project syntax.",
        )
        if parser_mode == "strict":
            strict_failures.append("Parser error in {}: {}".format(project_path, parse_error))

def _write_diagnostics_reports(repository_ctx, diagnostics):
    """Write machine- and human-readable diagnostics reports."""
    outputs = _render_diagnostics_outputs(diagnostics)
    repository_ctx.file("diagnostics.json", outputs.json_content)
    repository_ctx.file("DIAGNOSTICS.md", outputs.markdown_content)

def diagnostics_mode_is_valid_for_test(mode):
    """Test helper to validate diagnostics modes."""
    return _validate_diagnostics_mode("diagnostics_mode_is_valid_for_test", mode)

def sorted_diagnostics_for_test(diagnostics):
    """Test helper exposing deterministic diagnostics sorting."""
    return _sorted_diagnostics(diagnostics)

def diagnostics_outputs_for_test(diagnostics):
    """Test helper exposing rendered diagnostics outputs."""
    return _render_diagnostics_outputs(diagnostics)

def apply_parser_errors_for_test(parser_mode, project_path, parse_errors):
    """Test helper for parser diagnostics behavior.

    Args:
        parser_mode: Diagnostics mode string (off, warn, or strict).
        project_path: Path to the project file.
        parse_errors: List of parser error message strings.

    Returns:
        Struct containing diagnostics and strict_failures.
    """
    diagnostics = []
    strict_failures = []
    _apply_parser_errors(diagnostics, strict_failures, parser_mode, project_path, parse_errors)
    return struct(
        diagnostics = diagnostics,
        strict_failures = strict_failures,
    )

def apply_policy_diagnostic_for_test(mode, category, message):
    """Test helper for generic policy-driven diagnostics.

    Args:
        mode: Diagnostics policy mode (off|warn|strict).
        category: Diagnostic category to emit.
        message: Diagnostic message body.

    Returns:
        Struct containing diagnostics and strict_failures.
    """
    diagnostics = []
    strict_failures = []
    _record_policy_diagnostic(
        diagnostics,
        strict_failures,
        mode,
        category,
        message,
    )
    return struct(
        diagnostics = diagnostics,
        strict_failures = strict_failures,
    )

def parse_paket_references_for_test(content):
    """Test helper for parsing paket.references content."""
    return _parse_paket_references_content(content)

def merge_package_references_for_test(package_refs, paket_ids):
    """Test helper for package merge behavior."""
    return _merge_package_references(package_refs, paket_ids)

def _dotnet_projects_repo_impl(repository_ctx):
    """Implementation of the dotnet_projects_repo repository rule."""
    exclude_patterns = repository_ctx.attr.exclude_patterns
    nuget_repo_name = repository_ctx.attr.nuget_repo_name
    registered_toolchains_json = repository_ctx.attr.registered_toolchains
    fail_on_missing = repository_ctx.attr.fail_on_missing_toolchain
    emit_diagnostics_report = repository_ctx.attr.emit_diagnostics_report
    parser_mode = _validate_diagnostics_mode("parser_diagnostics", repository_ctx.attr.parser_diagnostics)
    toolchain_mode = _validate_diagnostics_mode("toolchain_diagnostics", repository_ctx.attr.toolchain_diagnostics)
    paket_mode = _validate_diagnostics_mode("paket_diagnostics", repository_ctx.attr.paket_diagnostics)
    internals_mode = _validate_diagnostics_mode(
        "internals_visibility_diagnostics",
        repository_ctx.attr.internals_visibility_diagnostics,
    )
    if fail_on_missing and toolchain_mode == "warn":
        # Preserve existing behavior when fail_on_missing_toolchain is enabled.
        toolchain_mode = "strict"

    diagnostics = []
    strict_failures = []

    # Parse registered toolchains from JSON
    registered_toolchains = {}
    if registered_toolchains_json:
        registered_toolchains = json.decode(registered_toolchains_json)

    # Get workspace root directory
    # Use workspace_root if available (Bazel 7.1+), otherwise fail with a helpful message
    if hasattr(repository_ctx, "workspace_root"):
        workspace_dir = repository_ctx.workspace_root
    else:
        fail("The scan_projects feature requires Bazel 7.1 or later which provides repository_ctx.workspace_root")

    # Find all project files
    project_files = _find_project_files(
        repository_ctx,
        workspace_dir,
        exclude_patterns,
    )

    # Watch directories containing project files for changes
    # This helps Bazel detect when new files are added to existing project directories
    # Note: New top-level directories with projects won't be detected automatically
    # - users should run `bazel sync --only=@dotnet_projects` after adding new project directories
    if hasattr(repository_ctx, "watch_tree"):
        watched_dirs = {}
        has_root_project = False
        for project_path in project_files:
            project_dir = "/".join(project_path.split("/")[:-1]) if "/" in project_path else ""
            if not project_dir:
                # Project at workspace root
                has_root_project = True
                continue
            if project_dir not in watched_dirs:
                watched_dirs[project_dir] = True
                dir_path = repository_ctx.path(workspace_dir).get_child(project_dir)
                repository_ctx.watch_tree(dir_path)

        # Note: We intentionally don't watch the workspace root even if there are
        # root-level projects, as this would cause excessive re-evaluation.
        # Users should run `bazel sync` if they add new root-level project files.
        if has_root_project:
            # Watch individual project files at root instead of the whole directory
            for project_path in project_files:
                if "/" not in project_path:
                    repository_ctx.watch(repository_ctx.path(workspace_dir).get_child(project_path))

    # Collect NuGet packages
    nuget_collector = create_nuget_collector()

    # Track generated files by directory
    generated_dirs = {}

    # Collect all TFMs for validation
    all_tfms = {}  # TFM -> list of projects using it
    parsed_projects = []  # Store parsed projects for later processing
    project_to_assembly = {}
    assembly_to_project = {}
    reverse_refs = {}  # referenced project path -> dict(referencing project path -> True)

    # First pass: parse all projects and collect TFMs
    for project_path in project_files:
        # Read project file content
        full_path = repository_ctx.path(workspace_dir).get_child(project_path)

        # Check if file exists and is readable
        content = repository_ctx.read(full_path)
        if not content:
            continue

        # Determine if F# or C#
        is_fsharp = project_path.endswith(".fsproj")

        # Parse the project
        parsed = parse_project_file(content)

        # Merge paket.references when Paket restore import is present.
        if parsed.uses_paket:
            project_dir = _project_dir(project_path)
            paket_refs_path = "paket.references" if not project_dir else project_dir + "/paket.references"
            paket_refs_full = repository_ctx.path(workspace_dir).get_child(paket_refs_path)
            paket_refs_content = ""
            if hasattr(paket_refs_full, "exists") and paket_refs_full.exists:
                paket_refs_content = repository_ctx.read(paket_refs_full)

            if paket_refs_content:
                paket_ids = _parse_paket_references_content(paket_refs_content)
                merged_package_refs = _merge_package_references(parsed.package_references, paket_ids)
                parsed = struct(
                    sdk = parsed.sdk,
                    target_frameworks = parsed.target_frameworks,
                    output_type = parsed.output_type,
                    sources = parsed.sources,
                    project_references = parsed.project_references,
                    package_references = merged_package_refs,
                    internals_visible_to = parsed.internals_visible_to,
                    uses_paket = parsed.uses_paket,
                    properties = parsed.properties,
                    enable_default_items = parsed.enable_default_items,
                    is_fsharp = parsed.is_fsharp,
                    errors = parsed.errors,
                )
            else:
                _record_policy_diagnostic(
                    diagnostics,
                    strict_failures,
                    paket_mode,
                    "paket",
                    "Project imports Paket restore targets but no paket.references was found.",
                    project_path,
                    "Add paket.references next to the project file, or remove Paket.Restore.targets import.",
                    "Paket diagnostic",
                )

        if parsed.errors:
            _apply_parser_errors(
                diagnostics,
                strict_failures,
                parser_mode,
                project_path,
                parsed.errors,
            )

        # Collect TFMs
        for tfm in parsed.target_frameworks:
            if tfm not in all_tfms:
                all_tfms[tfm] = []
            all_tfms[tfm].append(project_path)

        # Store for later
        assembly_name = parsed.properties.get("AssemblyName", _project_stem(project_path))
        normalized_assembly = _normalize_assembly_name(assembly_name)
        if normalized_assembly and normalized_assembly not in assembly_to_project:
            assembly_to_project[normalized_assembly] = project_path
        project_to_assembly[project_path] = assembly_name

        # Build reverse reference index for internals_visible_to derivation.
        project_dir = _project_dir(project_path)
        for proj_ref in parsed.project_references:
            resolved = resolve_relative_path(project_dir, proj_ref.path)
            if not resolved:
                continue
            if resolved not in reverse_refs:
                reverse_refs[resolved] = {}
            reverse_refs[resolved][project_path] = True

        parsed_projects.append(struct(
            path = project_path,
            parsed = parsed,
            is_fsharp = is_fsharp,
        ))

    # Validate toolchain coverage
    if not registered_toolchains and all_tfms and toolchain_mode != "off":
        _add_diagnostic(
            diagnostics,
            "toolchain_config",
            "warning",
            "No auto_dotnet.toolchain declarations found; toolchain coverage validation is skipped.",
            "",
            "Declare matching auto_dotnet.toolchain(...) tags or disable this diagnostic.",
        )

    if registered_toolchains and all_tfms:
        coverage = find_best_toolchain_for_tfms(registered_toolchains, all_tfms.keys())

        if coverage.uncovered:
            message_lines = [
                "The following target frameworks are not covered by any registered toolchain:",
            ]
            for tfm in coverage.uncovered:
                projects = all_tfms.get(tfm, [])
                message_lines.append("  {} (used by {} project(s)):".format(tfm, len(projects)))
                for proj in projects[:3]:  # Show first 3 projects
                    message_lines.append("    - {}".format(proj))
                if len(projects) > 3:
                    message_lines.append("    - ... and {} more".format(len(projects) - 3))

                suggested = coverage.suggestions.get(tfm)
                if suggested:
                    message_lines.append("    Suggested: dotnet.toolchain(dotnet_version = \"{}\")".format(suggested))

            message = "\n".join(message_lines)

            if toolchain_mode != "off":
                severity = "error" if toolchain_mode == "strict" else "warning"
                _add_diagnostic(
                    diagnostics,
                    "toolchain_coverage",
                    severity,
                    message,
                    "",
                    "Add or align toolchain declarations for uncovered TFMs.",
                )
            if toolchain_mode == "strict":
                strict_failures.append(message)
            elif toolchain_mode == "warn":
                # buildifier: disable=print
                print("WARNING: " + message)

        # Write a summary file
        summary_lines = ["# Toolchain Coverage Summary", ""]
        summary_lines.append("## Registered Toolchains")
        for name in sorted(registered_toolchains.keys()):
            version = registered_toolchains[name]
            summary_lines.append("- {}: {}".format(name, version))
        summary_lines.append("")
        summary_lines.append("## Discovered Target Frameworks")
        for tfm in sorted(all_tfms.keys()):
            projects = all_tfms[tfm]
            status = "COVERED" if tfm in coverage.covered else "NOT COVERED"
            summary_lines.append("- {} ({}) - {} project(s)".format(tfm, status, len(projects)))
        summary_lines.append("")

        if coverage.uncovered:
            summary_lines.append("## Missing Toolchains")
            for tfm in coverage.uncovered:
                suggested = coverage.suggestions.get(tfm, "unknown")
                summary_lines.append("- {}: dotnet.toolchain(dotnet_version = \"{}\")".format(tfm, suggested))

        repository_ctx.file("TOOLCHAIN_COVERAGE.md", "\n".join(summary_lines))

    # Second pass: generate .bzl files
    for proj in parsed_projects:
        project_path = proj.path
        parsed = proj.parsed
        is_fsharp = proj.is_fsharp
        project_dir = _project_dir(project_path)

        # Compute internals_visible_to labels from explicit declarations and
        # reverse references (derived friend targets for gradual adoption).
        internals_visible_to_labels = {}
        explicit_friends = {}
        for friend in parsed.internals_visible_to:
            normalized_friend = _normalize_assembly_name(friend)
            if not normalized_friend:
                continue
            explicit_friends[normalized_friend] = True
            friend_project = assembly_to_project.get(normalized_friend)
            if friend_project:
                internals_visible_to_labels[_project_path_to_label(friend_project)] = True

        referencers = reverse_refs.get(project_path, {})
        for referencer_path in sorted(referencers.keys()):
            internals_visible_to_labels[_project_path_to_label(referencer_path)] = True
            referencer_assembly = project_to_assembly.get(referencer_path, "")
            normalized_referencer = _normalize_assembly_name(referencer_assembly)
            if normalized_referencer and normalized_referencer not in explicit_friends:
                _record_policy_diagnostic(
                    diagnostics,
                    strict_failures,
                    internals_mode,
                    "internals_visible_to",
                    "Project is referenced by {} but does not explicitly declare InternalsVisibleTo for assembly {}.".format(
                        referencer_path,
                        referencer_assembly,
                    ),
                    project_path,
                    "Add explicit InternalsVisibleTo metadata if internals sharing is required.",
                    "InternalsVisibleTo diagnostic",
                )

        # Collect NuGet packages
        nuget_collector.add_packages_from_project(parsed.package_references, project_path)

        # Generate .bzl content
        bzl_content = generate_project_bzl(
            parsed,
            project_path,
            project_dir,
            is_fsharp,
            nuget_repo_name,
            str(workspace_dir),
            sorted(internals_visible_to_labels.keys()),
        )

        # Determine output path
        # Project at my/path/foo.csproj -> my/path/foo.csproj.bzl
        bzl_path = project_path + ".bzl"

        # Create directory structure
        output_dir = "/".join(bzl_path.split("/")[:-1]) if "/" in bzl_path else ""
        if output_dir:
            repository_ctx.file(output_dir + "/.gitkeep", "")

        # Track this file in its directory
        if output_dir not in generated_dirs:
            generated_dirs[output_dir] = []
        generated_dirs[output_dir].append(bzl_path.split("/")[-1])

        # Write the .bzl file
        repository_ctx.file(bzl_path, bzl_content)

    # Generate nuget packages.bzl
    resolved_packages = nuget_collector.resolve_packages()
    if resolved_packages:
        nuget_bzl = generate_nuget_packages_bzl(resolved_packages, nuget_repo_name)
        repository_ctx.file("nuget/packages.bzl", nuget_bzl)

        # Also generate an extension file for the NuGet packages
        nuget_extension_bzl = _generate_nuget_extension_bzl(nuget_repo_name)
        repository_ctx.file("nuget/packages_extension.bzl", nuget_extension_bzl)

        # Generate a paket.dependencies file to help users set up Paket
        paket_deps = generate_paket_dependencies(resolved_packages)
        repository_ctx.file("nuget/paket.dependencies.generated", paket_deps)

        if "nuget" not in generated_dirs:
            generated_dirs["nuget"] = []
        generated_dirs["nuget"].extend(["packages.bzl", "packages_extension.bzl"])

    # Generate root files
    repository_ctx.file("defs.bzl", generate_defs_bzl())
    repository_ctx.file("BUILD.bazel", generate_root_build_bazel())

    # Generate BUILD.bazel for each directory
    for dir_path in sorted(generated_dirs.keys()):
        bzl_files = sorted(generated_dirs[dir_path])
        if dir_path:
            build_content = generate_subdir_build_bazel(bzl_files)
            repository_ctx.file(dir_path + "/BUILD.bazel", build_content)

    # Report any version conflicts
    conflicts = nuget_collector.get_version_conflicts()
    if conflicts:
        conflict_lines = ["# NuGet version conflicts detected:"]
        for conflict in conflicts:
            conflict_lines.append("#   {}: versions {} requested from:".format(
                conflict.id,
                ", ".join(conflict.versions),
            ))
            for version in sorted(conflict.sources.keys()):
                sources = conflict.sources[version]
                for source in sorted(sources):
                    conflict_lines.append("#     - {} (version {})".format(source, version))
        conflict_lines.append("")
        repository_ctx.file("CONFLICTS.md", "\n".join(conflict_lines))

    if emit_diagnostics_report:
        _write_diagnostics_reports(repository_ctx, diagnostics)

    if strict_failures:
        fail("Diagnostics strict mode failures:\n\n{}".format("\n\n".join(strict_failures)))

def _generate_nuget_extension_bzl(_nuget_repo_name):  # buildifier: disable=unused-variable
    """Generate module extension for NuGet packages.

    Args:
        _nuget_repo_name: Name of the NuGet repository (unused, kept for API compatibility).

    Returns:
        String content of the extension .bzl file.
    """
    return '''"Generated module extension for NuGet packages"

load(":packages.bzl", _dotnet_nuget_packages = "dotnet_nuget_packages")

def _dotnet_nuget_impl(module_ctx):
    """Implementation of the dotnet_projects NuGet extension."""
    _dotnet_nuget_packages()
    return module_ctx.extension_metadata(reproducible = True)

dotnet_nuget_extension = module_extension(
    implementation = _dotnet_nuget_impl,
)
'''

dotnet_projects_repo = repository_rule(
    implementation = _dotnet_projects_repo_impl,
    # buildifier: disable=unsorted-dict-items
    attrs = {
        "root_module_name": attr.string(
            default = "",
            doc = "Name of the root module to scan (deprecated, not used).",
        ),
        "exclude_patterns": attr.string_list(
            default = ["**/bin/**", "**/obj/**", "**/.git/**", "**/.jj/**"],
            doc = "Glob patterns for paths to exclude from scanning.",
        ),
        "nuget_repo_name": attr.string(
            default = "dotnet_projects.nuget",
            doc = "Name of the NuGet repository to generate.",
        ),
        "registered_toolchains": attr.string(
            default = "",
            doc = "JSON-encoded dict of registered toolchain names to SDK versions.",
        ),
        "auto_register_toolchains": attr.bool(
            default = False,
            doc = "If true, auto-register toolchains for discovered TFMs (not yet implemented).",
        ),
        "fail_on_missing_toolchain": attr.bool(
            default = True,
            doc = "If true, fail when a TFM is not covered by any registered toolchain.",
        ),
        "toolchain_diagnostics": attr.string(
            default = "warn",
            doc = "Diagnostics mode for toolchain checks: off|warn|strict.",
        ),
        "parser_diagnostics": attr.string(
            default = "warn",
            doc = "Diagnostics mode for parser checks: off|warn|strict.",
        ),
        "paket_diagnostics": attr.string(
            default = "warn",
            doc = "Diagnostics mode for Paket checks: off|warn|strict.",
        ),
        "internals_visibility_diagnostics": attr.string(
            default = "warn",
            doc = "Diagnostics mode for internals visibility checks: off|warn|strict.",
        ),
        "emit_diagnostics_report": attr.bool(
            default = True,
            doc = "If true, emit DIAGNOSTICS.md and diagnostics.json files.",
        ),
    },
    doc = """Scans a workspace for .csproj and .fsproj files and generates .bzl files.

This repository rule:
1. Finds all .csproj and .fsproj files in the workspace
2. Parses each project file to extract properties, sources, and dependencies
3. Generates a .bzl file for each project with an auto_dotnet_targets() macro
4. Collects all NuGet package references and generates a nuget_repo() call
5. Validates that registered toolchains cover all discovered target frameworks

Usage in MODULE.bazel:
    dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
    dotnet.toolchain(dotnet_version = "10.0.100")
    dotnet.scan_projects()
    use_repo(dotnet, "dotnet_toolchains", "dotnet_projects")

Usage in BUILD files:
    load("@dotnet_projects//path/to:project.csproj.bzl", "auto_dotnet_targets")
    auto_dotnet_targets(name = "project")

File Change Detection:
    Bazel will automatically re-run this repository rule when:
    - Any existing .csproj or .fsproj file is modified
    - New project files are added to directories that already contain project files

    Bazel will NOT automatically detect:
    - New project files added to entirely new directories
    - New top-level project directories

    To pick up new project directories, run:
        bazel sync --only=@dotnet_projects

Requirements:
    - Bazel 7.1 or later (for repository_ctx.workspace_root support)
""",
)
