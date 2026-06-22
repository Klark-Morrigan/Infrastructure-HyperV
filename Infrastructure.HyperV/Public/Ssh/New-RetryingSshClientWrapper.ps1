# ---------------------------------------------------------------------------
# New-RetryingSshClientWrapper
#   Wraps an SSH client (a raw SSH.NET client, or any duck-type-compatible
#   wrapper around one) with a PSCustomObject whose RunCommand retries the
#   call through Invoke-WithRetry when it fails with a transient transport
#   error, reconnecting the dropped session first. IsConnected / Connect /
#   Disconnect / Dispose forward to the inner client, so the wrapper is a
#   transparent stand-in.
#
#   Why: a long-lived SSH session (one held open across many commands)
#   can have its channel torn down mid-RunCommand by a NAT or firewall
#   middlebox reaping an idle-looking connection, surfacing as "An
#   established connection was aborted by the server" and failing the whole
#   operation even though a reconnect-and-retry would have succeeded.
#   New-VmSshClient's keepalive narrows that window; this wrapper is the
#   belt to that brace, turning a transient drop into a retried command.
#
#   Only transport-level exceptions are retried. A command that runs but
#   reports a non-zero exit status does NOT throw here - RunCommand returns
#   the result object unchanged, so caller-side logic that inspects
#   ExitStatus keeps full control and its own throws are never mistaken
#   for a flake.
#
#   Compose this outermost - over any logging/diagnostic wrapper - so the
#   retried attempts still pass through the inner layers.
#
#   Requires Invoke-WithRetry from Common.PowerShell (declared in this
#   module's RequiredModules).
#
#   Dot-sourced by Infrastructure.HyperV.psm1.
# ---------------------------------------------------------------------------

function New-RetryingSshClientWrapper {
    [CmdletBinding()]
    param(
        # The client to wrap: any object exposing IsConnected / Connect /
        # RunCommand (a raw SSH.NET client, or a wrapper around one). Typed
        # [object] to avoid resolving the Renci type at module-import time.
        [Parameter(Mandatory)]
        [object] $InnerClient,

        # Total attempts including the first. 3 keeps a flap from costing
        # more than a few seconds of backoff while still riding out the
        # single-drop case this targets.
        [int] $MaxAttempts = 3,

        # Inter-attempt pacing. Defaults to $null so Invoke-WithRetry picks
        # its own exponential backoff; a caller can pass a strategy to
        # override the curve (e.g. a fixed or zero delay).
        [hashtable] $BackoffStrategy = $null
    )

    # Classifier for "the transport dropped, worth retrying". The failure
    # can arrive method-wrapped (each RunCommand ScriptMethod layer re-wraps
    # a thrown exception), so walk the whole InnerException chain rather than
    # trusting the top-level type or message. Matches both the SSH.NET
    # connection/timeout types and the raw socket errors, plus a message
    # fallback for SSH.NET's own "aborted by the server" wording, which
    # carries no distinctive type.
    $transientTransportStrategy = @{
        Name        = 'TransientSshTransport'
        ShouldRetry = {
            param([System.Management.Automation.ErrorRecord] $ErrorRecord)

            $transientTypes = @(
                'Renci.SshNet.Common.SshConnectionException',
                'Renci.SshNet.Common.SshOperationTimeoutException',
                'System.Net.Sockets.SocketException',
                'System.IO.IOException',
                'System.TimeoutException'
            )
            # Narrow patterns: the cost of a missed one is a real flake
            # failing fast (safe); the cost of a wrong match is retrying a
            # permanent error for the whole budget.
            $transientPatterns = @(
                'aborted by the server',
                'forcibly closed',
                'connection.*(reset|abort|clos)',
                'client not connected',
                'not connected',
                'broken pipe',
                'operation has timed out',
                'timed out'
            )

            $ex = $ErrorRecord.Exception
            while ($null -ne $ex) {
                if ($transientTypes -contains $ex.GetType().FullName) {
                    return $true
                }
                foreach ($pattern in $transientPatterns) {
                    if ($ex.Message -match $pattern) { return $true }
                }
                $ex = $ex.InnerException
            }
            return $false
        }
    }

    $wrapper = [PSCustomObject]@{
        _inner      = $InnerClient
        _maxAttempts = $MaxAttempts
        _strategy   = $transientTransportStrategy
        _backoff    = $BackoffStrategy
    }

    # The main hook. Invoke-SshClientCommand calls RunCommand on whatever
    # object it is handed, so funnelling the retry here gives any caller that
    # routes through this wrapper reconnect-and-retry without changing the
    # shared Invoke-SshClientCommand cmdlet.
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'RunCommand' -Value {
        param($command)

        # Snapshot $this state into locals the work closure can capture;
        # GetNewClosure only snapshots the immediate scope's variables.
        $inner   = $this._inner
        $work    = {
            # Re-establish before the attempt when a prior drop left the
            # session down; the first attempt normally finds it connected
            # and skips straight to RunCommand.
            if (-not $inner.IsConnected) { $inner.Connect() }
            $inner.RunCommand($command)
        }.GetNewClosure()

        # Build the Invoke-WithRetry argument set, omitting -BackoffStrategy
        # when none was injected so the helper applies its own default.
        $retryArgs = @{
            OperationName = "SSH RunCommand"
            MaxAttempts   = $this._maxAttempts
            RetryStrategy = $this._strategy
            ScriptBlock   = $work
        }
        if ($null -ne $this._backoff) {
            $retryArgs.BackoffStrategy = $this._backoff
        }

        Invoke-WithRetry @retryArgs
    } -Force

    # Forward connection lifecycle to the inner client so this wrapper is a
    # transparent stand-in: a caller's IsConnected check and the retry's own
    # reconnect both reach the real session.
    $wrapper | Add-Member -MemberType ScriptProperty -Name 'IsConnected' `
        -Value { $this._inner.IsConnected } -Force
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'Connect' `
        -Value { $this._inner.Connect() } -Force
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'Disconnect' `
        -Value { $this._inner.Disconnect() } -Force
    $wrapper | Add-Member -MemberType ScriptMethod -Name 'Dispose' `
        -Value { $this._inner.Dispose() } -Force

    return $wrapper
}
