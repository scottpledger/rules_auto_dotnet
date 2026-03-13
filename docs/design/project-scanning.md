# Project Scanning Pipeline

## Overview

The scanning pipeline transforms `.csproj` and `.fsproj` files into Bazel-loadable
`.bzl` files. It runs as a Bazel repository rule (`dotnet_projects_repo`) during the
loading phase.

## File Discovery

Discovery is platform-aware:

- **Unix**: Uses `find` with `-name "*.csproj" -o -name "*.fsproj"` and built-in
  exclusions for `bin/`, `obj/`, `.git/`, `.jj/`, and `bazel-*` directories
- **Windows**: Uses PowerShell `Get-ChildItem` with `-Recurse -Include` filters,
  falling back to `cmd /c dir /s /b` if PowerShell is unavailable

Additional exclude patterns from the user's `scan_projects()` configuration are
applied via `glob_match` from `bazel_lib`.

## XML Parsing

Each project file is parsed using `xml.bzl` (a pure-Starlark XML parser). The
parser extracts:

| Element             | Source                                           | Example                                      |
| ------------------- | ------------------------------------------------ | -------------------------------------------- |
| SDK type            | `<Project Sdk="...">`                            | `Microsoft.NET.Sdk`, `Microsoft.NET.Sdk.Web` |
| Target framework(s) | `<TargetFramework>` / `<TargetFrameworks>`       | `net10.0`, `net8.0;net9.0`                   |
| Output type         | `<OutputType>`                                   | `Exe`, `Library`                             |
| Source files        | `<Compile Include="...">`                        | `Program.cs`, `Lib.fs`                       |
| Project references  | `<ProjectReference Include="...">`               | `../lib/lib.csproj`                          |
| Package references  | `<PackageReference Include="..." Version="...">` | `Newtonsoft.Json 13.0.3`                     |
| Properties          | Various `<PropertyGroup>` children               | `Nullable`, `LangVersion`, etc.              |

The parser handles both single-target (`TargetFramework`) and multi-target
(`TargetFrameworks`) projects, SDK-style default items, and properties that map
to Bazel rule attributes.

## Code Generation

For each project file, a `.bzl` file is generated containing:

```starlark
load("@rules_dotnet//dotnet:defs.bzl", "csharp_library")

def auto_dotnet_targets(name, **kwargs):
    csharp_library(
        name = name,
        srcs = ["lib.cs"],
        target_frameworks = ["net10.0"],
        deps = [
            "//other:project",
            "@dotnet_projects.nuget//newtonsoft.json",
        ],
        nullable = "enable",
        **kwargs
    )
```

Key generation decisions:

- **Rule selection**: `csharp_binary`/`fsharp_binary` for `OutputType=Exe`,
  `csharp_library`/`fsharp_library` otherwise. F# is detected from `.fsproj` extension.
- **Source files**: Explicit `<Compile>` items are used directly. For SDK-style projects
  with default items enabled, a `native.glob()` is generated.
- **Project references**: Relative paths like `../lib/lib.csproj` are resolved to
  Bazel labels like `//lib:lib` using path normalization.
- **NuGet references**: Package IDs are lowercased and prefixed with the NuGet repo name.
- **Additional attributes**: `Nullable`, `LangVersion`, `TreatWarningsAsErrors`,
  `WarningLevel`, and `AllowUnsafeBlocks` are extracted and passed through.
- **kwargs passthrough**: All generated macros accept `**kwargs` allowing users to
  override any attribute.

## File Change Detection

The repository rule uses `repository_ctx.watch_tree()` (Bazel 7.1+) to watch
directories containing project files. This means:

- Modifications to existing `.csproj`/`.fsproj` files trigger automatic re-scanning
- New files in directories already containing projects are detected
- New top-level project directories require manual `bazel sync --only=@dotnet_projects`

## Generated Repository Structure

```
@dotnet_projects/
├── BUILD.bazel              # Root BUILD with exports_files
├── defs.bzl                 # Common utilities
├── TOOLCHAIN_COVERAGE.md    # TFM coverage summary
├── CONFLICTS.md             # NuGet version conflicts (if any)
├── path/to/
│   ├── BUILD.bazel          # exports_files for .bzl files
│   ├── MyApp.csproj.bzl     # Generated macro
│   └── MyLib.csproj.bzl     # Generated macro
└── nuget/
    ├── BUILD.bazel
    ├── packages.bzl          # Consolidated NuGet packages
    ├── packages_extension.bzl
    └── packet.dependencies.generated
```
