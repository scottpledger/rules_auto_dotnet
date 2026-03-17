"""Unit tests for sync_paket_references."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

from tools.sync_paket_references import sync_workspace


_PROJECT_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<Project Sdk="Microsoft.NET.Sdk">
  <Import Project="../../.paket/Paket.Restore.targets" />
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
    <PackageReference Include="Serilog" Version="4.0.0" />
  </ItemGroup>
</Project>
"""


class SyncPaketReferencesTest(unittest.TestCase):
    def test_check_mode_reports_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            project_dir = root / "src" / "lib"
            project_dir.mkdir(parents=True, exist_ok=True)
            (project_dir / "Lib.csproj").write_text(_PROJECT_TEMPLATE, encoding="utf-8")
            (project_dir / "paket.references").write_text("Newtonsoft.Json\n", encoding="utf-8")

            exit_code, messages = sync_workspace(root, check_only=True)

            self.assertEqual(1, exit_code)
            self.assertTrue(any("Serilog" in message for message in messages))

    def test_apply_mode_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            project_dir = root / "src" / "lib"
            project_dir.mkdir(parents=True, exist_ok=True)
            (project_dir / "Lib.csproj").write_text(_PROJECT_TEMPLATE, encoding="utf-8")
            paket_refs = project_dir / "paket.references"
            paket_refs.write_text("Newtonsoft.Json\n", encoding="utf-8")

            first_exit, _ = sync_workspace(root, check_only=False)
            first_content = paket_refs.read_text(encoding="utf-8")
            second_exit, _ = sync_workspace(root, check_only=False)
            second_content = paket_refs.read_text(encoding="utf-8")

            self.assertEqual(0, first_exit)
            self.assertEqual(0, second_exit)
            self.assertEqual(first_content, second_content)
            self.assertIn("Serilog", first_content)


if __name__ == "__main__":
    unittest.main()
