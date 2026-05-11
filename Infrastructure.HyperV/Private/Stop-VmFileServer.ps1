function Stop-VmFileServer {
    <#
    .SYNOPSIS
        Stops a file server started by Start-VmFileServer and cleans up all
        associated resources.

    .DESCRIPTION
        Calls Listener.Stop(), which causes the background runspace's GetContext()
        call to throw, exiting the serve loop cleanly. Then disposes the runspace
        and PowerShell instance, removes the firewall rule, and deletes the staging
        directory.

        Always call this from a finally block so resources are released even if
        subsequent steps fail.

    .PARAMETER Server
        The handle returned by Start-VmFileServer.

    .EXAMPLE
        $server = Start-VmFileServer -VmIpAddress '10.10.0.50'
        try { ... } finally { Stop-VmFileServer -Server $server }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Server
    )

    # Stop() signals the background loop to exit by causing GetContext() to throw.
    $Server.Listener.Stop()
    $Server.PowerShell.Dispose()
    $Server.Runspace.Dispose()
    Remove-NetFirewallRule -Name $Server.FirewallRuleName
    Remove-Item -Path $Server.StagingDir -Recurse -Force
}
