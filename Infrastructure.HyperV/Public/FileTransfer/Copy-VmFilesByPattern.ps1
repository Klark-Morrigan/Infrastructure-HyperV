<#
.SYNOPSIS
    Copies host files matching a wildcard pattern to a Hyper-V VM.

.DESCRIPTION
    Thin public wrapper that combines two existing primitives:
      1. Resolve-VmFileEntries (private) expands the host-side wildcard
         into the entry shape Copy-VmFiles consumes and runs the
         pre-flight validation pass.
      2. Copy-VmFiles (public) performs the per-entry transport.

    Validation lives entirely in the resolver - if it throws, no SSH or
    file-server I/O happens, which is the contract documented in
    docs\dev\implementation\01 - bulk-vm-file-transfer\problem.md.

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle. Forwarded to Copy-VmFiles unchanged.

.PARAMETER Server
    A file-server handle returned by Start-VmFileServer or supplied by
    Invoke-WithVmFileServer's scriptblock. Forwarded to Copy-VmFiles
    unchanged.

.PARAMETER Pattern
    A host-side wildcard accepted by Get-ChildItem -Path. Forwarded to
    the resolver.

.PARAMETER TargetDir
    Absolute Linux directory on the VM under which every matched file
    lands. Forwarded to the resolver.

.PARAMETER Recurse
    Descend into subdirectories. Forwarded to the resolver.

.PARAMETER PreserveRelativePath
    Mirror the host subtree under TargetDir instead of flattening to
    basenames. Forwarded to the resolver.

.PARAMETER Owner
    chown argument applied uniformly to every entry. When omitted the
    resolver's default ('root:root') applies.

.PARAMETER Mode
    chmod argument applied uniformly to every entry. When omitted the
    resolver's default ('0644') applies.

.EXAMPLE
    Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
        param($server)
        $sshClient = New-VmSshClient -IpAddress '10.10.0.50' `
                                     -Username 'admin' -Password 'secret'
        try {
            Copy-VmFilesByPattern -SshClient $sshClient -Server $server `
                                  -Pattern   'C:\seed\*.json' `
                                  -TargetDir '/var/data'
        }
        finally {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }
#>
function Copy-VmFilesByPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        [Parameter(Mandatory)]
        [string] $Pattern,

        [Parameter(Mandatory)]
        [string] $TargetDir,

        [switch] $Recurse,

        [switch] $PreserveRelativePath,

        [string] $Owner,

        [string] $Mode
    )

    # Forward only the file-selection parameters the caller actually
    # supplied. This keeps the resolver as the single source of truth
    # for Owner / Mode defaults instead of restating them here.
    $resolveArgs = @{
        Pattern   = $Pattern
        TargetDir = $TargetDir
    }
    if ($Recurse)              { $resolveArgs.Recurse              = $true }
    if ($PreserveRelativePath) { $resolveArgs.PreserveRelativePath = $true }
    if ($PSBoundParameters.ContainsKey('Owner')) { $resolveArgs.Owner = $Owner }
    if ($PSBoundParameters.ContainsKey('Mode'))  { $resolveArgs.Mode  = $Mode  }

    $entries = Resolve-VmFileEntries @resolveArgs

    Copy-VmFiles -SshClient $SshClient -Server $Server -Entries $entries
}
