#!/usr/bin/env python3
"""Verify generated @dotnet_projects outputs for integration coverage."""

import pathlib
import sys


def assert_contains(path: pathlib.Path, needle: str) -> None:
    content = path.read_text(encoding="utf-8")
    if needle not in content:
        raise AssertionError(f"Expected to find {needle!r} in {path}")


def main() -> int:
    if len(sys.argv) != 7:
        raise SystemExit("expected 6 file path args")

    app_bzl = pathlib.Path(sys.argv[1])
    lib_bzl = pathlib.Path(sys.argv[2])
    core_bzl = pathlib.Path(sys.argv[3])
    core_tests_bzl = pathlib.Path(sys.argv[4])
    diag_json = pathlib.Path(sys.argv[5])
    diag_md = pathlib.Path(sys.argv[6])

    # App is a web SDK project and references Lib.
    assert_contains(app_bzl, 'project_sdk = "web"')
    assert_contains(app_bzl, "//src/lib:Lib")

    # Lib is Paket-based and should include paket + project-derived IVT.
    assert_contains(lib_bzl, 'project_sdk = "default"')
    assert_contains(lib_bzl, "@dotnet_projects.nuget//newtonsoft.json")
    assert_contains(lib_bzl, "@dotnet_projects.nuget//serilog")
    assert_contains(lib_bzl, "internals_visible_to = [")
    assert_contains(lib_bzl, '"//src/app:App"')

    # Core is referenced by CoreTests and should get derived IVT entry.
    assert_contains(core_bzl, "internals_visible_to = [")
    assert_contains(core_bzl, '"//src/tests:CoreTests"')

    # CoreTests should be default SDK and keep project dep.
    assert_contains(core_tests_bzl, 'project_sdk = "default"')
    assert_contains(core_tests_bzl, "//src/core:Core")

    # Diagnostics should include missing explicit InternalsVisibleTo warning for Core.
    assert_contains(diag_md, "[warning] [internals_visible_to] src/core/Core.csproj")
    assert_contains(diag_json, '"category":"internals_visible_to"')
    # Diagnostics should include missing paket.references warning.
    assert_contains(diag_md, "[warning] [paket] src/core/MissingPaket.csproj")
    assert_contains(diag_json, "Project imports Paket restore targets but no paket.references was found.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
