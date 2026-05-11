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

    Private helpers (Assert-SshNetLoaded, Get-VmSwitchHostIp,
    Start-VmFileServer, Stop-VmFileServer) are dot-sourced below but not
    exported.

    Each function lives in its own file under Public\ or Private\ and is
    dot-sourced below so diffs stay focused on a single function per commit.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Private\Assert-SshNetLoaded.ps1"
. "$PSScriptRoot\Private\Get-VmSwitchHostIp.ps1"
. "$PSScriptRoot\Private\Start-VmFileServer.ps1"
. "$PSScriptRoot\Private\Stop-VmFileServer.ps1"
. "$PSScriptRoot\Public\Add-VmFileServerFile.ps1"
. "$PSScriptRoot\Public\Invoke-SshClientCommand.ps1"
. "$PSScriptRoot\Public\Invoke-WithVmFileServer.ps1"
. "$PSScriptRoot\Public\New-VmSshClient.ps1"

# Export-ModuleMember controls what is actually callable after Import-Module.
# It takes precedence over FunctionsToExport in the psd1 at runtime, so both
# must be kept in sync. FunctionsToExport serves a separate purpose: it is
# read by Get-Module -ListAvailable, Find-Module, and PSGallery for fast
# discovery without loading the module. The shared Module.Tests.ps1 in the
# run-unit-tests action enforces that every Public\*.ps1 file appears in both.
Export-ModuleMember -Function @(
    'Add-VmFileServerFile',
    'Invoke-SshClientCommand',
    'Invoke-WithVmFileServer',
    'New-VmSshClient'
)
