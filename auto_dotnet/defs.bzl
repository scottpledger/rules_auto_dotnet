"""Public API surface is re-exported here.

Users should not load files under "/auto_dotnet/private"
"""

load(
    "//auto_dotnet/private:generated_props.bzl",
    _dotnet_generated_props = "dotnet_generated_props",
    _dotnet_generated_props_test = "dotnet_generated_props_test",
)

dotnet_generated_props = _dotnet_generated_props
dotnet_generated_props_test = _dotnet_generated_props_test
