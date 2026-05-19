function Start-VmFileServer {
    <#
    .SYNOPSIS
        Starts an HTTP file server on the Hyper-V internal switch host adapter.

    .DESCRIPTION
        Creates a temporary staging directory, opens a Windows Firewall inbound
        rule for the port, starts System.Net.HttpListener, and spawns a background
        runspace that serves files from the staging directory.

        The caller MUST call Stop-VmFileServer in a finally block so the listener,
        firewall rule, and staging directory are always cleaned up.

    .PARAMETER VmIpAddress
        IPv4 address of any VM on the switch. Used to locate the host adapter IP
        via Get-VmSwitchHostIp. Mutually exclusive with -HostIp.

    .PARAMETER HostIp
        Explicit host IP to bind the listener to. Use this in tests or when the
        host IP is already known. Mutually exclusive with -VmIpAddress.

    .PARAMETER Port
        TCP port for the HTTP listener. Defaults to 8745.

    .OUTPUTS
        PSCustomObject with properties:
          HostIp, Port, BaseUrl, StagingDir, Listener, Runspace, PowerShell,
          FirewallRuleName

    .EXAMPLE
        $server = Start-VmFileServer -VmIpAddress '10.10.0.50' -Port 8745
        try { ... } finally { Stop-VmFileServer -Server $server }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByVmIp')]
        [string] $VmIpAddress,

        [Parameter(Mandatory, ParameterSetName = 'ByHostIp')]
        [string] $HostIp,

        [Parameter()]
        [int] $Port = 8745
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByVmIp') {
        $HostIp = Get-VmSwitchHostIp -VmIpAddress $VmIpAddress
    }

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "VmFileServer-$Port"
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    # Open the firewall before the listener starts so no connection is accepted
    # before the rule is in place (defence in depth - the rule is what controls
    # which hosts can reach the port on the internal switch).
    $firewallRuleName = "VmFileServer-$Port"
    New-NetFirewallRule `
        -DisplayName $firewallRuleName `
        -Name        $firewallRuleName `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   $Port `
        -Action      Allow | Out-Null

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://${HostIp}:${Port}/")
    $listener.Start()

    # Isolated runspace so the caller's thread is not blocked.
    # The loop exits when Listener.Stop() causes GetContext() to throw.
    $ps       = [powershell]::Create()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $ps.Runspace = $runspace

    $null = $ps.AddScript({
        param($Listener, $StagingDir)
        while ($true) {
            try {
                $ctx = $Listener.GetContext()
            } catch {
                # Listener.Stop() raises an exception here - that is the
                # intended exit signal, not an error condition.
                break
            }
            $req      = $ctx.Request
            $resp     = $ctx.Response
            # Strip the leading slash to obtain a bare filename.
            $fileName = $req.Url.LocalPath.TrimStart('/')
            $filePath = Join-Path $StagingDir $fileName
            if (Test-Path $filePath) {
                $fileInfo             = [System.IO.FileInfo]::new($filePath)
                $resp.StatusCode      = 200
                $resp.ContentLength64 = $fileInfo.Length
                # CopyTo avoids PowerShell's byte[]-to-string coercion that
                # occurs when calling Write(byte[], int, int) directly.
                $fileStream = [System.IO.File]::OpenRead($filePath)
                $fileStream.CopyTo($resp.OutputStream)
                $fileStream.Dispose()
            } else {
                $resp.StatusCode = 404
            }
            $resp.OutputStream.Close()
        }
    })
    $null = $ps.AddParameters(@{
        Listener   = $listener
        StagingDir = $stagingDir
    })
    $null = $ps.BeginInvoke()

    [PSCustomObject]@{
        HostIp           = $HostIp
        Port             = $Port
        BaseUrl          = "http://${HostIp}:${Port}"
        StagingDir       = $stagingDir
        Listener         = $listener
        Runspace         = $runspace
        PowerShell       = $ps
        FirewallRuleName = $firewallRuleName
    }
}
