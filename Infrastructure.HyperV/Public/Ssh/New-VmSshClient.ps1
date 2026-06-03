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
#   Connect timing:
#     -Timeout caps the total Connect() wall-clock. SSH.NET applies the
#     same value to both socket-read and KEX, so a long Timeout is the
#     right knob when a slow server-side responder (e.g. sshd held off
#     by cloud-config until users are created) needs more than SSH.NET's
#     30s default. The connect runs on the thread pool so the calling
#     thread can emit a progress dot every -ProgressInterval while the
#     Task is still running. Without that, a multi-minute wait looks
#     identical to a hang to an operator watching the console.
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
        [string] $Password,

        # Total Connect() wall-clock budget. Default 30s matches SSH.NET's
        # built-in default so existing callers are unaffected. Callers
        # waiting on a slow server-side responder (e.g. provisioning,
        # where sshd is ordered after cloud-config) pass a generous value.
        [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(30),

        # How often a progress dot is emitted while Connect is still
        # running. Smaller values are smoother visually but produce more
        # output; 5s is a reasonable default for waits measured in
        # minutes.
        [TimeSpan] $ProgressInterval = [TimeSpan]::FromSeconds(5)
    )

    Assert-SshNetLoaded

    $auth     = [Renci.SshNet.PasswordAuthenticationMethod]::new($Username, $Password)
    $connInfo = [Renci.SshNet.ConnectionInfo]::new($IpAddress, $Username, @($auth))
    # SSH.NET applies ConnectionInfo.Timeout to both the TCP socket read
    # and the KEX exchange. Setting it here governs the upper bound that
    # the Task below observes.
    $connInfo.Timeout = $Timeout
    $client   = [Renci.SshNet.SshClient]::new($connInfo)

    # Run Connect on the thread pool so the foreground can poll and emit
    # progress. Task.Run wraps the .Connect() call and surfaces any
    # exception via Task.Exception (an AggregateException whose
    # InnerException is the real SSH.NET error).
    Write-Host "  Connecting to $IpAddress (timeout $([int]$Timeout.TotalSeconds)s) ..." `
        -NoNewline
    $connectTask = [System.Threading.Tasks.Task]::Run([System.Action] { $client.Connect() })

    # Wait in ProgressInterval slices, emitting a dot per slice. Wait()
    # returns $true on completion, $false on slice-timeout. SSH.NET's
    # own timeout will surface on the Task as an exception once the
    # configured ConnectionInfo.Timeout elapses; we do not impose a
    # second timeout in this loop.
    while (-not $connectTask.Wait($ProgressInterval)) {
        Write-Host '.' -NoNewline
    }
    Write-Host ''

    if ($connectTask.IsFaulted) {
        # AggregateException wraps the original; rethrow the inner so
        # the caller's catch sees the underlying SSH.NET exception type
        # (e.g. SocketException, SshOperationTimeoutException) instead
        # of a generic AggregateException.
        throw $connectTask.Exception.InnerException
    }

    $client
}
