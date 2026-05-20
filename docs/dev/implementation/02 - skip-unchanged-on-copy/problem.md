# Skip unchanged files on Copy-VmFiles

## Index

- [Context](#context)
- [Problem](#problem)
- [Scope](#scope)
- [Out of scope](#out-of-scope)
- [Design decisions](#design-decisions)
- [Acceptance criteria](#acceptance-criteria)

## Context

[Copy-VmFiles](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFiles.ps1)
is the transport primitive every file-shipping caller in the module
funnels through, including the bulk
[Copy-VmFilesByPattern](../../../../Infrastructure.HyperV/Public/FileTransfer/Copy-VmFilesByPattern.ps1)
wrapper added in
[01 - bulk-vm-file-transfer](../01%20-%20bulk-vm-file-transfer/problem.md).
Per entry it runs, under sudo on the VM, an unconditional sequence:
`mkdir -p` of the parent, `curl -fsSL -o` of the staged URL, `chown`,
`chmod`. That happens every run, regardless of whether the VM already
holds the same bytes with the same owner and mode.

The host-side staging step
([Add-VmFileServerFile](../../../../Infrastructure.HyperV/Public/FileServer/Add-VmFileServerFile.ps1))
already short-circuits on name + byte count, but its idempotence only
covers the host->staging copy, not the VM-side write.

## Problem

Per-entry overhead is dominated by SSH round-trips, not by bytes on the
wire (the Hyper-V internal switch moves hundreds of MB in seconds, but
each sudo command pays ~50-200 ms of round-trip + auth). The current
shape is four sudo commands per file:

1. `sudo mkdir -p`
2. `sudo curl -fsSL -o ...`
3. `sudo chown ...`
4. `sudo chmod ...`

For a re-provision where nothing changed (the common case for vendored
JARs, configs, scripts), all four steps are pure waste. With 200
entries that is ~40-160 s of unnecessary overhead per re-provision, on
top of the bytes themselves. The single-file form pays this per entry;
the bulk form pays it per resolved match, which makes the cost grow
with the size of the matched set rather than with the size of the
config.

## Scope

Make `Copy-VmFiles` reconcile each entry against the VM before
transferring. A successful skip means the VM-side state already matches
the requested content and metadata; nothing is downloaded and nothing
is mutated.

Per-entry algorithm, single SSH round-trip:

1. The function computes the source SHA-256 host-side once per entry
   (cheap relative to even one SSH round-trip).
2. The remote script runs `sha256sum` on the target and `stat -c
   '%U:%G %a'` for owner + mode. If both match the desired values, it
   `exit 0`s before any write.
3. Otherwise it falls through to the existing `mkdir -p` + `curl` +
   `chown` + `chmod` sequence, unchanged.

The skip decision and the write happen in **the same remote script**
so the whole reconcile-or-write becomes one round-trip per entry
instead of four. No second SSH command, no host-side branching.

Surface changes:

- `Copy-VmFiles` adds an opt-out switch (e.g. `-NoSkipUnchanged`) that
  forces the current always-write behaviour. Default is the new
  skip-unchanged path because it is strictly cheaper and produces the
  same observable state.
- Public signatures of `Copy-VmFiles` and `Copy-VmFilesByPattern`
  otherwise unchanged. The bulk form inherits the optimisation for
  free because it forwards entries through the same primitive.
- `Add-VmFileServerFile` staging is unchanged. Staging cost is paid
  once per host file regardless and is cheap.

## Out of scope

- Pruning files under `targetDir` that no longer match a bulk pattern.
  Separate concern (different intent, different surface). Tracked in
  [Vm-Provisioner's bulk-pattern problem](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/07%20-%20ci%20jars/problem.md#out-of-scope)
  as a future opt-in flag.
- Caching SHA values across runs. The remote `sha256sum` is computed
  per entry per run; a multi-run cache is a separate optimisation
  with its own invalidation problems.
- Smarter staging on the host side. Re-staging is already idempotent
  on name + byte count and is not on the slow path.
- Schema changes in any consumer repo. This is a transport-layer
  optimisation; the `files` schema does not move.
- Parallel transfer. Reconciling sequentially is enough to remove the
  bulk of the overhead; concurrency is a separate trade-off (output
  interleaving, error semantics) and not blocked by this change.

## Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Where the skip decision lives | Inside the single remote script per entry, alongside the write | One round-trip per entry whether the file is up to date or not; no host-side branching that doubles SSH traffic. |
| Hash algorithm | `sha256sum` | Available on every supported Ubuntu image; collision-resistant enough that "same hash" means "same bytes" in practice; aligned with how the project already thinks about content identity. |
| Where the host-side hash is computed | In `Copy-VmFiles`, per entry, just before the SSH call | Keeps the staging layer unchanged; pays the hash exactly when the transport needs it. |
| Default behaviour | Skip-unchanged on by default; `-NoSkipUnchanged` opts out | The new path produces the same observable VM state as the old one at lower cost. Callers that genuinely want to force a re-write (e.g. recovering from out-of-band tampering) keep an explicit escape hatch. |
| Comparison surface | Hash + owner + mode | The current contract pins all three. Skipping when any of them differs would silently let drift persist. |
| First-run cost | Unchanged write path runs as today, plus one `sha256sum` call per entry | First-run pays a small constant overhead in exchange for cheap re-runs. Break-even is "any unchanged file on any re-run." |
| Visibility into skips | None beyond debug logging | A counter / per-entry log adds noise to the common case. Failure paths still throw exactly as they do today. |

## Acceptance criteria

- `Copy-VmFiles` with `-NoSkipUnchanged` behaves bit-for-bit as it
  does today: every entry triggers `mkdir -p` + `curl` + `chown` +
  `chmod`. Existing tests for the always-write path pass unchanged
  when the switch is set.
- Default `Copy-VmFiles` produces the same VM state as today for
  every input that previously succeeded. Asserted in integration
  tests by running the function twice against the same target and
  diffing the resulting tree.
- A re-run against a VM that already holds the desired content,
  owner and mode does not invoke `curl`, `chown` or `chmod`.
  Asserted in integration tests by `stat`-ing mtime before and after
  the second run and observing it unchanged.
- A re-run where the target's content differs (host file edited)
  re-writes the target. Asserted by mutating the host source between
  two runs and verifying the VM contents update.
- A re-run where only the owner or only the mode differs re-applies
  the metadata. Two integration-test cases, one per dimension.
- A re-run where the target does not exist falls through to the
  full write path. Covered by first-run integration test.
- `Copy-VmFilesByPattern` inherits the optimisation with no test or
  signature change of its own. Existing integration tests for the
  bulk form continue to pass.
- Unit tests assert that the remote script emitted by `Copy-VmFiles`
  contains the hash + stat comparison and the early `exit 0`, and
  that the `-NoSkipUnchanged` switch suppresses that block.
- README mentions the skip-unchanged default in the
  `Copy-VmFiles` row, and the `-NoSkipUnchanged` opt-out next to it,
  with no new top-level section (this is a refinement of an existing
  function, not a new public surface).
