# ---------------------------------------------------------------------------
# Test-VmSshPort
#   Single-shot TCP probe of an SSH port on a remote host. Returns $true if
#   the connection succeeded within the timeout, $false otherwise.
#
#   Use this in place of ICMP ping (Test-Connection) when the question is
#   "is sshd listening?" rather than "is the host responding at all?". A
#   successful TCP connect strictly implies the host is up AND sshd has
#   bound the port - i.e. the failure modes that matter to a caller about
#   to open an SSH session.
#
#   Use Wait-VmSshReady when you need to poll until the port comes up.
#
#   [System.Net.Sockets.TcpClient] is used instead of Test-NetConnection for
#   predictability: the .NET API gives a direct bool result without parsing
#   cmdlet output objects, and it works on PS 7+ on every supported platform.
# ---------------------------------------------------------------------------

function Test-VmSshPort {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [int] $Port = 22,
        # 2000 ms catches a "host up, port closed" reject quickly while
        # leaving headroom for a slow LAN. Tune up if probing across higher-
        # latency links.
        [int] $TimeoutMilliseconds = 2000
    )

    $tcpClient = $null
    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        # ConnectAsync().Wait(ms) returns $true on success within the
        # timeout, $false on timeout. Other failures (DNS resolution, host
        # unreachable) raise and are swallowed by the catch below.
        return $tcpClient.ConnectAsync($IpAddress, $Port).Wait($TimeoutMilliseconds)
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $tcpClient) { $tcpClient.Dispose() }
    }
}
