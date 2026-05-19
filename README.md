# Infrastructure.HyperV

PowerShell module providing Hyper-V VM utilities (SSH execution, host file
server) for infrastructure repos.

## Index

- [Overview](#overview)
- [Functions](#functions)
- [Usage](#usage)
- [Development](#development)
  - [Prerequisites](#prerequisites)
  - [Running Tests](#running-tests)
  - [CI](#ci)
  - [Release](#release)

## Overview

This module is extracted from `Infrastructure.Common` to give Hyper-V-specific
functions their own cohesion boundary. Everything in here assumes a Hyper-V VM
sitting on an internal switch that the Windows host can reach over SSH or HTTP.
It is published to PSGallery and consumed by other repos.

## Functions

| Function | Description |
|---|---|
| `New-VmSshClient` | Creates and connects a `Renci.SshNet.SshClient` using password authentication. Caller owns Disconnect/Dispose. |
| `Invoke-SshClientCommand` | Runs a shell command on a connected `SshClient` and returns `{ Output, Error, ExitStatus }`. |
| `Test-VmSshPort` | Single-shot TCP probe of an SSH port. Returns `$true` if the port accepted a connection within the timeout; strict superset of an ICMP ping for "should I SSH?". |
| `Wait-VmSshReady` | Polls `Test-VmSshPort` until the port comes up or a deadline expires. Returns `$true` on success, `$false` on timeout - never throws on the network path. |
| `Invoke-WithVmFileServer` | Runs a script block with a live HTTP file server bound to the Hyper-V internal switch; guarantees cleanup in a `finally`. |
| `Add-VmFileServerFile` | Stages a host-side file in the live server and returns its VM-reachable download URL. Idempotent by name + byte count. |
| `Copy-VmFiles` | Per-entry transport: stages each `{ Source, Target, Owner?, Mode? }` via the file server, then `mkdir -p` + `curl -fsSL -o` + `chown` + `chmod` under sudo on the VM. |
| `Copy-VmFilesByPattern` | Wildcard front-end to `Copy-VmFiles`. Expands a host-side pattern, validates host-side (no SSH on rejection), then forwards to `Copy-VmFiles`. |

SSH helpers require Posh-SSH's bundled `Renci.SshNet.dll` to be loaded into
the session - `Invoke-ModuleInstall -ModuleName 'Posh-SSH'` is the standard
way to do that. The module fails fast with an actionable message otherwise.

## Usage

```powershell
Install-Module -Name Infrastructure.HyperV -MinimumVersion 0.4.0
Import-Module Infrastructure.HyperV
```

## Development

### Prerequisites

Clone `Infrastructure-Common` at `.ci-common` once before running any local
test runner:

```powershell
git clone https://github.com/VitaliiAndreev/Infrastructure-Common .ci-common
```

### Running Tests

```powershell
# Unit tests
.\Run-Tests.ps1

# Integration tests (Docker host)
.\Run-IntegrationTests-InDocker.ps1

# Integration tests (Docker SSH target)
.\Run-IntegrationTests-AgainstDockerTarget.ps1
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
