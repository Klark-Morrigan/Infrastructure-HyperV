<#
.SYNOPSIS
    Hyper-V VM utilities for infrastructure repos.

.DESCRIPTION
    Provides VM-facing functions extracted from Infrastructure.Common to
    keep each module cohesive and single-purpose. All functions in this
    module assume a Hyper-V VM on an internal switch that the host can
    reach over SSH or HTTP.

    Current functions:
      - Invoke-SshClientCommand : runs a shell command via SSH.NET SshClient
      - New-VmSshClient         : creates and connects a SSH.NET SshClient
      - Invoke-WithVmFileServer : runs a script block with a live HTTP file
                                  server bound to the Hyper-V internal switch
      - Add-VmFileServerFile    : stages a host file and returns its VM URL
      - Copy-VmFiles            : per-entry transport (Add-VmFileServerFile +
                                  curl -o + chown + chmod under sudo); each
                                  entry is { Source, Target, Owner?, Mode? }
      - Copy-VmFilesByPattern   : wildcard front-end to Copy-VmFiles; expands
                                  a host-side pattern, validates host-side,
                                  then forwards to Copy-VmFiles
      - Assert-VmFilesField     : shared schema validator for a 'files' array
                                  on a VM definition; consumers extend via
                                  -AllowedSubFields and -PostEntryValidator
      - Test-VmSshPort          : single-shot TCP probe of an SSH port; the
                                  ICMP-ping replacement for callers that
                                  intend to SSH immediately afterwards
      - Wait-VmSshReady         : polls Test-VmSshPort until the port comes
                                  up or a deadline expires; used to gate
                                  post-boot/reboot SSH work

    Private helpers (Assert-SshNetLoaded, Get-VmSwitchHostIp,
    Start-VmFileServer, Stop-VmFileServer) are dot-sourced below but not
    exported.

    Functions are grouped by concern under Public\ and Private\ into three
    subfolders that share a name across the two trees:
      - Ssh\          : SSH client + port-probe primitives.
      - FileServer\   : host-side HTTP file server used to stage VM downloads.
      - FileTransfer\ : VM-side transport on top of Ssh + FileServer.
    Each function still lives in its own file so diffs stay focused on a
    single function per commit.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Private functions:

. "$PSScriptRoot\Private\Ssh\Assert-SshNetLoaded.ps1"

. "$PSScriptRoot\Private\FileServer\Get-VmSwitchHostIp.ps1"
. "$PSScriptRoot\Private\FileServer\Start-VmFileServer.ps1"
. "$PSScriptRoot\Private\FileServer\Stop-VmFileServer.ps1"

. "$PSScriptRoot\Private\FileTransfer\Assert-VmFileBulkEntry.ps1"
. "$PSScriptRoot\Private\FileTransfer\Assert-VmFileSingleEntry.ps1"
. "$PSScriptRoot\Private\FileTransfer\Resolve-VmFileEntries.ps1"

# Public functions:

. "$PSScriptRoot\Public\Ssh\Invoke-SshClientCommand.ps1"
. "$PSScriptRoot\Public\Ssh\New-VmSshClient.ps1"
. "$PSScriptRoot\Public\Ssh\Test-VmSshPort.ps1"
. "$PSScriptRoot\Public\Ssh\Wait-VmSshReady.ps1"

. "$PSScriptRoot\Public\FileServer\Add-VmFileServerFile.ps1"
. "$PSScriptRoot\Public\FileServer\Invoke-WithVmFileServer.ps1"

. "$PSScriptRoot\Public\FileTransfer\Assert-VmFilesField.ps1"
. "$PSScriptRoot\Public\FileTransfer\Copy-VmFiles.ps1"
. "$PSScriptRoot\Public\FileTransfer\Copy-VmFilesByPattern.ps1"

# Export-ModuleMember controls what is actually callable after Import-Module.
# It takes precedence over FunctionsToExport in the psd1 at runtime, so both
# must be kept in sync. FunctionsToExport serves a separate purpose: it is
# read by Get-Module -ListAvailable, Find-Module, and PSGallery for fast
# discovery without loading the module. The shared Module.Tests.ps1 in the
# run-unit-tests action enforces that every Public\*.ps1 file appears in both.
Export-ModuleMember -Function @(
    'Add-VmFileServerFile',
    'Assert-VmFilesField',
    'Copy-VmFiles',
    'Copy-VmFilesByPattern',
    'Invoke-SshClientCommand',
    'Invoke-WithVmFileServer',
    'New-VmSshClient',
    'Test-VmSshPort',
    'Wait-VmSshReady'
)
