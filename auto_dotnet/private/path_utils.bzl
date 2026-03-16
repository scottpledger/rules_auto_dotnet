"Shared path helpers for project scanning and generation"

load("@bazel_skylib//lib:paths.bzl", "paths")

def resolve_relative_path(base_dir, rel_path):
    """Resolve a relative path against a base directory.

    Args:
        base_dir: Base directory path.
        rel_path: Relative path to resolve.

    Returns:
        Normalized resolved path, "" for root, or None if invalid/outside root.
    """
    if not rel_path:
        return None

    normalized_rel = rel_path.replace("\\", "/")
    joined = paths.join(base_dir, normalized_rel) if base_dir else normalized_rel
    normalized = paths.normalize(joined)

    if normalized.startswith(".."):
        return None
    if normalized == ".":
        return ""

    return normalized
