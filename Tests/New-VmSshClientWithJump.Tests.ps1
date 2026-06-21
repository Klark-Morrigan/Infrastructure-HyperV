# The BeforeAll stubs mirror SSH.NET's plaintext username/password contract
# (the production functions take the pair as strings and suppress this rule
# for the same reason). The stubs must keep the real parameter names so
# Mock -ParameterFilter can assert on $Password, so suppress file-wide
# rather than renaming the test doubles.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Test-double stubs mirror SSH.NET''s plaintext password contract')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingUsernameAndPasswordParams', '',
    Justification = 'Test-double stubs mirror SSH.NET''s username/password pair')]
param()

BeforeAll {
    # Stub the three commands the function depends on so the unit test stays
    # off the network and off the Renci types. New-VmSshClient and
    # New-VmSshTunnel carry the real parameter names so Mock -ParameterFilter
    # can assert on them. Assert-SshNetLoaded is a no-op guard here; its own
    # behaviour is covered by Assert-SshNetLoaded.Tests.ps1.
    function Assert-SshNetLoaded { }
    function New-VmSshClient {
        param($IpAddress, $Port, $Username, $Password, $Timeout, $KeepAliveInterval)
    }
    function New-VmSshTunnel {
        param($TargetIp, $JumpHostIp, $JumpUsername, $JumpPassword, $JumpConnectTimeout)
    }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Ssh\New-VmSshClientWithJump.ps1"

    # Records the order Dispose() is called across fakes so the jumped-path
    # "client before tunnel" teardown contract can be asserted.
    function New-FakeClient {
        $c = [PSCustomObject]@{ Connected = $true; DisconnectCalls = 0; DisposeCalls = 0 }
        $c | Add-Member ScriptProperty IsConnected { $this.Connected } -Force
        $c | Add-Member ScriptMethod Disconnect { $this.DisconnectCalls++; $this.Connected = $false } -Force
        $c | Add-Member ScriptMethod Dispose { $this.DisposeCalls++; $script:DisposeLog += 'client' } -Force
        $c
    }
    function New-FakeTunnel {
        param([string] $TunnelHost = '127.0.0.1', [int] $LocalPort = 55001)
        $t = [PSCustomObject]@{ LocalHost = $TunnelHost; LocalPort = $LocalPort; DisposeCalls = 0 }
        $t | Add-Member ScriptMethod Dispose { $this.DisposeCalls++; $script:DisposeLog += 'tunnel' } -Force
        $t
    }

    # VM definitions. The jump decision keys off the _RouterVm NoteProperty;
    # the direct VM simply omits it.
    $script:DirectVm = [PSCustomObject]@{
        ipAddress = '10.0.0.5'; username = 'admin'; password = 'direct-pw'
    }
    $script:JumpVm = [PSCustomObject]@{
        ipAddress = '10.99.0.10'; username = 'workload'; password = 'wl-pw'
        _RouterVm = [PSCustomObject]@{
            ipAddress = '192.168.137.10'; username = 'routeradmin'; password = 'r-pw'
        }
    }
}

Describe 'New-VmSshClientWithJump' {

    Context 'direct path (no _RouterVm)' {

        BeforeEach {
            $script:DisposeLog = @()
            $script:FakeClient = New-FakeClient
            Mock New-VmSshClient { $script:FakeClient }
            Mock New-VmSshTunnel { throw 'New-VmSshTunnel must not be called on the direct path' }
        }

        It 'connects via New-VmSshClient forwarding the VM creds, timeout and keepalive' {
            New-VmSshClientWithJump -Vm $script:DirectVm `
                -Timeout ([TimeSpan]::FromMinutes(5)) `
                -KeepAliveInterval ([TimeSpan]::FromSeconds(7)) | Out-Null

            Should -Invoke New-VmSshClient -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '10.0.0.5' -and
                $Username  -eq 'admin' -and
                $Password  -eq 'direct-pw' -and
                $Timeout   -eq ([TimeSpan]::FromMinutes(5)) -and
                $KeepAliveInterval -eq ([TimeSpan]::FromSeconds(7))
            }
        }

        It 'does not pass -Port so New-VmSshClient uses its default 22' {
            New-VmSshClientWithJump -Vm $script:DirectVm | Out-Null
            # -ParameterFilter exposes the call's args as named variables;
            # an unbound -Port surfaces as $null.
            Should -Invoke New-VmSshClient -Times 1 -ParameterFilter {
                $null -eq $Port
            }
        }

        It 'forwards the default 15s keepalive when the caller omits it' {
            New-VmSshClientWithJump -Vm $script:DirectVm | Out-Null
            Should -Invoke New-VmSshClient -Times 1 -ParameterFilter {
                $KeepAliveInterval -eq ([TimeSpan]::FromSeconds(15))
            }
        }

        It 'opens no tunnel and returns a session with Tunnel = $null' {
            $session = New-VmSshClientWithJump -Vm $script:DirectVm
            Should -Invoke New-VmSshTunnel -Times 0
            $session.Client | Should -Be $script:FakeClient
            $session.Tunnel | Should -BeNullOrEmpty
        }

        It 'Dispose disconnects then disposes the client' {
            $session = New-VmSshClientWithJump -Vm $script:DirectVm
            $session.Dispose()
            $script:FakeClient.DisconnectCalls | Should -Be 1
            $script:FakeClient.DisposeCalls    | Should -Be 1
        }
    }

    Context 'jumped path (_RouterVm present)' {

        BeforeEach {
            $script:DisposeLog = @()
            $script:FakeClient = New-FakeClient
            $script:FakeTunnel = New-FakeTunnel -TunnelHost '127.0.0.1' -LocalPort 55001
            Mock New-VmSshTunnel { $script:FakeTunnel }
            Mock New-VmSshClient { $script:FakeClient }
        }

        It 'opens the tunnel against the router neighbour with the workload as target' {
            New-VmSshClientWithJump -Vm $script:JumpVm `
                -Timeout ([TimeSpan]::FromMinutes(10)) | Out-Null

            Should -Invoke New-VmSshTunnel -Times 1 -Exactly -ParameterFilter {
                $TargetIp           -eq '10.99.0.10' -and
                $JumpHostIp         -eq '192.168.137.10' -and
                $JumpUsername       -eq 'routeradmin' -and
                $JumpPassword       -eq 'r-pw' -and
                $JumpConnectTimeout -eq ([TimeSpan]::FromMinutes(10))
            }
        }

        It 'connects through the helper to the tunnel loopback endpoint via -Port' {
            New-VmSshClientWithJump -Vm $script:JumpVm `
                -KeepAliveInterval ([TimeSpan]::FromSeconds(9)) | Out-Null

            Should -Invoke New-VmSshClient -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '127.0.0.1' -and
                $Port      -eq 55001 -and
                $Username  -eq 'workload' -and
                $Password  -eq 'wl-pw' -and
                $KeepAliveInterval -eq ([TimeSpan]::FromSeconds(9))
            }
        }

        It 'returns a session holding both the client and the tunnel' {
            $session = New-VmSshClientWithJump -Vm $script:JumpVm
            $session.Client | Should -Be $script:FakeClient
            $session.Tunnel | Should -Be $script:FakeTunnel
        }

        It 'Dispose tears down the client before the tunnel' {
            $session = New-VmSshClientWithJump -Vm $script:JumpVm
            $session.Dispose()
            $script:FakeClient.DisposeCalls | Should -Be 1
            $script:FakeTunnel.DisposeCalls | Should -Be 1
            $script:DisposeLog | Should -Be @('client', 'tunnel')
        }

        It 'disposes the tunnel and rethrows when the client connect fails' {
            Mock New-VmSshClient { throw 'connect failed' }
            { New-VmSshClientWithJump -Vm $script:JumpVm } |
                Should -Throw '*connect failed*'
            # The tunnel must not leak when the inner connect dies.
            $script:FakeTunnel.DisposeCalls | Should -Be 1
        }
    }
}
