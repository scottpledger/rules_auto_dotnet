"Scale-smoke tests for Phase 0 hardening"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//auto_dotnet/private:dotnet_projects_repo.bzl",
    "sorted_diagnostics_for_test",
)
load("//auto_dotnet/private:nuget_collector.bzl", "create_nuget_collector")

def _diagnostics_scale_smoke_test_impl(ctx):
    env = unittest.begin(ctx)

    diagnostics = []
    for i in range(1000):
        diagnostics.append({
            "category": "parser",
            "severity": "warning",
            "project_path": "proj{}/app.csproj".format(1000 - i),
            "message": "synthetic error {}".format(i),
            "remediation": "",
        })

    sorted_diags = sorted_diagnostics_for_test(diagnostics)

    asserts.equals(env, 1000, len(sorted_diags))
    asserts.equals(env, "proj1/app.csproj", sorted_diags[0]["project_path"])
    asserts.equals(env, "proj999/app.csproj", sorted_diags[999]["project_path"])

    return unittest.end(env)

diagnostics_scale_smoke_test = unittest.make(_diagnostics_scale_smoke_test_impl)

def _nuget_collector_scale_smoke_test_impl(ctx):
    env = unittest.begin(ctx)

    collector = create_nuget_collector()
    for i in range(1000):
        collector.add_package(
            "Package{}".format(i),
            "{}.0.0".format((i % 10) + 1),
            "proj{}/app.csproj".format(i),
        )

    resolved = collector.resolve_packages()
    asserts.equals(env, 1000, len(resolved))
    asserts.equals(env, "Package0", resolved[0].id)
    asserts.equals(env, "Package999", resolved[999].id)

    return unittest.end(env)

nuget_collector_scale_smoke_test = unittest.make(_nuget_collector_scale_smoke_test_impl)

def scale_smoke_test_suite(name):
    unittest.suite(
        name,
        diagnostics_scale_smoke_test,
        nuget_collector_scale_smoke_test,
    )
