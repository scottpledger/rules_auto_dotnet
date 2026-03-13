# Architecture Overview

`rules_auto_dotnet` is a Bazel module extension that bridges existing .NET project
files (`.csproj` / `.fsproj`) with Bazel builds powered by
[rules_dotnet](https://github.com/bazel-contrib/rules_dotnet).

## Relationship to rules_dotnet

```
                    ┌──────────────────────────┐
                    │    User MODULE.bazel      │
                    └───────┬──────────┬────────┘
                            │          │
               ┌────────────▼──┐  ┌────▼─────────────┐
               │ rules_dotnet  │  │ rules_auto_dotnet │
               │ (toolchains,  │  │ (project scanning │
               │  build rules) │  │  & code gen)      │
               └───────────────┘  └────────┬──────────┘
                       ▲                   │
                       │          ┌────────▼──────────┐
                       │          │  @dotnet_projects  │
                       └──────────┤  (generated repo)  │
                                  └───────────────────┘
```

`rules_auto_dotnet` does **not** provide its own toolchain or build rules. Instead:

- **rules_dotnet** provides the .NET SDK toolchains and build rules (`csharp_binary`,
  `csharp_library`, `fsharp_binary`, etc.)
- **rules_auto_dotnet** scans `.csproj`/`.fsproj` files and generates `.bzl` files that
  invoke rules_dotnet rules with the correct attributes

This separation means users who don't need project scanning can use rules_dotnet
directly, while users migrating from MSBuild can use rules_auto_dotnet for
automatic target generation.

## Pipeline Overview

The extension operates in a single pipeline when `scan_projects()` is configured:

1. **Discovery** (`dotnet_projects_repo.bzl`) -- Find all `.csproj` and `.fsproj` files
   in the workspace using platform-appropriate commands (`find` on Unix, PowerShell on Windows)

2. **Parsing** (`parser.bzl`) -- Parse each XML project file using `xml.bzl` to extract
   SDK type, target frameworks, output type, source files, project references, package
   references, and MSBuild properties

3. **TFM Validation** (`tfm_utils.bzl`) -- Check that registered .NET SDK toolchains cover
   all discovered target framework monikers (TFMs), with suggestions for missing SDKs

4. **Code Generation** (`generator.bzl`) -- Generate a `.bzl` file per project containing
   an `auto_dotnet_targets()` macro that creates the appropriate rules_dotnet rule

5. **NuGet Collection** (`nuget_collector.bzl`) -- Collect and deduplicate NuGet package
   references across all projects, resolving version conflicts using highest-version strategy

6. **Repository Assembly** (`dotnet_projects_repo.bzl`) -- Assemble the `@dotnet_projects`
   repository with generated `.bzl` files, BUILD files, NuGet package list, and diagnostics

See the individual design documents for detailed descriptions:

- [Project Scanning Pipeline](project-scanning.md)
- [TFM Validation](tfm-validation.md)
- [NuGet Collection](nuget-collection.md)
