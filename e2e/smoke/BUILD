"""Provides a simple way to test rules_auto_dotnet as an external workspace."""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_python//python:defs.bzl", "py_binary")

# Verify rules_auto_dotnet can be used as a dependency by building a target from it.
build_test(
    name = "smoke_test",
    targets = ["@rules_auto_dotnet//:package_metadata"],
)

py_binary(
    name = "integration_scan_projects_verify_bin",
    srcs = ["integration_scan_projects_verify.py"],
    main = "integration_scan_projects_verify.py",
)

genrule(
    name = "integration_scan_projects_verify",
    srcs = [
        "integration_scan_projects_verify.py",
        "@dotnet_projects//src/app:App.csproj.bzl",
        "@dotnet_projects//src/lib:Lib.csproj.bzl",
        "@dotnet_projects//src/core:Core.csproj.bzl",
        "@dotnet_projects//src/tests:CoreTests.csproj.bzl",
        "@dotnet_projects//src/core:MissingPaket.csproj.bzl",
        "@dotnet_projects//:diagnostics.json",
        "@dotnet_projects//:DIAGNOSTICS.md",
    ],
    outs = ["integration_scan_projects_verify.ok"],
    cmd = "$(location :integration_scan_projects_verify_bin) $(location @dotnet_projects//src/app:App.csproj.bzl) $(location @dotnet_projects//src/lib:Lib.csproj.bzl) $(location @dotnet_projects//src/core:Core.csproj.bzl) $(location @dotnet_projects//src/tests:CoreTests.csproj.bzl) $(location @dotnet_projects//:diagnostics.json) $(location @dotnet_projects//:DIAGNOSTICS.md) && echo OK > $@",
    cmd_bat = "$(location :integration_scan_projects_verify_bin) $(location @dotnet_projects//src/app:App.csproj.bzl) $(location @dotnet_projects//src/lib:Lib.csproj.bzl) $(location @dotnet_projects//src/core:Core.csproj.bzl) $(location @dotnet_projects//src/tests:CoreTests.csproj.bzl) $(location @dotnet_projects//:diagnostics.json) $(location @dotnet_projects//:DIAGNOSTICS.md) && echo OK > $@",
    tools = [":integration_scan_projects_verify_bin"],
)

build_test(
    name = "integration_scan_projects_test",
    targets = [":integration_scan_projects_verify"],
)

build_test(
    name = "dotnet_projects_files_exist_test",
    targets = [
        "@dotnet_projects//src/app:App.csproj.bzl",
        "@dotnet_projects//src/lib:Lib.csproj.bzl",
        "@dotnet_projects//src/core:Core.csproj.bzl",
        "@dotnet_projects//src/tests:CoreTests.csproj.bzl",
        "@dotnet_projects//:diagnostics.json",
        "@dotnet_projects//:DIAGNOSTICS.md",
    ],
)
