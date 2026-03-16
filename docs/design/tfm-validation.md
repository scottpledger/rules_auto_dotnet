# TFM Validation

## Overview

Target Framework Moniker (TFM) validation ensures that the .NET SDK toolchains
registered by the user can build all the target frameworks discovered in the
workspace's project files.

## Toolchain Contract

`rules_dotnet` remains the single source of truth for actual SDK/toolchain
registration (`register_toolchains(...)`).

`rules_auto_dotnet` does not register toolchains. It only validates coverage
using metadata declared via `auto_dotnet.toolchain(...)` and scan results from
project files.

Because extensions do not directly introspect each other's raw tag declarations,
the practical contract is:

- keep `dotnet.toolchain(...)` and `auto_dotnet.toolchain(...)` declarations aligned,
- let `rules_dotnet` own registration/runtime behavior,
- let `rules_auto_dotnet` own validation diagnostics and reporting.

## How It Works

After scanning all project files, the extension collects every unique TFM and
checks it against the registered toolchains using `tfm_utils.bzl`.

### SDK-to-TFM Compatibility

.NET SDKs are backward compatible: a newer SDK can build targets for older
framework versions. The mapping is:

| TFM                 | Minimum SDK Major Version |
| ------------------- | ------------------------- |
| `net10.0`           | 10                        |
| `net9.0`            | 9                         |
| `net8.0`            | 8                         |
| `net7.0`            | 7                         |
| `net6.0`            | 6                         |
| `netstandard2.1`    | 3                         |
| `netstandard2.0`    | 2                         |
| `netcoreapp3.1`     | 3                         |
| `net48` (Framework) | 5                         |

For example, an SDK version `10.0.100` (major version 10) can build `net10.0`,
`net9.0`, `net8.0`, all the way down to `netstandard2.0`.

### Validation Process

1. Extract the major version from each registered SDK version string
   (e.g., `"10.0.100"` -> `10`)
2. For each discovered TFM, find the minimum SDK major version required
3. Check if any registered toolchain meets or exceeds the requirement
4. Report uncovered TFMs with suggestions for which SDK version to add

### Error Behavior

When `toolchain_diagnostics = "strict"` (or `fail_on_missing_toolchain = True`),
the extension fails with a detailed message listing:

- Each uncovered TFM
- Which projects use it (up to 3 listed, plus count of remaining)
- Suggested SDK version to register

When diagnostics mode is `warn`, the same information is emitted as warnings and
included in generated diagnostics reports.

When diagnostics mode is `off`, toolchain coverage findings are suppressed.

### Multiple Toolchains

Users can register multiple toolchains for different SDK versions. The validation
tracks which toolchains cover which TFMs:

```starlark
dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(dotnet_version = "9.0.300")
dotnet.toolchain(name = "dotnet_10", dotnet_version = "10.0.100")

auto_dotnet = use_extension("@rules_auto_dotnet//auto_dotnet:extensions.bzl", "auto_dotnet")
auto_dotnet.toolchain(dotnet_version = "9.0.300")
auto_dotnet.toolchain(name = "dotnet_10", dotnet_version = "10.0.100")
auto_dotnet.scan_projects()
```

In this setup, `net10.0` is only covered by `dotnet_10`, while `net9.0` and `net8.0`
are covered by both toolchains.

## Gradual Adoption Pattern

Manual and generated targets can coexist in one repo and rely on the same
globally registered `rules_dotnet` toolchains:

```starlark
# MODULE.bazel
dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(dotnet_version = "10.0.100")
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

auto_dotnet = use_extension("@rules_auto_dotnet//auto_dotnet:extensions.bzl", "auto_dotnet")
auto_dotnet.toolchain(dotnet_version = "10.0.100")
auto_dotnet.scan_projects(
    toolchain_diagnostics = "warn",
)
use_repo(auto_dotnet, "dotnet_projects")
```

In BUILD files, user-authored targets and generated macros resolve through the
same registered toolchains.

### Coverage Report

A `TOOLCHAIN_COVERAGE.md` file is generated in the `@dotnet_projects` repository
summarizing the coverage, useful for debugging toolchain configuration.
