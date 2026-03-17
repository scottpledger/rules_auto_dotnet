"Generate .bzl files from parsed .csproj/.fsproj projects"

load("@bazel_skylib//lib:paths.bzl", "paths")
load(":parser.bzl", "extract_additional_attrs", "get_bazel_rule_name", "get_project_sdk_attr")
load(":path_utils.bzl", "resolve_relative_path")

def generate_project_bzl(
        parsed_project,
        project_path,
        project_dir,
        is_fsharp,
        nuget_repo_name = "dotnet_projects.nuget",
        workspace_root = "",
        internals_visible_to_labels = [],
        project_sdk_override = None):
    """Generate the .bzl file content for a single project.

    Args:
        parsed_project: A struct returned by parse_project_file.
        project_path: Path to the project file relative to workspace.
        project_dir: Directory containing the project file relative to workspace.
        is_fsharp: Whether this is an F# project.
        nuget_repo_name: Name of the NuGet repository.
        workspace_root: The workspace root for label resolution.
        internals_visible_to_labels: Labels to set in internals_visible_to.
        project_sdk_override: Optional explicit project_sdk to emit.

    Returns:
        String content of the .bzl file.
    """
    rule_name = get_bazel_rule_name(parsed_project, is_fsharp)
    project_sdk = project_sdk_override if project_sdk_override != None else get_project_sdk_attr(parsed_project)
    additional_attrs = extract_additional_attrs(parsed_project)

    # Generate source file list or glob
    srcs = _generate_srcs(parsed_project, is_fsharp)

    # Generate dependencies
    deps = _generate_deps(parsed_project, project_dir, nuget_repo_name, workspace_root)

    # Build the .bzl file content
    lines = []
    lines.append('"Generated from {}"'.format(project_path))
    lines.append("")
    lines.append('load("@rules_dotnet//dotnet:defs.bzl", "{}")'.format(rule_name))
    lines.append("")
    lines.append("def auto_dotnet_targets(name, **kwargs):")
    lines.append('    """Auto-generated targets from {}.'.format(project_path.split("/")[-1]))
    lines.append("")
    lines.append("    Args:")
    lines.append("        name: The target name.")
    lines.append("        **kwargs: Additional arguments passed to the underlying rule.")
    lines.append('    """')
    lines.append("    kwargs = dict(kwargs)")

    # Consume overridable attrs from kwargs to avoid duplicate keyword
    # arguments when forwarding **kwargs to the underlying rule.
    lines.append("    srcs = kwargs.pop(\"srcs\", {})".format(srcs))

    if parsed_project.target_frameworks:
        frameworks = ['"{}"'.format(f) for f in parsed_project.target_frameworks]
        lines.append("    target_frameworks = kwargs.pop(\"target_frameworks\", [{}])".format(", ".join(frameworks)))
    else:
        # Default to a reasonable framework if none specified
        lines.append('    target_frameworks = kwargs.pop("target_frameworks", ["net8.0"])')

    # Dependencies
    if deps:
        lines.append("    deps = kwargs.pop(\"deps\", [")
        for dep in deps:
            lines.append('        "{}",'.format(dep))
        lines.append("    ])")

    # Project SDK
    if project_sdk:
        lines.append('    project_sdk = kwargs.pop("project_sdk", "{}")'.format(project_sdk))

    # Friend assemblies mapped to Bazel labels.
    if internals_visible_to_labels:
        lines.append("    internals_visible_to = kwargs.pop(\"internals_visible_to\", [")
        for label in sorted(internals_visible_to_labels):
            lines.append('        "{}",'.format(label))
        lines.append("    ])")

    # Additional attributes from properties
    for attr_name in sorted(additional_attrs.keys()):
        attr_value = additional_attrs[attr_name]
        if type(attr_value) == "bool":
            lines.append("    {} = kwargs.pop(\"{}\", {})".format(attr_name, attr_name, "True" if attr_value else "False"))
        elif type(attr_value) == "int":
            lines.append("    {} = kwargs.pop(\"{}\", {})".format(attr_name, attr_name, attr_value))
        else:
            lines.append('    {} = kwargs.pop("{}", "{}")'.format(attr_name, attr_name, attr_value))

    # Start rule invocation
    lines.append("    {}(".format(rule_name))
    lines.append("        name = name,")
    lines.append("        srcs = srcs,")
    lines.append("        target_frameworks = target_frameworks,")
    if deps:
        lines.append("        deps = deps,")
    if project_sdk:
        lines.append("        project_sdk = project_sdk,")
    if internals_visible_to_labels:
        lines.append("        internals_visible_to = internals_visible_to,")

    for attr_name in sorted(additional_attrs.keys()):
        lines.append("        {} = {},".format(attr_name, attr_name))

    # Allow kwargs override
    lines.append("        **kwargs")
    lines.append("    )")
    lines.append("")

    return "\n".join(lines)

def _generate_srcs(parsed_project, is_fsharp):
    """Generate the srcs attribute value.

    Args:
        parsed_project: A struct returned by parse_project_file.
        is_fsharp: Whether this is an F# project.

    Returns:
        String representation of the srcs list or glob.
    """
    ext = ".fs" if is_fsharp else ".cs"

    if parsed_project.sources:
        # Explicit sources - use them directly
        # For F#, order matters, so we preserve the order from the .fsproj
        sources = ['"{}"'.format(s) for s in parsed_project.sources]
        return "[{}]".format(", ".join(sources))

    if parsed_project.enable_default_items:
        # Use glob for default item behavior (SDK-style projects include subdirectories)
        return 'native.glob(["**/*{}"], exclude = ["obj/**", "bin/**"])'.format(ext)

    # No sources and default items disabled.
    return "[]"

def _generate_deps(parsed_project, project_dir, nuget_repo_name, _workspace_root):  # buildifier: disable=unused-variable
    """Generate the deps list.

    Args:
        parsed_project: A struct returned by parse_project_file.
        project_dir: Directory containing the project file.
        nuget_repo_name: Name of the NuGet repository.
        _workspace_root: The workspace root for label resolution (unused, kept for API compatibility).

    Returns:
        List of Bazel label strings.
    """
    deps = []

    # Add project references
    for proj_ref in parsed_project.project_references:
        label = _project_reference_to_label(proj_ref.path, project_dir)
        if label:
            deps.append(label)

    # Add package references
    for pkg_ref in parsed_project.package_references:
        label = "@{}//{}".format(nuget_repo_name, pkg_ref.id.lower())
        deps.append(label)

    return sorted(deps)

def _project_reference_to_label(ref_path, project_dir):
    """Convert a ProjectReference path to a Bazel label.

    Uses paths utilities from bazel_skylib for path manipulation.

    Args:
        ref_path: Relative path from the current project to the referenced project.
        project_dir: Directory containing the current project file.

    Returns:
        Bazel label string, or None if conversion fails.
    """
    if not ref_path:
        return None

    # Normalize the path (handle Windows backslashes)
    ref_path = ref_path.replace("\\", "/")

    # Resolve relative path components
    resolved = resolve_relative_path(project_dir, ref_path)
    if resolved == None:
        return None

    # Use paths utilities to extract directory and filename
    dir_path = paths.dirname(resolved)
    filename = paths.basename(resolved)

    # Remove file extension to get target name using paths.split_extension
    target_name = paths.split_extension(filename)[0]

    # Build the label
    if dir_path:
        return "//{}:{}".format(dir_path, target_name)
    else:
        return ":{}".format(target_name)

def generate_defs_bzl():
    """Generate the root defs.bzl file for the @dotnet_projects repository.

    Returns:
        String content of the defs.bzl file.
    """
    return '''"Common utilities for @dotnet_projects repository"

# This file provides common utilities that can be used across generated .bzl files.
# Currently empty but can be extended with shared functionality.
'''

def generate_root_build_bazel():
    """Generate the root BUILD.bazel file for the @dotnet_projects repository.

    Returns:
        String content of the BUILD.bazel file.
    """
    return '''# Generated BUILD.bazel for @dotnet_projects repository
# This file exports the generated .bzl files.

exports_files(glob([
    "**/*.bzl",
    "*.md",
    "*.json",
]))
'''

def generate_subdir_build_bazel(bzl_files):
    """Generate a BUILD.bazel file for a subdirectory.

    Args:
        bzl_files: List of .bzl filenames in this directory.

    Returns:
        String content of the BUILD.bazel file.
    """
    lines = [
        "# Generated BUILD.bazel",
        "",
    ]

    if bzl_files:
        exports = ['"{}"'.format(f) for f in bzl_files]
        lines.append("exports_files([{}])".format(", ".join(exports)))
    else:
        lines.append("# No .bzl files in this directory")

    lines.append("")
    return "\n".join(lines)
