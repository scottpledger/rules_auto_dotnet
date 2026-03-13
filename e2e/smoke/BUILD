"""Provides a simple way to test rules_auto_dotnet as an external workspace."""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

# Verify rules_auto_dotnet can be used as a dependency by building a target from it.
build_test(
    name = "smoke_test",
    targets = ["@rules_auto_dotnet//:package_metadata"],
)
