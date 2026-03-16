"Tests for dotnet_projects_repo diagnostics helpers"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//auto_dotnet/private:dotnet_projects_repo.bzl",
    "apply_parser_errors_for_test",
    "apply_policy_diagnostic_for_test",
    "diagnostics_mode_is_valid_for_test",
    "diagnostics_outputs_for_test",
    "merge_package_references_for_test",
    "parse_paket_references_for_test",
    "sorted_diagnostics_for_test",
)

def _validate_diagnostics_mode_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "off", diagnostics_mode_is_valid_for_test("off"))
    asserts.equals(env, "warn", diagnostics_mode_is_valid_for_test("warn"))
    asserts.equals(env, "strict", diagnostics_mode_is_valid_for_test("strict"))

    return unittest.end(env)

validate_diagnostics_mode_test = unittest.make(_validate_diagnostics_mode_test_impl)

def _sorted_diagnostics_test_impl(ctx):
    env = unittest.begin(ctx)

    diagnostics = [
        {
            "category": "toolchain_coverage",
            "severity": "warning",
            "project_path": "",
            "message": "missing toolchain",
            "remediation": "add one",
        },
        {
            "category": "parser",
            "severity": "warning",
            "project_path": "z/proj.csproj",
            "message": "bad xml",
            "remediation": "",
        },
        {
            "category": "parser",
            "severity": "warning",
            "project_path": "a/proj.csproj",
            "message": "bad xml",
            "remediation": "",
        },
    ]

    sorted_diags = sorted_diagnostics_for_test(diagnostics)

    asserts.equals(env, "a/proj.csproj", sorted_diags[0]["project_path"])
    asserts.equals(env, "z/proj.csproj", sorted_diags[1]["project_path"])
    asserts.equals(env, "", sorted_diags[2]["project_path"])

    return unittest.end(env)

sorted_diagnostics_test = unittest.make(_sorted_diagnostics_test_impl)

def _diagnostics_outputs_test_impl(ctx):
    env = unittest.begin(ctx)

    diagnostics = [
        {
            "category": "parser",
            "severity": "warning",
            "project_path": "b/proj.csproj",
            "message": "bad xml B",
            "remediation": "",
        },
        {
            "category": "parser",
            "severity": "warning",
            "project_path": "a/proj.csproj",
            "message": "bad xml A",
            "remediation": "fix xml",
        },
    ]

    outputs = diagnostics_outputs_for_test(diagnostics)

    asserts.true(env, outputs.json_content.startswith("["))
    asserts.true(env, "# Diagnostics Report" in outputs.markdown_content)
    asserts.true(env, "a/proj.csproj: bad xml A" in outputs.markdown_content)
    asserts.true(env, "b/proj.csproj: bad xml B" in outputs.markdown_content)
    asserts.true(env, "remediation: fix xml" in outputs.markdown_content)

    # Ensure sorted order in output list.
    asserts.equals(env, "a/proj.csproj", outputs.sorted_diagnostics[0]["project_path"])
    asserts.equals(env, "b/proj.csproj", outputs.sorted_diagnostics[1]["project_path"])

    return unittest.end(env)

diagnostics_outputs_test = unittest.make(_diagnostics_outputs_test_impl)

def _apply_parser_errors_test_impl(ctx):
    env = unittest.begin(ctx)

    warn_result = apply_parser_errors_for_test("warn", "foo/bar.csproj", ["bad xml"])
    asserts.equals(env, 1, len(warn_result.diagnostics))
    asserts.equals(env, "warning", warn_result.diagnostics[0]["severity"])
    asserts.equals(env, 0, len(warn_result.strict_failures))

    strict_result = apply_parser_errors_for_test("strict", "foo/bar.csproj", ["bad xml"])
    asserts.equals(env, 1, len(strict_result.diagnostics))
    asserts.equals(env, "error", strict_result.diagnostics[0]["severity"])
    asserts.equals(env, 1, len(strict_result.strict_failures))

    off_result = apply_parser_errors_for_test("off", "foo/bar.csproj", ["bad xml"])
    asserts.equals(env, 0, len(off_result.diagnostics))
    asserts.equals(env, 0, len(off_result.strict_failures))

    return unittest.end(env)

apply_parser_errors_test = unittest.make(_apply_parser_errors_test_impl)

def _paket_references_parse_test_impl(ctx):
    env = unittest.begin(ctx)

    parsed = parse_paket_references_for_test("""
# comment
nuget Newtonsoft.Json
Serilog
framework: net9.0
nuget Microsoft.Extensions.Logging >= 8.0.0
""")

    asserts.equals(env, ["Microsoft.Extensions.Logging", "Newtonsoft.Json", "Serilog"], parsed)

    return unittest.end(env)

paket_references_parse_test = unittest.make(_paket_references_parse_test_impl)

def _merge_package_references_test_impl(ctx):
    env = unittest.begin(ctx)

    existing = [
        struct(id = "Newtonsoft.Json", version = "13.0.3"),
    ]
    merged = merge_package_references_for_test(
        existing,
        ["Newtonsoft.Json", "Serilog"],
    )

    asserts.equals(env, 2, len(merged))
    asserts.equals(env, "Newtonsoft.Json", merged[0].id)
    asserts.equals(env, "13.0.3", merged[0].version)
    asserts.equals(env, "Serilog", merged[1].id)
    asserts.equals(env, "", merged[1].version)

    return unittest.end(env)

merge_package_references_test = unittest.make(_merge_package_references_test_impl)

def _policy_diagnostic_modes_test_impl(ctx):
    env = unittest.begin(ctx)

    off_result = apply_policy_diagnostic_for_test("off", "paket", "missing refs")
    asserts.equals(env, 0, len(off_result.diagnostics))
    asserts.equals(env, 0, len(off_result.strict_failures))

    warn_result = apply_policy_diagnostic_for_test("warn", "paket", "missing refs")
    asserts.equals(env, 1, len(warn_result.diagnostics))
    asserts.equals(env, "warning", warn_result.diagnostics[0]["severity"])
    asserts.equals(env, 0, len(warn_result.strict_failures))

    strict_result = apply_policy_diagnostic_for_test("strict", "paket", "missing refs")
    asserts.equals(env, 1, len(strict_result.diagnostics))
    asserts.equals(env, "error", strict_result.diagnostics[0]["severity"])
    asserts.equals(env, 1, len(strict_result.strict_failures))

    return unittest.end(env)

policy_diagnostic_modes_test = unittest.make(_policy_diagnostic_modes_test_impl)

def dotnet_projects_repo_test_suite(name):
    unittest.suite(
        name,
        validate_diagnostics_mode_test,
        sorted_diagnostics_test,
        diagnostics_outputs_test,
        apply_parser_errors_test,
        paket_references_parse_test,
        merge_package_references_test,
        policy_diagnostic_modes_test,
    )
