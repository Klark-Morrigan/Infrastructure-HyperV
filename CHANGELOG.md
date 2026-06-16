# Changelog

All notable changes to `Infrastructure.HyperV` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org).

Add entries under `[Unreleased]` as changes merge; at release the
`[Unreleased]` heading is promoted to the new version + date and a fresh
`[Unreleased]` is opened above it. Changes prior to 0.11.0 live in the git
history and the tag list.

## [Unreleased]

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

[Unreleased]: https://github.com/VitaliiAndreev/Infrastructure-HyperV/compare/0.11.0...HEAD
[0.11.0]: https://github.com/VitaliiAndreev/Infrastructure-HyperV/compare/0.10.1...0.11.0
