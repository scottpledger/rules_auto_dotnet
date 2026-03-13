# AI Agent Guidance

## Project Overview

`rules_auto_dotnet` is a Bazel module extension that scans `.csproj` and `.fsproj`
files and generates Bazel targets using
[rules_dotnet](https://github.com/bazel-contrib/rules_dotnet). It does **not**
provide its own toolchain -- it depends on rules_dotnet for build rules and .NET
SDK toolchains.

## Language and Tooling

- **Primary language**: Starlark (`.bzl` files) -- Bazel's configuration language
- **XML parsing**: Uses `xml.bzl` (a pure-Starlark XML parser) for .csproj/.fsproj
- **Path utilities**: `@bazel_skylib//lib:paths` for path manipulation
- **Glob matching**: `@bazel_lib//lib:glob_match` for exclude pattern filtering
- **Formatting**: All Starlark files must be formatted with
  [buildifier](https://github.com/bazelbuild/buildtools/tree/master/buildifier)
- **BUILD file generation**: `bzl_library` targets are maintained manually

## Directory Structure

```
auto_dotnet/              # Public API surface
  defs.bzl                # User-facing rule re-exports
  extensions.bzl          # Module extension (scan_projects)
  BUILD.bazel             # bzl_library targets

auto_dotnet/private/      # Implementation (not for direct user consumption)
  parser.bzl              # XML project file parser
  generator.bzl           # .bzl code generator
  nuget_collector.bzl     # NuGet package aggregation
  tfm_utils.bzl           # TFM-to-SDK version mapping
  dotnet_projects_repo.bzl # Repository rule (orchestrator)
  generated_props.bzl     # IDE .props file generation
  BUILD.bazel

auto_dotnet/tests/        # Unit tests
  parser_test.bzl
  generator_test.bzl
  nuget_collector_test.bzl
  tfm_utils_test.bzl
  BUILD.bazel

e2e/smoke/                # End-to-end smoke test (external workspace)
docs/design/              # Architecture and design documentation
```

## Key Patterns

### Repository Rules

The core scanning logic runs as a **repository rule** (`dotnet_projects_repo`)
during Bazel's loading phase. Repository rules can execute shell commands
(`repository_ctx.execute`), read files (`repository_ctx.read`), and write files
(`repository_ctx.file`), but cannot use Bazel's action graph.

### Module Extensions

The user-facing API is a **module extension** (`auto_dotnet`) defined in
`extensions.bzl`. Extensions process tag classes from `MODULE.bazel` and create
repositories.

### bzl_library Targets

Every `.bzl` file should have a corresponding `bzl_library` target in its
`BUILD.bazel`. These are used for documentation generation and dependency
tracking. Update them manually when adding or modifying .bzl files.

### Load Path Conventions

- Internal loads within `auto_dotnet/private/` use relative `:` syntax
  (e.g., `load(":parser.bzl", ...)`)
- Cross-package loads use full labels
  (e.g., `load("//auto_dotnet/private:parser.bzl", ...)`)
- Generated code references upstream rules via
  `load("@rules_dotnet//dotnet:defs.bzl", ...)`

## Testing

Tests use `@bazel_skylib//lib:unittest.bzl` with the `unittest.suite` pattern:

```starlark
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

def _my_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, expected, actual)
    return unittest.end(env)

my_test = unittest.make(_my_test_impl)

def my_test_suite(name):
    unittest.suite(name, my_test)
```

Each test file defines a `*_test_suite` function loaded in `BUILD.bazel`.

## Build and Test Commands

```bash
bazel test //...                    # Run all tests
bazel test //auto_dotnet/tests/...  # Run unit tests only
bazel test //e2e/smoke/...          # Run smoke test
```

## Dependencies

- `rules_dotnet` -- .NET build rules and SDK toolchains (runtime dependency)
- `bazel_skylib` -- Starlark utility libraries and test framework
- `bazel_lib` -- `glob_match`, `write_source_files`, `bzl_library`
- `xml.bzl` -- Pure-Starlark XML parser
- `platforms` -- Platform constraint definitions

## Important Notes

- This module is **bzlmod-only** (no WORKSPACE support)
- Requires **Bazel 7.1+** for `repository_ctx.workspace_root`
- The `@dotnet_projects` repository is generated at loading time; it's not
  checked into version control
- All generated `.bzl` files load rules from `@rules_dotnet`, not from this repo
