# ---------------------------------------------------------------------------
# Wait-VmSshReady
#   Polls a remote SSH port until it accepts a TCP connection or a deadline
#   expires. Returns $true on success, $false on timeout. Never throws on
#   the network path - callers decide what to do with a $false result.
#
#   Use this after booting (or rebooting) a VM to wait for cloud-init or
#   sshd startup to finish. A successful return is a stronger signal than
#   ICMP ping: it means sshd has bound the port and is accepting TCP
#   connections, which is the precondition the next SSH call needs.
#
#   For a single non-blocking probe, call Test-VmSshPort directly instead -
#   this function is the loop on top of that primitive.
# ---------------------------------------------------------------------------

function Wait-VmSshReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [int] $Port = 22,
        # 120 s covers a typical Ubuntu cloud-init first-boot with slack.
        # Cold-boot waits (10 min) should override this.
        [int] $TimeoutSeconds = 120,
        [int] $PollIntervalSeconds = 2,
        [int] $ConnectTimeoutMilliseconds = 2000
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-VmSshPort -IpAddress           $IpAddress `
                           -Port                $Port `
                           -TimeoutMilliseconds $ConnectTimeoutMilliseconds) {
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    return $false
}
