# rules_auto_dotnet

Automatic Bazel target generation from `.csproj` and `.fsproj` project files.

This module extension scans your workspace for .NET project files and generates
Bazel targets using [rules_dotnet](https://github.com/bazel-contrib/rules_dotnet).
It bridges the gap between existing MSBuild project structure and Bazel builds.

WARNING: This module is experimental and not yet ready for production use. APIs will likely change as the implementation is fleshed out. Use at your own risk until version 1.0.0 is released.

## Installation

Add to your `MODULE.bazel`:

```starlark
# 1. Set up rules_dotnet toolchain
bazel_dep(name = "rules_dotnet", version = "0.17.6")

dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(dotnet_version = "10.0.100")
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

# 2. Enable automatic project scanning
bazel_dep(name = "rules_auto_dotnet", version = "0.0.0")

auto_dotnet = use_extension("@rules_auto_dotnet//auto_dotnet:extensions.bzl", "auto_dotnet")
auto_dotnet.toolchain(dotnet_version = "10.0.100")
auto_dotnet.scan_projects()
use_repo(auto_dotnet, "dotnet_projects")
```

## Usage

In your `BUILD.bazel` files, load the generated macros from `@dotnet_projects`:

```starlark
load("@dotnet_projects//path/to:MyProject.csproj.bzl", "auto_dotnet_targets")

auto_dotnet_targets(
    name = "MyProject",
    visibility = ["//visibility:public"],
)
```

The generated `auto_dotnet_targets()` macro creates the appropriate
`csharp_binary`, `csharp_library`, `fsharp_binary`, or `fsharp_library` rule
based on the project file contents.

## How It Works

1. **Scanning**: The extension scans your workspace for all `.csproj` and `.fsproj` files
2. **Parsing**: Each project file is parsed to extract target framework(s), output type,
   source files, project references, and NuGet package references
3. **Generation**: A `.bzl` file is generated per project containing an `auto_dotnet_targets()`
   macro that creates the appropriate rules_dotnet rule
4. **Validation**: Registered toolchains are checked against discovered target frameworks

## Configuration

### Exclude Patterns

Exclude certain paths from scanning:

```starlark
auto_dotnet.scan_projects(
    exclude_patterns = [
        "**/tests/**",
        "**/legacy/**",
    ],
)
```

Default exclusions: `**/bin/**`, `**/obj/**`, `**/.git/**`, `**/.jj/**`, `**/bazel-*/**`

### Toolchain Validation

By default, the extension validates that your registered toolchains can build all
discovered target frameworks:

```starlark
auto_dotnet.scan_projects(
    fail_on_missing_toolchain = True,  # Default
)
```

Set to `False` to emit warnings instead of failing.

You can also configure diagnostics policy explicitly:

```starlark
auto_dotnet.scan_projects(
    toolchain_diagnostics = "warn",  # off | warn | strict
    parser_diagnostics = "warn",     # off | warn | strict
    emit_diagnostics_report = True,  # writes diagnostics.json + DIAGNOSTICS.md
)
```

`rules_auto_dotnet` does not register toolchains. Continue registering toolchains
through `rules_dotnet`; generated and manual targets both resolve through those
global registrations.

### Overriding Generated Targets

The `auto_dotnet_targets()` macro accepts `**kwargs` to override any generated attribute:

```starlark
auto_dotnet_targets(
    name = "MyProject",
    visibility = ["//visibility:public"],
    deps = ["//other:dependency"],
    compiler_options = ["/warnaserror"],
)
```

## File Change Detection

Bazel automatically re-scans when existing `.csproj`/`.fsproj` files change or
new projects appear in directories that already contain projects. For new project
files in entirely new directories, run:

```bash
bazel sync --only=@dotnet_projects
```

## IDE Support

Use `dotnet_generated_props` to generate `.props` files that let your IDE see
Bazel-generated source files:

```starlark
load("@rules_auto_dotnet//auto_dotnet:defs.bzl", "dotnet_generated_props")

dotnet_generated_props(
    name = "sync_ide",
    generated_srcs = [":my_protos"],
    out = "MyProject.Generated.props",
)
```

Then import in your `.csproj`:

```xml
<Import Project="MyProject.Generated.props"
        Condition="Exists('MyProject.Generated.props')" />
```

## Requirements

- Bazel 7.1 or later (for `repository_ctx.workspace_root`)
- [rules_dotnet](https://github.com/bazel-contrib/rules_dotnet) for .NET build rules and SDK toolchains
- Cross-platform support is a core requirement: Windows, macOS, Linux, and
  other Bazel-supported platforms must be supported.
