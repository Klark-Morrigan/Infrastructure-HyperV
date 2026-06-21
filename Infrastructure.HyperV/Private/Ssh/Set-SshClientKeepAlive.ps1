# ---------------------------------------------------------------------------
# Set-SshClientKeepAlive
#   Applies an SSH-level keepalive interval to a constructed (not yet
#   connected) SSH.NET client, encapsulating the one policy decision its
#   caller needs: a non-positive interval means "disabled", so leave
#   SSH.NET's default (Timeout.InfiniteTimeSpan) untouched rather than
#   feeding it a zero interval, which it would treat as "send continuously".
#
#   Kept as a standalone, side-effect-free helper rather than inlined into
#   New-VmSshClient: that function's body is an effectful construct-then-
#   connect sequence, and isolating this one pure policy decision keeps it
#   self-contained and reusable instead of buried in the connection path.
#
#   Call this before Client.Connect() so the timer arms with the session.
#
#   $Client is typed [object] (not Renci.SshNet.SshClient) so the module
#   imports cleanly on hosts without Posh-SSH loaded - same reason the
#   public SSH functions avoid the Renci type in their signatures.
# ---------------------------------------------------------------------------

function Set-SshClientKeepAlive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Client,

        [Parameter(Mandatory)]
        [TimeSpan] $Interval
    )

    if ($Interval -gt [TimeSpan]::Zero) {
        $Client.KeepAliveInterval = $Interval
    }
}
