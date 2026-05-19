# Bulk VM file transfer

## Index

- [Context](#context)
- [Problem](#problem)
- [Scope](#scope)
- [Out of scope](#out-of-scope)
- [Design decisions](#design-decisions)
- [Acceptance criteria](#acceptance-criteria)

## Context

`Infrastructure.HyperV` already exposes a transport primitive,
[Copy-VmFiles](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFiles.ps1),
that copies host files to a Hyper-V VM over the local file server +
SSH. It is deliberately minimal: the caller supplies an explicit list
of `{ Source; Target; Owner?; Mode? }` entries, one entry per file.

## Problem

Callers that want to push many files (e.g. a directory of configs,
scripts, or jars) currently have to enumerate every file themselves
and build the entry list. There is no supported way to:

1. Select host files by wildcard (`*.json`, `bin\*.exe`, ...).
2. Push them in bulk without naming each target path individually.

This forces duplicated globbing code in every caller and makes the
common "drop these files into /opt/x on the VM" case verbose.

## Scope

Add a new public function in `Infrastructure.HyperV` that:

- Resolves a host-side wildcard pattern to a concrete file set.
- Supports an opt-in `-Recurse` switch for descending into
  subdirectories.
- Accepts a single `TargetDir` on the VM rather than per-file targets.
- Supports two target-mapping modes selected by a switch:
  - **Flatten** (default): every match lands at
    `<TargetDir>/<basename(source)>`. Name collisions abort.
  - **Preserve relative path** (`-PreserveRelativePath`): every match
    keeps its path relative to the resolved source root under
    `<TargetDir>`. Mirrors `rsync` / `scp -r` behaviour.
- Delegates the actual transfer to the existing
  [Copy-VmFiles](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFiles.ps1)
  primitive by translating resolved matches into its entry shape.
  This keeps the transport contract intact and avoids a second SSH
  code path.
- Accepts optional `Owner` / `Mode` applied uniformly to every
  resolved entry (same defaults as `Copy-VmFiles`).
- Performs a pre-flight validation pass on the resolved entry set
  **before** any SSH client is touched or any file-server interaction
  occurs. The pass fails fast with a single, descriptive error and
  guarantees that an invalid request never reaches the VM. It checks:
  - At least one file matched the pattern.
  - In flatten mode, no two matches share a basename (collision
    detection).
  - In `-PreserveRelativePath` mode, no two matches resolve to the
    same VM target path.
  - Every resolved source is a file (directories among matches are
    filtered out up-front; if `-Recurse` was not specified and the
    pattern only matched directories, that surfaces as the
    zero-files error).

## Out of scope

- VM-to-host or VM-to-VM transfers. Wildcard resolution is host-side
  only; remote globbing is not supported.
- Schema / policy enforcement on what files are allowed. Callers
  remain responsible for that, consistent with `Copy-VmFiles`'s
  current stance.
- Changes to `Copy-VmFiles` itself. The new function is a
  resolution layer on top of it.

## Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Where to glob | Host-side only, via `Get-ChildItem` | Keeps the function side-effect-free with respect to the VM; remote globbing would require a second protocol path. |
| Recursion | Opt-in via `-Recurse` | Matches PowerShell idioms; prevents surprise traversal of large trees. |
| Target mapping | Flatten by default, `-PreserveRelativePath` for tree copies | Covers both common cases ("drop these into one dir" vs "mirror this tree") without splitting into two functions. |
| Collision handling | Abort during pre-flight validation, before any SSH or file-server I/O | Fail-fast is consistent with `Copy-VmFiles`'s set-e semantics; running validation up-front guarantees an invalid request never produces a partial-write on the VM. |
| Pre-flight validation | All shape checks (zero matches, basename collisions, duplicate targets, directory filtering) run as one host-side pass before any transport step | Cheap host-side checks should not depend on a live VM; keeps the failure mode deterministic and reproducible without a target. |
| Transport | Delegate to `Copy-VmFiles` | Single source of truth for the SSH + file-server round-trip. |

## Acceptance criteria

- New public function exported from `Infrastructure.HyperV` resolves a
  host wildcard, with and without `-Recurse`, into the entries
  consumed by `Copy-VmFiles`.
- Flatten mode produces `<TargetDir>/<basename>` for every match.
- `-PreserveRelativePath` mode produces VM paths that mirror the host
  tree under `<TargetDir>`.
- `Owner` / `Mode` parameters propagate to every entry.
- Unit tests cover the pre-flight validation pass against a
  `Copy-VmFiles` mock. For every failure case the mock must be
  asserted **not** to have been called, proving the request was
  rejected before any transport step:
  - Zero matches against the host pattern.
  - Flatten-mode basename collision across different host
    subdirectories.
  - `-PreserveRelativePath` duplicate VM target paths.
  - Pattern that resolves only to directories (no files).
- Unit tests also assert the entries passed to the `Copy-VmFiles`
  mock for each successful mode / switch combination.
- Integration tests (Docker target) cover the practical scenarios
  end-to-end against a live target. For every case below, contents,
  ownership and mode are verified on the VM:
  - Non-recursive wildcard (`*.ext`) against a flat directory, flatten
    mode.
  - Recursive wildcard with `-Recurse`, flatten mode, across at least
    two directory levels.
  - Recursive wildcard with `-Recurse -PreserveRelativePath`, asserting
    that the host subtree is mirrored under `TargetDir` (including a
    nested file at depth >= 2).
  - Custom `Owner` and `Mode` propagate uniformly to every transferred
    file.
  - Pattern that includes directories among its matches copies only
    the files (directories are ignored, not transferred as empty).
