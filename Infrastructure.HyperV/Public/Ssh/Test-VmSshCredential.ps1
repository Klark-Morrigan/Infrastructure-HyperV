# ---------------------------------------------------------------------------
# Test-VmSshCredential
#   Single-shot authentication probe: opens one SSH session with the given
#   credentials, then disposes it. Returns $true if the server ACCEPTED the
#   password, $false if it DEFINITIVELY REJECTED it, and throws on any other
#   (transient / unreachable) failure.
#
#   Why three outcomes instead of a bool:
#     "rejected" and "could not connect" are different facts and callers
#     act on them differently. A rejection is a verdict about the account
#     (the password is wrong, or - upstream of this probe - the account was
#     never created); a timeout / connection-refused / KEX failure is a
#     transport problem that says nothing about the credentials. Collapsing
#     both into $false would force every caller to re-derive the difference.
#     So a definitive rejection returns $false, while a transient error is
#     rethrown UNCHANGED to keep its own diagnostic surface.
#
#   Relationship to the other Ssh probes:
#     - Test-VmSshPort  answers "is the port open?" (TCP).
#     - Test-SshBanner  answers "is sshd actually replying?" (banner bytes).
#     - Test-VmSshCredential answers "does this login work?" (auth) - the
#       last rung, reached only once the lower probes pass. A banner-
#       reachable host can still have zero usable logins (e.g. first-boot
#       user provisioning failed), which only an auth attempt reveals.
#
#   Classification is by message/inner-exception shape rather than a hard
#   Renci type reference: SSH.NET surfaces a rejected password as a
#   "Permission denied" message (wrapped by PowerShell's method-call
#   machinery into a MethodInvocationException whose message still carries
#   that text, with the SshAuthenticationException as InnerException). Keying
#   on that keeps the function unit-testable without SSH.NET loaded.
#
#   Connect policy (host-key acceptance, KEX set, keepalive, timeout) is
#   inherited wholesale from New-VmSshClient so this probe behaves exactly
#   like every other session in the module. NOTE: a rejection therefore
#   pays New-VmSshClient's connect retries before SSH.NET gives up, so the
#   $false path is not instantaneous; the $true path returns as soon as the
#   handshake completes.
#
#   Security:
#   - Password is required as a plain string by SSH.NET (same contract as
#     New-VmSshClient). Source it from SecretManagement and never log it.
# ---------------------------------------------------------------------------

function Test-VmSshCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password')]
    # SSH.NET takes the username/password as plaintext strings; the pair is
    # intrinsic to the connect contract (see New-VmSshClient), so suppress
    # the paired-param rule (function-scoped: the suppression ID is empty).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'SSH.NET requires a plaintext username/password pair')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $IpAddress,

        [Parameter(Mandatory)]
        [string] $Username,

        # Plain string required by SSH.NET PasswordAuthenticationMethod.
        [Parameter(Mandatory)]
        [string] $Password,

        # TCP port sshd is reachable on. Defaults to 22; callers probing
        # through a local-forward tunnel pass the ephemeral loopback port.
        [int] $Port = 22,

        # Total Connect() wall-clock budget. Mirrors New-VmSshClient's
        # default so this probe and a real session time out identically.
        [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(30)
    )

    $client = $null
    try {
        # New-VmSshClient owns the connect + password-auth contract for the
        # whole stack; reuse it so this probe is indistinguishable from a
        # real session at the transport layer.
        $client = New-VmSshClient -IpAddress $IpAddress `
                                  -Username  $Username `
                                  -Password  $Password `
                                  -Port      $Port `
                                  -Timeout   $Timeout
        return $true
    }
    catch {
        $ex = $_.Exception

        # A definitive authentication rejection is the only failure that
        # answers the question with "no". Anything else (timeout, refused,
        # KEX mismatch) is a transport problem that says nothing about the
        # credentials, so rethrow it with its original surface intact.
        $isAuthFailure =
            ($ex.Message -match 'Permission denied') -or
            ($null -ne $ex.InnerException -and
             $ex.InnerException.GetType().Name -match 'Authentication')

        if ($isAuthFailure) { return $false }
        throw
    }
    finally {
        if ($null -ne $client) {
            if ($client.IsConnected) { $client.Disconnect() }
            $client.Dispose()
        }
    }
}
