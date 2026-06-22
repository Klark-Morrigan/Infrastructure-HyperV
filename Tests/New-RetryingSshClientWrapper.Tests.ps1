BeforeAll {
    # Faithful-but-sleepless stand-in for Common.PowerShell's
    # Invoke-WithRetry. It replicates the documented contract the wrapper
    # depends on - run the block, on failure consult RetryStrategy.ShouldRetry,
    # loop up to MaxAttempts, otherwise propagate - without the real backoff
    # sleeps. Retry *policy* is covered by Common.PowerShell's own tests; here
    # we exercise the reconnect + transient-classification logic this wrapper
    # owns. Captured args are surfaced via script-scope vars for assertions.
    function Invoke-WithRetry {
        param(
            [scriptblock] $ScriptBlock,
            [hashtable[]] $RetryStrategy,
            [hashtable]   $BackoffStrategy,
            [int]         $MaxAttempts,
            [string]      $OperationName
        )
        $script:CapturedMaxAttempts = $MaxAttempts
        $script:CapturedStrategies  = $RetryStrategy
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try { return & $ScriptBlock }
            catch {
                $err     = $_
                $matched = $RetryStrategy |
                    Where-Object { & $_.ShouldRetry $err } |
                    Select-Object -First 1
                if (-not $matched -or $attempt -ge $MaxAttempts) { throw }
            }
        }
    }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Ssh\New-RetryingSshClientWrapper.ps1"

    # Duck-typed stand-in for the wrapped SSH client. Tracks call counts and
    # lets each test inject RunCommand behaviour. State lives on the object
    # so the ScriptMethods mutate it through $this.
    function New-FakeInnerClient {
        param([scriptblock] $RunBehavior)

        $fake = [PSCustomObject]@{
            RunCalls        = 0
            ConnectCalls    = 0
            DisconnectCalls = 0
            DisposeCalls    = 0
            Connected       = $true
            _behavior       = $RunBehavior
        }
        $fake | Add-Member ScriptProperty 'IsConnected' { $this.Connected } -Force
        $fake | Add-Member ScriptMethod 'RunCommand' {
            param($command)
            $this.RunCalls++
            & $this._behavior $this $command
        } -Force
        $fake | Add-Member ScriptMethod 'Connect' {
            $this.ConnectCalls++; $this.Connected = $true
        } -Force
        $fake | Add-Member ScriptMethod 'Disconnect' { $this.DisconnectCalls++ } -Force
        $fake | Add-Member ScriptMethod 'Dispose'    { $this.DisposeCalls++ } -Force
        return $fake
    }
}

Describe 'New-RetryingSshClientWrapper' {

    Context 'happy path' {

        It 'returns the inner result and does not reconnect when the first attempt succeeds' {
            $inner = New-FakeInnerClient -RunBehavior {
                param($self, $command)
                [PSCustomObject]@{ Result = 'ok'; Error = ''; ExitStatus = 0 }
            }
            $wrapper = New-RetryingSshClientWrapper -InnerClient $inner

            $result = $wrapper.RunCommand('uname -a')

            $result.Result          | Should -Be 'ok'
            $inner.RunCalls         | Should -Be 1
            $inner.ConnectCalls     | Should -Be 0
        }
    }

    Context 'transient transport drop' {

        It 'reconnects and retries after an abort, then returns the result' {
            # First attempt drops the session mid-command; second succeeds.
            $inner = New-FakeInnerClient -RunBehavior {
                param($self, $command)
                if ($self.RunCalls -eq 1) {
                    $self.Connected = $false
                    throw 'An established connection was aborted by the server.'
                }
                [PSCustomObject]@{ Result = 'recovered'; Error = ''; ExitStatus = 0 }
            }
            $wrapper = New-RetryingSshClientWrapper -InnerClient $inner

            $result = $wrapper.RunCommand('sudo nft list ruleset')

            $result.Result      | Should -Be 'recovered'
            $inner.RunCalls     | Should -Be 2
            $inner.ConnectCalls | Should -Be 1   # exactly one reconnect
        }
    }

    Context 'permanent failure' {

        It 'propagates a non-transient error without retrying' {
            $inner = New-FakeInnerClient -RunBehavior {
                param($self, $command)
                throw 'totally unrelated argument failure'
            }
            $wrapper = New-RetryingSshClientWrapper -InnerClient $inner

            { $wrapper.RunCommand('whoami') } | Should -Throw '*unrelated argument failure*'
            $inner.RunCalls     | Should -Be 1
            $inner.ConnectCalls | Should -Be 0
        }
    }

    Context 'transient classification' {

        BeforeEach {
            $inner          = New-FakeInnerClient -RunBehavior { param($self, $command) }
            $script:wrapper = New-RetryingSshClientWrapper -InnerClient $inner
        }

        It 'classifies SSH.NET "aborted by the server" wording as transient' {
            $err = try { throw 'An established connection was aborted by the server.' }
                   catch { $_ }
            (& $script:wrapper._strategy.ShouldRetry $err) | Should -BeTrue
        }

        It 'classifies a raw SocketException as transient by type' {
            $err = try { throw [System.Net.Sockets.SocketException]::new(10053) }
                   catch { $_ }
            (& $script:wrapper._strategy.ShouldRetry $err) | Should -BeTrue
        }

        It 'classifies an unrelated error as permanent' {
            $err = try { throw 'bad parameter value' } catch { $_ }
            (& $script:wrapper._strategy.ShouldRetry $err) | Should -BeFalse
        }
    }

    Context 'retry budget' {

        It 'passes the configured MaxAttempts through to Invoke-WithRetry' {
            $inner = New-FakeInnerClient -RunBehavior {
                param($self, $command)
                [PSCustomObject]@{ Result = 'ok'; Error = ''; ExitStatus = 0 }
            }
            $wrapper = New-RetryingSshClientWrapper -InnerClient $inner -MaxAttempts 5

            $wrapper.RunCommand('true') | Out-Null

            $script:CapturedMaxAttempts | Should -Be 5
        }
    }

    Context 'lifecycle forwarding' {

        It 'forwards IsConnected, Connect, Disconnect and Dispose to the inner client' {
            $inner   = New-FakeInnerClient -RunBehavior { param($self, $command) }
            $wrapper = New-RetryingSshClientWrapper -InnerClient $inner

            $wrapper.IsConnected | Should -BeTrue
            $wrapper.Disconnect()
            $wrapper.Dispose()
            $inner.DisconnectCalls | Should -Be 1
            $inner.DisposeCalls    | Should -Be 1
        }
    }
}
