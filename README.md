# Infrastructure.HyperV

PowerShell module providing Hyper-V VM utilities (SSH execution, host file
server) for infrastructure repos.

## Index

- [Overview](#overview)
- [Functions](#functions)
  - [SSH primitives](#ssh-primitives)
  - [Hyper-V host queries](#hyper-v-host-queries)
  - [Host file server](#host-file-server)
  - [File transfer](#file-transfer)
  - [Environment variables](#environment-variables)
  - [Schema validators](#schema-validators)
  - [VM install primitives](#vm-install-primitives)
- [Usage](#usage)
- [Development](#development)
  - [Prerequisites](#prerequisites)
  - [Running Tests](#running-tests)
  - [CI](#ci)
  - [Release](#release)

## Overview

This module is extracted from `Common.PowerShell` to give Hyper-V-specific
functions their own cohesion boundary. Everything in here assumes a Hyper-V VM
sitting on an internal switch that the Windows host can reach over SSH or HTTP.
It is published to PSGallery and consumed by other repos.

## Functions

### SSH primitives

Listed in workflow order: create a session, run commands, probe / wait for
readiness. `New-VmSshClientWithJump` and `New-VmSshTunnel` cover the
NAT-router topology where the host has no direct route to a VM; the other
cmdlets work the same whether the session is direct or jumped.

These cmdlets require Posh-SSH's bundled `Renci.SshNet.dll` to be loaded
into the session - `Invoke-ModuleInstall -ModuleName 'Posh-SSH'` is the
standard way to do that. The module fails fast with an actionable message
otherwise.

| Function | Description |
|---|---|
| `New-VmSshClient` | Creates and connects a `Renci.SshNet.SshClient` using password authentication. Caller owns Disconnect/Dispose. `-Timeout` (default 30s) caps the total Connect() wall-clock; the call is synchronous, so callers expecting a multi-minute wait should print a leading "this may take a few minutes" line. |
| `New-VmSshClientWithJump` | Opens an SSH session to a VM, transparently routing through a jump host when the supplied VM def carries a `_RouterVm` NoteProperty. Direct `New-VmSshClient` otherwise. Returns a session object with `Client`, `Tunnel`, and `Dispose()` so callers see a uniform shape across the two paths. |
| `New-VmSshTunnel` | Opens an SSH session to a jump host and configures a local TCP port forward (`Renci.SshNet.ForwardedPortLocal`) so traffic to `127.0.0.1:<assigned-port>` emerges at `<TargetIp>:<TargetPort>` on the far side. The returned object exposes `LocalHost`, `LocalPort`, `JumpClient`, `Forward`, and `Dispose()` for ordered teardown. Used when the host has no direct route into a VM's subnet (e.g. a workload behind a NAT router). |
| `Invoke-SshClientCommand` | Runs a shell command on a connected `SshClient` and returns `{ Output, Error, ExitStatus }`. |
| `Test-SshBanner` | Connects to `<Ip>:<Port>`, reads up to 16 bytes within a short budget (default 3s), and returns `$true` iff the bytes start with `"SSH-"`. The fix for the false-positive `Test-VmSshPort` produces through an SSH.NET `ForwardedPortLocal`: the local TCP socket accepts the moment `Start()` returns, before the workload on the far side has actually replied. Read the banner to confirm the far end is really serving SSH. |
| `Test-VmSshPort` | Single-shot TCP probe of an SSH port. Returns `$true` if the port accepted a connection within the timeout; strict superset of an ICMP ping for "should I SSH?". |
| `Wait-VmSshReady` | Polls `Test-VmSshPort` until the port comes up or a deadline expires. Returns `$true` on success, `$false` on timeout - never throws on the network path. |

### Hyper-V host queries

Host-side cmdlets that talk to Hyper-V (`Get-VM`, `Get-VMNetworkAdapter`,
`Start-VM`) rather than to the VM over SSH. Bridge the gap between "the VM
exists in Hyper-V" and "I have an IP / a routable host adapter to act on".

| Function | Description |
|---|---|
| `Get-VmKvpIpAddress` | Polls Hyper-V's KVP integration services (`Get-VMNetworkAdapter` + `.IPAddresses`) until the supplied VM reports an IPv4 address on the requested switch, then returns that address. `-SwitchName` discriminates between adapters on multi-NIC VMs (e.g. a router VM's external vs private). `-OnPoll` is fired once per "no IP yet" iteration so the caller drives progress UX. The discovery primitive every consumer of a DHCP-only VM needs once it has booted. |
| `Get-VmSwitchHostIp` | Returns the Windows host's IPv4 address on the same /24 as a supplied VM IP. Used to anchor an HTTP file server's bind to the adapter the VM (or its upstream router) can route to. |
| `Start-VmIfStopped` | Idempotent Hyper-V power-on by VM name. Starts an `Off` VM, resumes a `Saved` VM, no-ops on `Running`, and throws (without calling `Start-VM`) on transient states (`Paused`, `Stopping`, `Starting`, `Saving`) or any unrecognised state. Returns `{ VmName, EntryState, Action }` describing the transition. Pair with `Wait-VmSshReady` to bring a VM up and gate on sshd accepting connections. |

### Host file server

Spins up an `HttpListener` on a host adapter the VM can reach, so the VM
can `curl` host-staged artefacts during provisioning.

| Function | Description |
|---|---|
| `Invoke-WithVmFileServer` | Runs a script block with a live HTTP file server bound to the Hyper-V internal switch; guarantees cleanup in a `finally`. |
| `Add-VmFileServerFile` | Stages a host-side file in the live server and returns its VM-reachable download URL. Idempotent by name + byte count. |

### File transfer

VM-side transport built on top of the host file server above.

| Function | Description |
|---|---|
| `Copy-VmFiles` | Per-entry transport: stages each `{ Source, Target, Owner?, Mode? }` via the file server, then `mkdir -p` + `curl -fsSL -o` + `chown` + `chmod` under sudo on the VM. Re-runs reconcile against the VM (SHA-256 + owner + mode) and skip when all three match; pass `-NoSkipUnchanged` to force a write every time. |
| `Copy-VmFilesByPattern` | Wildcard front-end to `Copy-VmFiles`. Expands a host-side pattern, validates host-side (no SSH on rejection), then forwards to `Copy-VmFiles`. |

### Environment variables

| Function | Description |
|---|---|
| `Set-VmEnvironmentVariables` | Writes a sentinel-delimited managed block of `NAME="VALUE"` lines to `/etc/environment` on the VM, preserving every line outside the block. Required `-BlockName` parameter names the markers (`# BEGIN <name>` / `# END <name>`) so independent consumers can maintain their own blocks side by side in the same file. Reconciles against the existing block and skips when unchanged (default); pass `-NoSkipUnchanged` to force a write. An empty `Entries` array removes the managed block. Schema-validates via `Assert-VmEnvVarsField` before any SSH call. |

### Schema validators

Host-side validators for VM-def fields that map onto the file-transfer and
env-vars cmdlets above. Consumers run these before any SSH call so schema
errors surface synchronously with the operator's input.

| Function | Description |
|---|---|
| `Assert-VmFilesField` | Shared schema validator for a `files` array on a VM definition. Single-form entries (`{source, target, ...}`) by default; bulk-form entries (`{pattern, targetDir, recurse?, preserveRelativePath?}`) under `-AllowBulkEntries` for callers wired to `Copy-VmFilesByPattern`. Consumers extend the single form via `-AllowedSubFields` / `-PostEntryValidator`. |
| `Assert-VmEnvVarsField` | Shared schema validator for an `envVars` object on a VM definition. Shape is `{ blockName, entries }` (both required when `envVars` is present). `blockName` is a 1-128 char string from `[A-Za-z0-9._ -]` with no leading/trailing whitespace. Each entry is `{name, value}`; name must be a POSIX identifier (no `=`), value must be a non-empty string with no LF/CR/NUL, and names must be unique. Absent `envVars` is valid; an empty `entries` array is valid and the transport treats it as "remove the managed block". |

### VM install primitives

Single-round-trip cmdlets that install or uninstall small artefacts on a
running VM under sudo. All members of this family are idempotent and refuse
to silently clobber the wrong kind of object at the target path - data-loss
prevention is the headline behavioural contract.

| Function | Description |
|---|---|
| `New-VmSymlink` | Ensures `<Path>` is a symlink to `<Target>` under sudo. No-op when the symlink already points at the requested target; throws (without writing) when `<Path>` exists as a regular file, directory, or symlink to a different target. Path and target are validated host-side (absolute, no `..`, no NUL, no single quote) before any SSH call. |
| `Remove-VmSymlink` | Removes the symlink at `<Path>` under sudo. No-op when `<Path>` does not exist; throws (without deleting) when `<Path>` exists as a regular file, directory, or other non-symlink object. Path is validated host-side (absolute, no `..`, no NUL, no single quote) before any SSH call. |
| `Set-VmProfileDScript` | Writes a `/etc/profile.d/<Name>.sh` script on the VM under sudo via an atomic temp-file + `mv`. Byte-compares against the file currently on the VM and skips the write when unchanged (default); `-NoSkipUnchanged` forces a write. `Name` is validated host-side (`^[A-Za-z0-9._-]+$`, must not end in `.sh`); a trailing newline is appended to `Content` if missing so the snippet is not silently ignored by POSIX shells. The atomic-write tail (`tee` -> `chown root:root` -> `chmod 0644` -> `mv`) is the shared module-internal helper. |
| `Remove-VmProfileDScript` | Removes `/etc/profile.d/<Name>.sh` from the VM under sudo. No-op when the file is absent; mirrors `Set-VmProfileDScript` on the uninstall side and accepts the same `Name` shape (validated host-side before any SSH call). |
| `Remove-VmDirectory` | Removes a directory tree at `<Path>` on the VM via `sudo rm -rf --`. Gated by a hard-coded allowlist of safe parent prefixes (`/opt/`, `/var/lib/infra-provisioner/`, `/usr/local/share/`) and a defense-in-depth denylist of protected system paths; extension of either is a security-review decision. No-op when `<Path>` is absent; refuses to delete (without writing) when `<Path>` exists as a non-directory. Path is validated host-side (absolute, no `..`, no NUL, no single quote) before any SSH call. |
| `Stop-VmProcessesUsingPath` | Sends SIGTERM under sudo to every VM process whose open files, cwd, executable, or memory mappings touch `<Path>`, polls `kill -0` at 0.5s intervals for up to `<GraceSeconds>`, then escalates surviving PIDs to SIGKILL and polls for up to 5 more seconds (the kernel reap window). Returns `{ TerminatedPids, KilledPids, StillAlive }`: exited under SIGTERM, reaped after SIGKILL, and still unreaped (typically uninterruptible sleep). The scanner prefers `lsof +D`, falls back to `fuser -m`, then walks `/proc/*/{exe,cwd,maps}`. Non-empty `StillAlive` causes the cmdlet to throw. Path is validated host-side (absolute, no `..`, no NUL, no single quote) before any SSH call. |
| `Expand-VmTarball` | Stages a host-side `.tar.gz` via `Add-VmFileServerFile` and extracts it into `<Destination>` on the VM under sudo. One SSH round-trip: `sudo mktemp -d` for a sibling tempdir under the destination's parent, `curl -fsSL \| sudo tar -xzf - --strip-components=<n>`, write a SHA-256 marker (`<Destination>/.infra-hyperv-tarball.sha256`) into the tempdir, `sudo rm -rf` any existing destination, then `sudo mv` the tempdir into place so the swap is atomic. Skip-unchanged (default) compares the host-computed digest of the tarball against the existing marker and exits before any `curl` / `tar` when they match; `-NoSkipUnchanged` forces re-extract while still refreshing the marker. `Destination` is validated host-side (absolute, no `..`, no NUL, no single quote); `TarballPath` must exist on the host; `StripComponents` is a non-negative integer (default 0). |

## Usage

```powershell
Install-Module -Name Infrastructure.HyperV -MinimumVersion 0.11.0
Import-Module Infrastructure.HyperV
```

## Development

### Prerequisites

Clone `Common-PowerShell` at `.ci-common` once before running any local
test runner:

```powershell
git clone https://github.com/VitaliiAndreev/Common-PowerShell .ci-common
```

### Running Tests

```powershell
# Unit tests
.\scripts\Run-Tests.ps1

# Integration tests (Docker host)
.\scripts\Run-IntegrationTests-InDocker.ps1

# Integration tests (Docker SSH target)
.\scripts\Run-IntegrationTests-AgainstDockerTarget.ps1
```

### CI

Three thin CI workflows delegate to Common's reusable workflows:

| Workflow | Trigger | Calls |
|---|---|---|
| `ci.yml` | PR / manual | `ci-powershell.yml` |
| `ci-docker-host.yml` | PR / manual | `ci-powershell-docker-host.yml` |
| `ci-docker-target.yml` | PR / manual | `ci-powershell-docker-target.yml` |

### Release

Pushing a change to `Infrastructure.HyperV/Infrastructure.HyperV.psd1` on
`master` with a new `ModuleVersion` triggers `release.yml`, which:

1. Checks the version is new.
2. Runs all three CI workflows.
3. Tags the commit via Common's `tag.yml`.
4. Publishes to PSGallery via Common's `publish.yml`.
