# Phase 0 Baseline Hardening Audit

## Purpose

This audit checks the current `rules_auto_dotnet` implementation against the
enterprise hardening standards in `AGENTS.md` before Paket and
InternalsVisibleTo feature work.

## Baseline Checks Run

- Static audit of repository-rule, parser, generator, and toolchain-validation paths.
- `bazel test //auto_dotnet/tests/...` (pass).
- Determinism-focused review of iteration order in generated outputs and reports.

## Immediate Fixes Applied During Phase 0

- Deterministic ordering in generator attribute emission:
  - `auto_dotnet/private/generator.bzl` now sorts additional attrs before writing.
- Deterministic ordering in toolchain coverage matching:
  - `auto_dotnet/private/tfm_utils.bzl` now iterates sorted TFMs and sorted toolchain names.
- Deterministic ordering in repository outputs/reports:
  - `auto_dotnet/private/dotnet_projects_repo.bzl` now sorts discovered project files.
  - Toolchain coverage markdown now uses sorted toolchain and TFM keys.
  - Generated subdirectory BUILD files now use sorted directory keys and sorted file lists.
  - Conflict report generation now uses sorted versions and sorted source project lists.
- Conflict model stabilization:
  - `auto_dotnet/private/nuget_collector.bzl` now emits sorted conflict versions and sources.
- Structured diagnostics baseline:
  - Added diagnostics mode controls in `scan_projects` and repository attrs:
    - `toolchain_diagnostics` (`off|warn|strict`)
    - `parser_diagnostics` (`off|warn|strict`)
    - `emit_diagnostics_report` (bool)
  - Added deterministic diagnostics artifacts:
    - `DIAGNOSTICS.md`
    - `diagnostics.json`
  - Added strict-mode failure aggregation at end of repository evaluation.
- Added baseline unit coverage for diagnostics helper behavior:
  - `auto_dotnet/tests/dotnet_projects_repo_test.bzl`
- Added malformed-input parser fixture coverage:
  - `auto_dotnet/tests/parser_test.bzl` now validates safe degradation for malformed XML.
- Added deterministic generation regression coverage:
  - `auto_dotnet/tests/generator_test.bzl` compares repeated generation output.
- Added malformed dependency metadata coverage:
  - `auto_dotnet/tests/nuget_collector_test.bzl` validates malformed versions and empty IDs degrade safely.
- Added synthetic scale-smoke fixtures:
  - `auto_dotnet/tests/scale_smoke_test.bzl` (1,000 diagnostics entries and 1,000 package entries).
  - Manual benchmark harness: `tools/phase0_scale_benchmark.sh`.

These are "must-fix baseline determinism" items and are now resolved.

## Gap Assessment

### Must-Fix Before Feature Completion

- Toolchain contract checks are still partial:
  - validation uses `auto_dotnet.toolchain(...)` metadata,
  - direct introspection of `rules_dotnet.toolchain(...)` declarations is not
    available from this extension context, so exact cross-extension drift checks
    are constrained.
  - mitigation is to keep a documented "single source of truth" model where
    rules_dotnet performs registration and auto_dotnet metadata is treated as
    validation input.

### Feature-Phase Gaps (Expected)

- No Paket project support yet:
  - no detection of `Paket.Restore.targets`,
  - no `paket.references` parsing.
- No explicit `InternalsVisibleTo` extraction or generation yet.
- No `internals_visible_to` diagnostics/reporting yet.

### Nice-to-Have Hardening Follow-Ups

- Add deterministic integration tests at repository-rule level (not only helper/generator level).
- Expand malformed-input fixtures beyond current XML/version cases (e.g., mixed encoding, unexpected XML namespaces, malformed lock/dependency side files).
- Expand synthetic scale coverage from current 1,000-entry smoke tests to multi-size
  benchmark matrix (100/500/1000 project-shaped fixtures).
- Expand repository-rule-focused tests from helper-level to full integration
  fixture checks for diagnostics report generation and policy modes.

## Benchmark Guardrail Command

Run manually (or in CI with machine-specific thresholds):

```bash
bash tools/phase0_scale_benchmark.sh 20
```

The default threshold is conservative to reduce host variance; teams can tune
it per CI class.

Initial local run result during Phase 0:

- `bash tools/phase0_scale_benchmark.sh 20` completed within threshold.

## Readiness Summary

- **Determinism baseline**: improved and acceptable for continuing.
- **Correctness/safety baseline**: acceptable for Phase 1 implementation start.
- **Enterprise diagnostics and policy controls**: baseline implemented
  (`diagnostics.json`, `DIAGNOSTICS.md`, mode controls). Additional test
  coverage is still needed.
- **Cross-platform verification**: met at baseline level. CI now includes a
  Windows/macOS/Linux smoke matrix for representative parser/generator targets.

## Phase 0 Exit Criteria Met

- Deterministic generation and deterministic diagnostics ordering are in place.
- Structured diagnostics artifacts (`diagnostics.json`, `DIAGNOSTICS.md`) are emitted.
- Diagnostics policy controls are available for toolchain/parser/paket/internals checks.
- Parser error handling remains non-fatal in warn/off modes and isolated per project.
- Baseline cross-platform coverage is enforced in CI (Linux/macOS/Windows).

## Cross-Platform Audit Snapshot

- **Implemented**:
  - Separate file discovery logic for Windows (PowerShell/cmd) and Unix (`find`).
  - Path normalization to forward slashes across parser/generator/repository code.
  - No new Unix-only assumptions introduced in core scanning/generation logic.
- **CI enforcement added**:
  - `.github/workflows/ci.yaml` includes `cross-platform-smoke` matrix on
    `ubuntu-latest`, `macos-latest`, and `windows-latest`.
  - Matrix runs representative targets:
    - `//auto_dotnet/tests:parser_test`
    - `//auto_dotnet/tests:generator_test`
