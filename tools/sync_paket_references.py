"""Synchronize per-project paket.references with direct PackageReference usage."""

from __future__ import annotations

import argparse
import os
import pathlib
import sys
import xml.etree.ElementTree as ET

_PROJECT_EXTS = (".csproj", ".fsproj")
_PRUNED_DIRS = {"bin", "obj", ".git", ".jj"}


def _tag_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def _is_paket_import(project_value: str) -> bool:
    normalized = project_value.replace("\\", "/").lower()
    return ".paket/paket.restore.targets" in normalized


def _parse_project(path: pathlib.Path) -> tuple[bool, list[str]]:
    tree = ET.parse(path)
    root = tree.getroot()
    uses_paket = False
    package_ids_by_norm: dict[str, str] = {}

    for elem in root.iter():
        tag = _tag_name(elem.tag)
        if tag == "Import":
            project_attr = (elem.attrib.get("Project") or "").strip()
            if project_attr and _is_paket_import(project_attr):
                uses_paket = True
        elif tag == "PackageReference":
            package_id = (elem.attrib.get("Include") or "").strip()
            if not package_id:
                continue
            normalized = package_id.lower()
            if normalized not in package_ids_by_norm:
                package_ids_by_norm[normalized] = package_id

    package_ids = [package_ids_by_norm[key] for key in sorted(package_ids_by_norm.keys())]
    return uses_paket, package_ids


def _parse_existing_paket_reference_ids(content: str) -> dict[str, str]:
    ids_by_norm: dict[str, str] = {}
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        package_id = ""
        if lower.startswith("nuget "):
            tokens = [token for token in line.split(" ") if token]
            if len(tokens) >= 2:
                package_id = tokens[1]
        elif " " not in line:
            package_id = line
        if not package_id:
            continue

        normalized = package_id.lower()
        if normalized not in ids_by_norm:
            ids_by_norm[normalized] = package_id
    return ids_by_norm


def _find_project_files(workspace: pathlib.Path) -> list[pathlib.Path]:
    projects: list[pathlib.Path] = []
    for root, dirs, files in os.walk(workspace):
        dirs[:] = sorted(
            [
                directory
                for directory in dirs
                if directory not in _PRUNED_DIRS and not directory.startswith("bazel-")
            ]
        )
        for filename in sorted(files):
            if filename.lower().endswith(_PROJECT_EXTS):
                projects.append(pathlib.Path(root) / filename)
    return projects


def sync_workspace(workspace: pathlib.Path, check_only: bool) -> tuple[int, list[str]]:
    messages: list[str] = []
    parse_errors: list[str] = []
    drift_detected = False
    updated_files = 0

    for project_file in _find_project_files(workspace):
        rel_project = project_file.relative_to(workspace).as_posix()
        try:
            uses_paket, package_ids = _parse_project(project_file)
        except ET.ParseError as exc:
            parse_errors.append(f"{rel_project}: XML parse error: {exc}")
            continue

        if not uses_paket:
            continue

        paket_refs_file = project_file.parent / "paket.references"
        existing_content = ""
        if paket_refs_file.exists():
            existing_content = paket_refs_file.read_text(encoding="utf-8")
        existing_ids_by_norm = _parse_existing_paket_reference_ids(existing_content)

        missing: list[str] = []
        for package_id in package_ids:
            if package_id.lower() not in existing_ids_by_norm:
                missing.append(package_id)

        if not missing:
            continue

        drift_detected = True
        rel_paket_refs = paket_refs_file.relative_to(workspace).as_posix()
        missing_sorted = sorted(missing, key=lambda value: value.lower())
        messages.append(
            f"{rel_paket_refs}: missing direct package references [{', '.join(missing_sorted)}]"
        )
        if check_only:
            continue

        if existing_content and not existing_content.endswith("\n"):
            existing_content += "\n"
        appended = "\n".join(missing_sorted) + "\n"
        paket_refs_file.write_text(existing_content + appended, encoding="utf-8")
        updated_files += 1

    if parse_errors:
        messages.extend([f"ERROR: {err}" for err in sorted(parse_errors)])
        return 2, messages
    if check_only and drift_detected:
        return 1, messages

    if check_only:
        messages.append("All Paket references are in sync.")
    else:
        messages.append(f"Updated {updated_files} paket.references file(s).")
    return 0, messages


def _resolve_workspace(arg_workspace: str | None) -> pathlib.Path:
    if arg_workspace:
        return pathlib.Path(arg_workspace).resolve()

    candidate = os.environ.get("BUILD_WORKING_DIRECTORY")
    if candidate:
        return pathlib.Path(candidate).resolve()
    return pathlib.Path.cwd().resolve()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Update paket.references with direct PackageReference dependencies."
    )
    parser.add_argument(
        "--workspace",
        help="Workspace root path. Defaults to BUILD_WORKING_DIRECTORY or current directory.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check-only mode; exit non-zero if references are out of sync.",
    )
    args = parser.parse_args(argv)

    workspace = _resolve_workspace(args.workspace)
    exit_code, messages = sync_workspace(workspace, check_only=args.check)
    for message in messages:
        print(message)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
