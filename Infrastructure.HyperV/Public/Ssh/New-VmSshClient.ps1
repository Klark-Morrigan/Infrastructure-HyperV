# ---------------------------------------------------------------------------
# New-VmSshClient
#   Creates and connects a Renci.SshNet.SshClient using password
#   authentication. Returns the connected client; the caller is responsible
#   for calling Disconnect() and Dispose() in a finally block.
#
#   SSH.NET is used directly rather than Posh-SSH cmdlets because
#   ConnectionInfoGenerator in Posh-SSH 3.x drops algorithm entries from
#   the SSH.NET ConnectionInfo, breaking key exchange against OpenSSH 9.x
#   (Ubuntu 24.04). Posh-SSH must still be installed - it ships the
#   Renci.SshNet.dll the function depends on.
#
#   Renci types are referenced inside the function body (not as parameter
#   types) so the module imports cleanly on hosts without Posh-SSH. The
#   Assert-SshNetLoaded guard turns the otherwise opaque "type not found"
#   error into an actionable message naming the missing prerequisite.
#
#   -Timeout caps the total Connect() wall-clock. SSH.NET applies the
#   same value to both socket-read and KEX, so a long Timeout is the
#   right knob when a slow server-side responder (e.g. sshd held off
#   by cloud-config until users are created) needs more than SSH.NET's
#   30s default. The Connect call is synchronous - the caller pays a
#   single block of up to -Timeout with no console output in between.
#   Consumers waiting on multi-minute connects should print a leading
#   "this may take a few minutes" line so the silence does not read
#   like a hang.
#
#   -KeepAliveInterval arms SSH.NET's keepalive timer so a long-lived
#   session survives the idle gaps between commands on a path where a NAT
#   or firewall middlebox would otherwise silently reap an idle-looking
#   connection. Defaults to 15s; pass [TimeSpan]::Zero to opt out.
#
#   -Port selects the TCP port (default 22). It lets a caller reach an
#   sshd published on a non-standard port - e.g. a jump tunnel's ephemeral
#   loopback forward - through this one helper, so the connect/keepalive
#   policy is not re-implemented at each call site.
#
#   Security:
#   - SSH.NET accepts any host key by default (no HostKeyReceived handler).
#     Equivalent to Posh-SSH's -AcceptKey. Acceptable on a private Hyper-V
#     network with statically provisioned IPs; do NOT use on untrusted
#     networks without supplying a fingerprint check.
#   - Password is required as a plain string by SSH.NET's
#     PasswordAuthenticationMethod constructor. Callers should source the
#     value from SecretManagement and avoid logging it.
# ---------------------------------------------------------------------------

function New-VmSshClient {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password')]
    # SSH.NET's PasswordAuthenticationMethod takes the username and password
    # as plaintext strings; a PSCredential would only be unwrapped here. The
    # pair is intrinsic to the library contract, so suppress the paired-param
    # rule (function-scoped: the suppression ID must be empty).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'SSH.NET requires a plaintext username/password pair')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $IpAddress,

        [Parameter(Mandatory)]
        [string] $Username,

        # Plain string required by SSH.NET PasswordAuthenticationMethod.
        [Parameter(Mandatory)]
        [string] $Password,

        # TCP port sshd is reachable on. Defaults to 22; callers connecting
        # through a local-forward tunnel pass the ephemeral loopback port.
        [int] $Port = 22,

        # Total Connect() wall-clock budget. Default 30s matches SSH.NET's
        # built-in default so existing callers are unaffected. Callers
        # waiting on a slow server-side responder (e.g. provisioning,
        # where sshd is ordered after cloud-config) pass a generous value.
        [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(30),

        # SSH-level keepalive interval for the connected client. SSH.NET
        # sends a keepalive global-request every interval, which keeps a
        # long-lived session alive across the idle gaps between commands:
        # a NAT or firewall middlebox on the host<->VM path can otherwise
        # drop an idle-looking connection, surfacing mid-command as
        # "connection aborted by the server". Defaults to 15s, comfortably
        # under common middlebox idle timeouts; pass [TimeSpan]::Zero to
        # disable (restoring SSH.NET's no-keepalive default).
        [TimeSpan] $KeepAliveInterval = [TimeSpan]::FromSeconds(15)
    )

    Assert-SshNetLoaded

    $auth     = [Renci.SshNet.PasswordAuthenticationMethod]::new($Username, $Password)
    $connInfo = [Renci.SshNet.ConnectionInfo]::new($IpAddress, $Port, $Username, @($auth))
    # SSH.NET applies ConnectionInfo.Timeout to both the TCP socket read
    # and the KEX exchange.
    $connInfo.Timeout = $Timeout
    $client   = [Renci.SshNet.SshClient]::new($connInfo)
    # Arm keepalive before Connect so the timer starts with the session.
    # The disabled-on-non-positive policy lives in Set-SshClientKeepAlive.
    Set-SshClientKeepAlive -Client $client -Interval $KeepAliveInterval
    $client.Connect()
    $client
}
