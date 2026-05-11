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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $IpAddress,

        [Parameter(Mandatory)]
        [string] $Username,

        # Plain string required by SSH.NET PasswordAuthenticationMethod.
        [Parameter(Mandatory)]
        [string] $Password
    )

    Assert-SshNetLoaded

    $auth     = [Renci.SshNet.PasswordAuthenticationMethod]::new($Username, $Password)
    $connInfo = [Renci.SshNet.ConnectionInfo]::new($IpAddress, $Username, @($auth))
    $client   = [Renci.SshNet.SshClient]::new($connInfo)
    $client.Connect()
    $client
}
