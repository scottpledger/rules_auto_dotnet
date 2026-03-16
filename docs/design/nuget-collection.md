# NuGet Collection

## Overview

The NuGet collector aggregates package references from all scanned project files
into a single, deduplicated package list. This enables centralized dependency
management across the workspace.

## Collection Process

1. As each project file is parsed, its `<PackageReference>` items are added to the
   collector with the package ID, version, and source project path
2. Package IDs are normalized to lowercase for deduplication (NuGet IDs are
   case-insensitive)
3. The original casing of the first occurrence is preserved for display
4. For projects importing `Paket.Restore.targets`, sibling `paket.references`
   IDs are parsed and merged before global deduplication

## Version Conflict Resolution

When multiple projects reference the same package at different versions, the
collector uses **highest version wins** strategy, consistent with MSBuild/NuGet
behavior:

- Versions are parsed into semantic version components (major, minor, patch)
- Prerelease versions (`-beta.1`, `-rc.2`) are ranked lower than release versions
- Among prereleases, parts are compared numerically when possible, otherwise
  lexicographically

### Conflict Reporting

Version conflicts are reported in a `CONFLICTS.md` file in the generated
repository, listing:

- The package ID
- All requested versions
- Which project requested each version

This helps users identify and resolve version inconsistencies.

## Generated Output

### packages.bzl

A `nuget/packages.bzl` file is generated containing a `dotnet_nuget_packages()`
function that calls `nuget_repo()` from rules_dotnet:

```starlark
load("@rules_dotnet//dotnet:defs.bzl", "nuget_repo")

def dotnet_nuget_packages():
    nuget_repo(
        name = "dotnet_projects.nuget",
        packages = [
            {
                "id": "Newtonsoft.Json",
                "version": "13.0.3",
                "sha512": "",  # Placeholder
                "sources": [...],
                "dependencies": {},
                ...
            },
        ],
    )
```

**Important**: The generated file uses placeholder SHA512 values. The first build
will fail with hash mismatch errors. Users should either:

1. Update the SHA512 values from the error messages, or
2. Use [Paket](https://fsprojects.github.io/Paket/) with `paket2bazel` for
   proper dependency resolution (recommended for production)

### paket.dependencies.generated

A Paket-compatible `paket.dependencies` file is generated to bootstrap Paket
integration. Users can copy this to their workspace root and run
`dotnet tool run paket install` to get a proper lock file.

### Paket Side-File Semantics

`paket.references` handling is intentionally conservative:

- Parsed only for projects that import `Paket.Restore.targets`.
- Missing `paket.references` produces diagnostics (category `paket`) according to
  `paket_diagnostics` mode (`off|warn|strict`).
- Unsupported `paket.references` directives are ignored instead of failing parse.

## Limitations

- SHA512 hashes are not available from project files; they must be resolved
  externally
- Transitive NuGet dependencies are not resolved (only direct references from
  project files are collected)
- Version ranges (e.g., `[1.0, 2.0)`) are not fully interpreted; the literal
  string is used
- `paket.references` does not currently model full Paket group/source semantics;
  it only contributes package IDs for dependency bootstrap and deduplication
