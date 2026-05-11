function Invoke-WithVmFileServer {
    <#
    .SYNOPSIS
        Runs a script block with a live file server handle, guaranteeing cleanup.

    .DESCRIPTION
        Starts the file server, passes the handle to $ScriptBlock, then stops the
        server in a finally block regardless of whether $ScriptBlock throws.

        This wrapper makes it structurally impossible to forget the cleanup that
        Stop-VmFileServer performs (closing the HttpListener, removing the firewall
        rule, deleting the staging directory). Use it in preference to writing
        Start-VmFileServer / Stop-VmFileServer try/finally blocks directly.

    .PARAMETER VmIpAddress
        IPv4 address of any VM on the switch. Forwarded to Start-VmFileServer,
        which uses it to locate the host adapter IP. Mutually exclusive with
        -HostIp.

    .PARAMETER HostIp
        Explicit host IP. Forwarded to Start-VmFileServer. Mutually exclusive
        with -VmIpAddress.

    .PARAMETER Port
        TCP port for the HTTP listener. Defaults to 8745.

    .PARAMETER ScriptBlock
        Block to run while the server is live. Receives the server handle as its
        first argument. Any output it produces flows through to the caller.

    .EXAMPLE
        Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
            param($server)
            $url = Add-VmFileServerFile -Server $server -LocalPath 'E:\cache\tarball.tar.gz'
            Invoke-VmRunnerGroup -HostBaseUrl $server.BaseUrl ...
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByVmIp')]
        [string] $VmIpAddress,

        [Parameter(Mandatory, ParameterSetName = 'ByHostIp')]
        [string] $HostIp,

        [Parameter()]
        [int] $Port = 8745,

        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock
    )

    $startParams = @{ Port = $Port }
    if ($PSCmdlet.ParameterSetName -eq 'ByVmIp') {
        $startParams['VmIpAddress'] = $VmIpAddress
    } else {
        $startParams['HostIp'] = $HostIp
    }

    $server = Start-VmFileServer @startParams
    try {
        & $ScriptBlock $server
    } finally {
        Stop-VmFileServer -Server $server
    }
}
