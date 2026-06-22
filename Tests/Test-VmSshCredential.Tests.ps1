BeforeAll {
    # Stub the connector this probe wraps so Pester can Mock it and the
    # classification logic is testable without SSH.NET loaded. The real
    # New-VmSshClient (Public\Ssh\New-VmSshClient.ps1) returns a connected
    # Renci SshClient; every test overrides this with a Mock.
    function New-VmSshClient {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'Password')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingUsernameAndPasswordParams', '')]
        param(
            [string] $IpAddress, [string] $Username, [string] $Password,
            [int] $Port = 22, [TimeSpan] $Timeout
        )
    }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Ssh\Test-VmSshCredential.ps1"

    # Fake connected client recording Disconnect/Dispose so the cleanup
    # contract can be asserted.
    function New-FakeSshClient {
        $script:_disconnects = 0
        $script:_disposes    = 0
        $client = [PSCustomObject]@{ IsConnected = $true }
        $client | Add-Member ScriptMethod Disconnect { $script:_disconnects++ }
        $client | Add-Member ScriptMethod Dispose    { $script:_disposes++ }
        $client
    }
}

Describe 'Test-VmSshCredential' {

    Context 'credentials accepted' {

        It 'returns $true when the connect succeeds' {
            Mock New-VmSshClient { New-FakeSshClient }

            Test-VmSshCredential -IpAddress '10.0.0.1' -Username 'admin' -Password 'p' |
                Should -BeTrue
        }

        It 'forwards the endpoint and credentials to New-VmSshClient' {
            Mock New-VmSshClient { New-FakeSshClient }

            Test-VmSshCredential -IpAddress '10.0.0.1' -Username 'admin' `
                -Password 'secret' -Port 2222 | Out-Null

            Should -Invoke New-VmSshClient -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '10.0.0.1' -and
                $Username  -eq 'admin'    -and
                $Password  -eq 'secret'   -and
                $Port      -eq 2222
            }
        }

        It 'disconnects and disposes the session it opened' {
            Mock New-VmSshClient { New-FakeSshClient }

            Test-VmSshCredential -IpAddress '10.0.0.1' -Username 'admin' -Password 'p' |
                Out-Null

            $script:_disconnects | Should -Be 1
            $script:_disposes    | Should -Be 1
        }
    }

    Context 'credentials rejected' {

        It 'returns $false on a Permission denied failure (does not throw)' {
            # SSH.NET surfaces a rejected password with this exact text -
            # the real-world classification path.
            Mock New-VmSshClient { throw 'Permission denied (password).' }

            Test-VmSshCredential -IpAddress '10.0.0.1' -Username 'admin' -Password 'p' |
                Should -BeFalse
        }
    }

    Context 'transient / unreachable failures' {

        It 'rethrows a transient connect error unchanged' {
            # A timeout/refused/KEX failure says nothing about the
            # credentials and must keep its own surface, not collapse to
            # $false.
            Mock New-VmSshClient { throw 'Connection timed out while opening socket' }

            { Test-VmSshCredential -IpAddress '10.0.0.1' -Username 'admin' -Password 'p' } |
                Should -Throw -ExpectedMessage '*Connection timed out*'
        }
    }
}
