"Extensions for bzlmod"

load("//auto_dotnet/private:dotnet_projects_repo.bzl", "dotnet_projects_repo")

# buildifier: disable=unsorted-dict-items
_SCAN_PROJECTS_ATTRS = {
    "exclude_patterns": attr.string_list(
        doc = """Glob patterns for paths to exclude from scanning.

Default patterns exclude bin/, obj/, .git/, .jj/, and bazel-* directories.""",
    ),
    "nuget_repo_name": attr.string(
        default = "dotnet_projects.nuget",
        doc = """Name of the NuGet repository to generate.

Packages can be referenced as @{nuget_repo_name}//PackageName.""",
    ),
    "fail_on_missing_toolchain": attr.bool(
        default = True,
        doc = """If true, fail when a project targets a TFM not covered by registered toolchains.

Set to false to only emit warnings instead of failing.""",
    ),
    "toolchain_diagnostics": attr.string(
        default = "warn",
        doc = """Severity for toolchain coverage diagnostics.

Allowed values: "off", "warn", "strict".
- off: do not emit toolchain diagnostics
- warn: emit warnings and continue (default)
- strict: fail after collecting diagnostics""",
    ),
    "parser_diagnostics": attr.string(
        default = "warn",
        doc = """Severity for project parsing diagnostics.

Allowed values: "off", "warn", "strict".
- off: ignore parse diagnostics
- warn: emit warnings and continue (default)
- strict: fail after collecting diagnostics""",
    ),
    "paket_diagnostics": attr.string(
        default = "warn",
        doc = """Severity for Paket diagnostics.

Allowed values: "off", "warn", "strict".
- off: ignore Paket diagnostics
- warn: emit warnings and continue (default)
- strict: fail after collecting diagnostics""",
    ),
    "internals_visibility_diagnostics": attr.string(
        default = "warn",
        doc = """Severity for InternalsVisibleTo diagnostics.

Allowed values: "off", "warn", "strict".
- off: ignore internals visibility diagnostics
- warn: emit warnings and continue (default)
- strict: fail after collecting diagnostics""",
    ),
    "emit_diagnostics_report": attr.bool(
        default = True,
        doc = "If true, generate DIAGNOSTICS.md and diagnostics.json in @dotnet_projects.",
    ),
}

# buildifier: disable=unsorted-dict-items
_TOOLCHAIN_ATTRS = {
    "name": attr.string(
        doc = "Base name for generated repositories",
        default = "dotnet",
    ),
    "dotnet_version": attr.string(
        doc = "Version of the .Net SDK",
    ),
}

def _auto_dotnet_extension(module_ctx):
    # Collect registered toolchains from toolchain tags
    registrations = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name in registrations.keys():
                if toolchain.name == "dotnet":
                    continue
                if toolchain.dotnet_version == registrations[toolchain.name]:
                    continue
                fail("Multiple conflicting toolchains declared for name {} ({} and {})".format(
                    toolchain.name,
                    toolchain.dotnet_version,
                    registrations[toolchain.name],
                ))
            else:
                registrations[toolchain.name] = toolchain.dotnet_version

    # Collect scan_projects configuration (only first/root module)
    scan_config = None
    for mod in module_ctx.modules:
        for config in mod.tags.scan_projects:
            if scan_config != None:
                continue
            scan_config = config

    repos_to_return = []
    if scan_config != None:
        exclude_patterns = ["**/bin/**", "**/obj/**", "**/.git/**", "**/.jj/**", "**/bazel-*/**"]
        if scan_config.exclude_patterns:
            exclude_patterns = exclude_patterns + list(scan_config.exclude_patterns)

        nuget_repo_name = scan_config.nuget_repo_name if scan_config.nuget_repo_name else "dotnet_projects.nuget"

        dotnet_projects_repo(
            name = "dotnet_projects",
            exclude_patterns = exclude_patterns,
            nuget_repo_name = nuget_repo_name,
            registered_toolchains = json.encode(registrations),
            fail_on_missing_toolchain = scan_config.fail_on_missing_toolchain,
            toolchain_diagnostics = scan_config.toolchain_diagnostics,
            parser_diagnostics = scan_config.parser_diagnostics,
            paket_diagnostics = scan_config.paket_diagnostics,
            internals_visibility_diagnostics = scan_config.internals_visibility_diagnostics,
            emit_diagnostics_report = scan_config.emit_diagnostics_report,
        )
        repos_to_return.append("dotnet_projects")

    return module_ctx.extension_metadata(
        reproducible = False if scan_config else True,
        root_module_direct_deps = repos_to_return if repos_to_return else "all",
        root_module_direct_dev_deps = [],
    )

auto_dotnet = module_extension(
    implementation = _auto_dotnet_extension,
    # buildifier: disable=unsorted-dict-items
    tag_classes = {
        "toolchain": tag_class(
            attrs = _TOOLCHAIN_ATTRS,
            doc = """Declare a .NET toolchain version.

These declarations are used by scan_projects to validate that registered
toolchains cover all discovered target frameworks. The actual toolchain
registration should be done via rules_dotnet's extension.""",
        ),
        "scan_projects": tag_class(
            attrs = _SCAN_PROJECTS_ATTRS,
            doc = """Enable automatic scanning of .csproj and .fsproj files.

When enabled, the extension will:
1. Scan the workspace for .csproj and .fsproj files
2. Parse each file to extract properties, sources, and dependencies
3. Generate a @dotnet_projects repository with .bzl files for each project
4. Validate that registered toolchains cover all discovered target frameworks

Usage in MODULE.bazel:
    dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
    dotnet.toolchain(dotnet_version = "10.0.100")
    use_repo(dotnet, "dotnet_toolchains")
    register_toolchains("@dotnet_toolchains//:all")

    auto_dotnet = use_extension("@rules_auto_dotnet//auto_dotnet:extensions.bzl", "auto_dotnet")
    auto_dotnet.toolchain(dotnet_version = "10.0.100")
    auto_dotnet.scan_projects()
    use_repo(auto_dotnet, "dotnet_projects")

Usage in BUILD files:
    load("@dotnet_projects//path/to:MyProject.csproj.bzl", "auto_dotnet_targets")
    auto_dotnet_targets(name = "MyProject")

File Change Detection:
    Changes to existing .csproj/.fsproj files are automatically detected.
    New files in existing project directories are also detected.

    However, new project files in entirely new directories require manual sync:
        bazel sync --only=@dotnet_projects

Requirements:
    Bazel 7.1 or later is required for the scan_projects feature.
""",
        ),
    },
    doc = """Extension for automatic .NET project scanning and Bazel target generation.

This extension scans .csproj and .fsproj files in your workspace and generates
Bazel targets using rules_dotnet. Use alongside @rules_dotnet for toolchain
registration and build rules.
""",
)
