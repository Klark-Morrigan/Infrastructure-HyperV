<#
.SYNOPSIS
    Hyper-V VM utilities for infrastructure repos.

.DESCRIPTION
    Provides VM-facing functions extracted from Common.PowerShell to
    keep each module cohesive and single-purpose. All functions in this
    module assume a Hyper-V VM on an internal switch that the host can
    reach over SSH or HTTP.

    Current functions:
      - Add-VmFileServerFile    : stages a host file and returns its VM URL
      - Assert-VmFilesField     : shared schema validator for a 'files' array
                                  on a VM definition; consumers extend via
                                  -AllowedSubFields and -PostEntryValidator
      - Assert-VmEnvVarsField   : shared schema validator for an 'envVars'
                                  array on a VM definition; fixed rule set
                                  (POSIX-identifier name, non-empty value
                                  with no LF/CR/NUL, no duplicate names)
      - Copy-VmFiles            : per-entry transport (Add-VmFileServerFile +
                                  curl -o + chown + chmod under sudo); each
                                  entry is { Source, Target, Owner?, Mode? }
      - Copy-VmFilesByPattern   : wildcard front-end to Copy-VmFiles; expands
                                  a host-side pattern, validates host-side,
                                  then forwards to Copy-VmFiles
      - Expand-VmTarball        : stages a host-side .tar.gz via the file
                                  server and extracts it into Destination
                                  on the VM under sudo via an atomic
                                  mktemp + curl|tar + mv (skip-unchanged
                                  marker lands in a follow-up step)
      - Get-VmKvpIpAddress      : polls Hyper-V KVP integration services
                                  for a VM's IPv4 address on a named
                                  switch; the discovery primitive every
                                  caller of a DHCP-only VM needs once
                                  it has booted
      - Get-VmSwitchHostIp      : returns the Windows host's IPv4 on
                                  the same /24 as a supplied VM IP -
                                  used to anchor an HTTP file server's
                                  bind to the adapter the VM (or its
                                  upstream router) can route to
      - Invoke-SshClientCommand : runs a shell command via SSH.NET SshClient
      - Invoke-WithVmFileServer : runs a script block with a live HTTP file
                                  server bound to the Hyper-V internal switch
      - New-VmSshClient         : creates and connects a SSH.NET SshClient
      - New-VmSshClientWithJump : opens an SSH session to a VM,
                                  transparently routing through a jump
                                  host when the VM def carries
                                  _RouterVm (feature-53 NAT topology)
      - New-VmSshTunnel         : opens an SSH session to a jump host
                                  and configures a local TCP port
                                  forward (SSH.NET ForwardedPortLocal)
                                  so callers reach a VM the host has
                                  no direct route to
      - New-VmSymlink           : idempotent symlink creation under sudo;
                                  fails if Path exists as anything other
                                  than a matching symlink (data-loss
                                  guard) - first of the "VM install
                                  primitives" family
      - Remove-VmDirectory      : idempotent removal of a directory tree
                                  on a VM under sudo, gated by a
                                  hard-coded allowlist of safe parent
                                  prefixes. Refuses to delete a
                                  non-directory at the target path
                                  (data-loss guard)
      - Remove-VmProfileDScript : idempotent removal of a
                                  /etc/profile.d/<Name>.sh script
                                  under sudo. No-op when the target
                                  is absent; mirrors
                                  Set-VmProfileDScript on the
                                  uninstall side
      - Remove-VmSymlink        : idempotent symlink removal under sudo;
                                  no-op when Path is absent, refuses to
                                  delete anything that is not a symlink
                                  (data-loss guard)
      - Set-VmEnvironmentVariables : writes a sentinel-delimited managed
                                  block of NAME="VALUE" lines to
                                  /etc/environment on the VM. Reconciles
                                  against the existing block and skips
                                  when unchanged (default);
                                  -NoSkipUnchanged forces a write. Empty
                                  entries array removes the managed block
      - Set-VmProfileDScript    : writes a /etc/profile.d/<Name>.sh
                                  shell snippet on the VM under sudo
                                  via an atomic temp-file + mv. Byte-
                                  compares against the existing file
                                  and skips when unchanged (default);
                                  -NoSkipUnchanged forces a write
      - Start-VmIfStopped       : idempotent Hyper-V power-on. Starts Off /
                                  resumes Saved / no-ops on Running; throws
                                  on transient or unrecognised states. Pair
                                  with Wait-VmSshReady for "up and reachable"
      - Stop-VmProcessesUsingPath : sends SIGTERM (this step) to every
                                  VM process holding a given path open,
                                  waits a caller-specified grace
                                  period, and reports survivors. The
                                  SIGKILL fallback lands in a follow-up
                                  step; KilledPids in the result is
                                  always empty until then
      - Test-SshBanner          : connects to <Ip>:<Port> and reads up
                                  to 16 bytes within a short budget;
                                  returns $true iff the bytes start
                                  with "SSH-". Beats a TCP-only probe
                                  through a jump tunnel because SSH.NET
                                  accepts the local socket before the
                                  workload has actually replied
      - Test-VmSshPort          : single-shot TCP probe of an SSH port; the
                                  ICMP-ping replacement for callers that
                                  intend to SSH immediately afterwards
      - Wait-VmSshReady         : polls Test-VmSshPort until the port comes
                                  up or a deadline expires; used to gate
                                  post-boot/reboot SSH work

    Private helpers (Assert-HyperVModuleLoaded, Assert-PsModuleLoaded,
    Assert-SshNetLoaded, Start-VmFileServer, Stop-VmFileServer) are
    dot-sourced below but not exported.

    Functions are grouped by concern under Public\ and Private\ into
    subfolders that share a name across the two trees:
      - EnvVars\      : VM-side system environment variable management.
      - FileServer\   : host-side HTTP file server used to stage VM downloads,
                        plus VM-side tarball extraction primitive.
      - Filesystem\   : VM-side directory-tree removal primitives gated by
                        a hard-coded allowlist of safe parent prefixes.
      - FileTransfer\ : VM-side transport on top of Ssh + FileServer.
      - PsModules\    : guards that ensure a PowerShell module prerequisite
                        is installed and in scope before the caller runs.
      - Power\        : Hyper-V power-state management (start / resume).
      - Processes\    : VM-side process termination primitives keyed by
                        filesystem path holders.
      - ProfileD\     : VM-side /etc/profile.d/*.sh install primitives.
      - Ssh\          : SSH client + port-probe primitives.
      - Symlinks\     : VM-side symbolic-link install / uninstall primitives.
    Each function still lives in its own file so diffs stay focused on a
    single function per commit.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Private functions:

. "$PSScriptRoot\Private\Bash\New-AtomicWriteBashFragment.ps1"

. "$PSScriptRoot\Private\FileServer\Start-VmFileServer.ps1"
. "$PSScriptRoot\Private\FileServer\Stop-VmFileServer.ps1"

. "$PSScriptRoot\Private\FileTransfer\Assert-VmFileBulkEntry.ps1"
. "$PSScriptRoot\Private\FileTransfer\Assert-VmFileSingleEntry.ps1"
. "$PSScriptRoot\Private\FileTransfer\Resolve-VmFileEntries.ps1"

. "$PSScriptRoot\Private\Power\Assert-HyperVModuleLoaded.ps1"

. "$PSScriptRoot\Private\ProfileD\Assert-VmProfileDScriptName.ps1"

. "$PSScriptRoot\Private\PsModules\Assert-PsModuleLoaded.ps1"

. "$PSScriptRoot\Private\Ssh\Assert-SshNetLoaded.ps1"

# Public functions:

. "$PSScriptRoot\Public\EnvVars\Assert-VmEnvVarsField.ps1"
. "$PSScriptRoot\Public\EnvVars\Set-VmEnvironmentVariables.ps1"

. "$PSScriptRoot\Public\FileServer\Add-VmFileServerFile.ps1"
. "$PSScriptRoot\Public\FileServer\Expand-VmTarball.ps1"
. "$PSScriptRoot\Public\FileServer\Get-VmSwitchHostIp.ps1"
. "$PSScriptRoot\Public\FileServer\Invoke-WithVmFileServer.ps1"

. "$PSScriptRoot\Public\Filesystem\Remove-VmDirectory.ps1"

. "$PSScriptRoot\Public\FileTransfer\Assert-VmFilesField.ps1"
. "$PSScriptRoot\Public\FileTransfer\Copy-VmFiles.ps1"
. "$PSScriptRoot\Public\FileTransfer\Copy-VmFilesByPattern.ps1"

. "$PSScriptRoot\Public\Power\Get-VmKvpIpAddress.ps1"
. "$PSScriptRoot\Public\Power\Start-VmIfStopped.ps1"

. "$PSScriptRoot\Public\Processes\Stop-VmProcessesUsingPath.ps1"

. "$PSScriptRoot\Public\Ssh\Invoke-SshClientCommand.ps1"
. "$PSScriptRoot\Public\Ssh\New-VmSshClient.ps1"
. "$PSScriptRoot\Public\Ssh\New-VmSshTunnel.ps1"
. "$PSScriptRoot\Public\Ssh\New-VmSshClientWithJump.ps1"
. "$PSScriptRoot\Public\Ssh\Test-SshBanner.ps1"
. "$PSScriptRoot\Public\Ssh\Test-VmSshPort.ps1"
. "$PSScriptRoot\Public\Ssh\Wait-VmSshReady.ps1"

. "$PSScriptRoot\Public\ProfileD\Remove-VmProfileDScript.ps1"
. "$PSScriptRoot\Public\ProfileD\Set-VmProfileDScript.ps1"

. "$PSScriptRoot\Public\Symlinks\New-VmSymlink.ps1"
. "$PSScriptRoot\Public\Symlinks\Remove-VmSymlink.ps1"

# Export-ModuleMember controls what is actually callable after Import-Module.
# It takes precedence over FunctionsToExport in the psd1 at runtime, so both
# must be kept in sync. FunctionsToExport serves a separate purpose: it is
# read by Get-Module -ListAvailable, Find-Module, and PSGallery for fast
# discovery without loading the module. The shared Module.Tests.ps1 in the
# run-unit-tests action enforces that every Public\*.ps1 file appears in both.
Export-ModuleMember -Function @(
    'Add-VmFileServerFile',
    'Assert-VmEnvVarsField',
    'Assert-VmFilesField',
    'Copy-VmFiles',
    'Copy-VmFilesByPattern',
    'Expand-VmTarball',
    'Get-VmKvpIpAddress',
    'Get-VmSwitchHostIp',
    'Invoke-SshClientCommand',
    'Invoke-WithVmFileServer',
    'New-VmSshClient',
    'New-VmSshClientWithJump',
    'New-VmSshTunnel',
    'New-VmSymlink',
    'Remove-VmDirectory',
    'Remove-VmProfileDScript',
    'Remove-VmSymlink',
    'Set-VmEnvironmentVariables',
    'Set-VmProfileDScript',
    'Start-VmIfStopped',
    'Stop-VmProcessesUsingPath',
    'Test-SshBanner',
    'Test-VmSshPort',
    'Wait-VmSshReady'
)
