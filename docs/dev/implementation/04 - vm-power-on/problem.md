# Starting a Hyper-V VM idempotently

## Index

- [Context](#context)
- [Problem](#problem)
- [Scope](#scope)
- [Out of scope](#out-of-scope)
- [Design decisions](#design-decisions)
- [Acceptance criteria](#acceptance-criteria)

## Context

`Infrastructure.HyperV` owns the host-side VM primitives that downstream
infrastructure repos build on. Today the module covers SSH transport
([New-VmSshClient](../../../../Infrastructure.HyperV/Public/Ssh/New-VmSshClient.ps1),
[Invoke-SshClientCommand](../../../../Infrastructure.HyperV/Public/Ssh/Invoke-SshClientCommand.ps1)),
SSH readiness probing
([Test-VmSshPort](../../../../Infrastructure.HyperV/Public/Ssh/Test-VmSshPort.ps1),
[Wait-VmSshReady](../../../../Infrastructure.HyperV/Public/Ssh/Wait-VmSshReady.ps1)),
in-VM file transport, and environment-variable management. It does not own
**VM power state**: callers reach past the module to the native `Hyper-V`
cmdlets (`Get-VM`, `Start-VM`) when they need it.

The first concrete consumer is
[Infrastructure-GitHubRunners feature 04 (boot runners)](../../../../../Infrastructure-GitHubRunners/docs/dev/implementation/04%20-%20boot%20runners/problem.md):
after a workstation reboot, CI VMs are powered off and the GitHub runner
agents they host appear offline. The boot script needs to power those VMs
on and then continue with SSH-based reconciliation - so power-on and SSH
readiness sit on the critical path side by side.

## Problem

There is no module primitive for "start this VM if it is not already
running". The native `Start-VM` cmdlet is close, but using it directly from
downstream repos has consistent friction:

- **Not idempotent on state.** `Start-VM` against a `Running` VM throws or
  warns depending on platform version. Every caller ends up wrapping it
  with the same `Get-VM | where State` guard.
- **Saved-state handling is on the caller.** A VM in `Saved` state is
  resumed by `Start-VM` (it does the right thing) but a caller cannot tell
  from outside the cmdlet whether work was done. The intermediate state
  matters for logging and reporting.
- **No host-not-Hyper-V error story.** `Start-VM` from a machine without
  the Hyper-V role surfaces a `CommandNotFoundException`. Each consumer
  re-invents the actionable error message ("install / enable the Hyper-V
  PowerShell module").
- **Duplicated across consumers.** Every downstream repo that needs to
  bring a VM up reimplements the same five-line guard. Bug classes
  (e.g. mis-handled `Paused` state) then exist in N places.

There is also no composed "power on and wait for SSH" helper. Callers wire
this together themselves from `Start-VM` + `Wait-VmSshReady`, which is
fine, but the power-on half belongs in the module either way.

## Scope

Add one new public function to `Infrastructure.HyperV`:

- `Start-VmIfStopped` - idempotent VM power-on. Reads the current state
  via `Get-VM`, calls `Start-VM` when the state is `Off` or `Saved`, and
  no-ops when the state is `Running`. Returns an object describing the
  observed entry state and whether a start was issued, so the caller can
  log "started" vs "already running" without re-querying.

The function does **not** wait for SSH. Callers compose it with the
existing
[Wait-VmSshReady](../../../../Infrastructure.HyperV/Public/Ssh/Wait-VmSshReady.ps1)
when they want the VM to be reachable, not just powered on. Keeping the
two concerns separate mirrors how `Test-VmSshPort` and `Wait-VmSshReady`
are kept apart from `New-VmSshClient`.

Lives under a new `Public/Power/` folder next to `Ssh/`, `FileTransfer/`,
`FileServer/`, and `EnvVars/`.

## Out of scope

- **Stop / Save / Restart.** Symmetric counterparts (`Stop-VmIfRunning`,
  `Save-VmIfRunning`, `Restart-Vm`) are not introduced here. The first
  consumer only needs power-on; the other verbs go in when a real
  consumer needs them, not speculatively.
- **Waiting for SSH inside the power-on call.** Composed by the caller
  with the existing `Wait-VmSshReady`. Bundling the two would force every
  caller to either accept the SSH dependency or pass a "skip wait" flag;
  separation is cleaner.
- **Waiting for the guest OS to be "ready" beyond TCP-22.** The SSH-ready
  signal is what existing callers use; deeper readiness (services up,
  cloud-init done) belongs to the consumer, not the transport module.
- **VM creation / provisioning.** This is power-state management for VMs
  that already exist on the host. Creating, importing, or registering a
  VM is `Infrastructure-Vm-Provisioner`'s concern.
- **Cross-host (remote Hyper-V) targeting.** All current consumers run
  on the same host as the VMs. `-ComputerName` parity with native
  `Get-VM` / `Start-VM` is a future concern.
- **Concurrency / batching across many VMs.** The function is per-VM by
  design. A consumer that wants parallel power-on iterates and uses
  PowerShell job / runspace primitives at its own layer.

## Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Function name | `Start-VmIfStopped` | Says exactly what it does: starts the VM only if it is not already running. `Start-Vm` collides with the native `Hyper-V` cmdlet; `Resume-Vm` is wrong (the `Resume` verb is for paused VMs); `Initialize-Vm` is too broad. |
| Input | Single `-VmName` string parameter | Matches how every existing primitive in this module accepts a VM identifier (by name, not by VM object). Keeps the surface small. |
| Return shape | Object `{ VmName, EntryState, Action }` where `Action` is one of `Started`, `Resumed`, `AlreadyRunning` | Callers need to log per-VM what happened without re-querying state. `EntryState` records what was observed before any change; `Action` records what the function did. A bare `bool` was rejected because "did we issue a start" and "was it already running" are both useful and a single bool collapses them. |
| `Off` vs `Saved` handling | Both trigger `Start-VM`; `Action` distinguishes them (`Started` vs `Resumed`) | The cmdlet does the right thing in both cases; the distinction matters only for the log line. |
| `Paused` / `Stopping` / `Starting` / `Saving` | Throw with an actionable message naming the observed state | These are transient or operator-induced states. Auto-resuming a `Paused` VM (operator deliberately paused it) or racing a `Starting` VM (concurrent caller) is the wrong default; the safe default is to surface the state and let the operator decide. A consumer that wants to wait through `Starting` can wrap the call in a poll loop. |
| Hyper-V module missing | Throw a dedicated error pointing at `Install-WindowsFeature Hyper-V-PowerShell` (or the appropriate path per host SKU) | Same actionable-error pattern the SSH helpers use when `Renci.SshNet.dll` is missing. Avoids the bare `CommandNotFoundException` every consumer ends up wrapping. |
| Unknown VM | Throw with the VM name in the message | `Get-VM` already throws on unknown VMs; we let that propagate but wrap to include `VmName` cleanly. |
| Wait-for-SSH composition | Separate function (existing `Wait-VmSshReady`) | Keeps power-state and reachability orthogonal, mirrors how the rest of the module composes small primitives. A `-WaitForSsh` switch was rejected because it would force the caller to pass an IP / timeout to a function whose core job is power state. |
| Side effects on `Running` | None - no re-issue of `Start-VM` | Re-running must be a true no-op; observable side effects on the "already up" path would defeat the idempotence story. |
| Verbose logging | One `Write-Verbose` line per branch (`EntryState`, `Action`) | The caller renders the user-facing line from the return object; the module emits structured trace via `Write-Verbose` only. Same pattern as the file transport primitives. |

## Acceptance criteria

- `Start-VmIfStopped -VmName <name>` against a VM in state `Off`
  - issues `Start-VM`,
  - returns `{ VmName = <name>, EntryState = 'Off', Action = 'Started' }`.
- The same call against a VM in state `Saved`
  - issues `Start-VM`,
  - returns `{ ..., EntryState = 'Saved', Action = 'Resumed' }`.
- The same call against a VM in state `Running`
  - does not issue `Start-VM` (asserted by mock),
  - returns `{ ..., EntryState = 'Running', Action = 'AlreadyRunning' }`.
- The same call against a VM in state `Paused`, `Stopping`, `Starting`,
  or `Saving` throws an error whose message includes the VM name and the
  observed state, and does not call `Start-VM`.
- Calling against an unknown VM name throws an error whose message
  includes the VM name.
- When the `Hyper-V` PowerShell module is not available
  (`Get-VM` / `Start-VM` not in `Get-Command`), the function throws a
  dedicated error pointing the operator at the install / enable step,
  before any other work.
- Unit tests mock `Get-VM` and `Start-VM` and pin: which states trigger
  a start, which states throw, the return object shape, and the absence
  of a `Start-VM` call on the `Running` path.
- Module manifest exports `Start-VmIfStopped`; README documents it
  alongside the existing primitives in the function table. The
  `Module.Tests.ps1` parity check between `FunctionsToExport` and
  `Export-ModuleMember` continues to pass.
- No integration test is added: the function is a thin wrapper over
  native `Hyper-V` cmdlets that the integration harness (a Docker
  SSH target) cannot exercise. Unit tests with mocked cmdlets fully
  cover its behaviour.
