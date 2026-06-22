# Changelog

All notable changes to `Infrastructure.HyperV` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org).

Add entries under `[Unreleased]` as changes merge; at release the
`[Unreleased]` heading is promoted to the new version + date and a fresh
`[Unreleased]` is opened above it. Changes prior to 0.11.0 live in the git
history and the tag list.

## [Unreleased]

## [1.2.0] - 2026-06-21

### Added
- `New-RetryingSshClientWrapper`: wraps an SSH client with reconnect-and-
  retry on transient transport drops (the channel being reaped mid-command
  by a NAT/firewall middlebox), via `Invoke-WithRetry`. The belt to
  `New-VmSshClient`'s keepalive brace, now available to every consumer of
  this module rather than re-implemented per repo.

### Changed
- `RequiredModules` now declares `Common.PowerShell` (>= 8.1.0), which
  supplies the `Invoke-WithRetry` primitive the new wrapper uses.

## [1.1.0] - 2026-06-21

### Added
- `New-VmSshClient` and `New-VmSshClientWithJump` now accept a
  `-KeepAliveInterval` parameter (default 15s) that arms SSH.NET's
  keepalive timer. Keeps a long-lived session alive across the idle gaps
  between commands, where a NAT or firewall middlebox on the host<->VM
  path could otherwise drop an idle-looking connection and surface
  mid-command as "connection aborted by the server". Pass
  `[TimeSpan]::Zero` to restore the previous no-keepalive behaviour.
- `New-VmSshClient` now accepts an optional `-Port` parameter (default
  22). `New-VmSshClientWithJump`'s tunnelled path uses it to reach the
  local-forward's ephemeral loopback port through the shared helper
  instead of hand-building a `ConnectionInfo`, so the connect/keepalive
  policy has a single home.

## [1.0.0] - 2026-06-17

### Changed
- Major version bump; no functional changes (version realignment).

## [0.11.0] - 2026-06-09

### Added
- Baseline changelog. This section pins the current released surface so the
  release pipeline's changelog gate and GitHub Release have notes to anchor
  on; earlier history remains in the git log and tag list.

### Notes
- Public surface: a Hyper-V guest-VM toolkit - file transfer
  (`Copy-VmFiles`, `Copy-VmFilesByPattern`, `Add-VmFileServerFile`,
  `Expand-VmTarball`, `Invoke-WithVmFileServer`), SSH client / tunnel / jump
  (`New-VmSshClient`, `New-VmSshClientWithJump`, `New-VmSshTunnel`,
  `Invoke-SshClientCommand`), guest IP discovery (`Get-VmKvpIpAddress`,
  `Get-VmSwitchHostIp`), and symlink / environment-variable / directory
  management (`New-VmSymlink`, `Remove-VmSymlink`,
  `Set-VmEnvironmentVariables`, `Remove-VmDirectory`, ...). See the README
  function reference for the full list.

[Unreleased]: https://github.com/Klark-Morrigan/Infrastructure-HyperV/compare/1.0.0...HEAD
[1.0.0]: https://github.com/Klark-Morrigan/Infrastructure-HyperV/compare/0.11.0...1.0.0
[0.11.0]: https://github.com/Klark-Morrigan/Infrastructure-HyperV/compare/0.10.1...0.11.0
