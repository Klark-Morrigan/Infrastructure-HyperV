BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Ssh\Set-SshClientKeepAlive.ps1"

    # Duck-typed stand-in for an SSH.NET client: the helper only assigns the
    # KeepAliveInterval property, so a PSCustomObject seeded with SSH.NET's
    # real default (Timeout.InfiniteTimeSpan) is enough to prove both the
    # "set" and the "left untouched" branches without resolving the Renci
    # type or opening a connection.
    function New-FakeSshClient {
        [PSCustomObject]@{ KeepAliveInterval = [System.Threading.Timeout]::InfiniteTimeSpan }
    }
}

Describe 'Set-SshClientKeepAlive' {

    Context 'positive interval is applied' {

        It 'assigns the interval to the client' {
            $client = New-FakeSshClient
            Set-SshClientKeepAlive -Client $client -Interval ([TimeSpan]::FromSeconds(15))
            $client.KeepAliveInterval | Should -Be ([TimeSpan]::FromSeconds(15))
        }

        It 'assigns a sub-second interval verbatim' {
            $client = New-FakeSshClient
            Set-SshClientKeepAlive -Client $client -Interval ([TimeSpan]::FromMilliseconds(500))
            $client.KeepAliveInterval | Should -Be ([TimeSpan]::FromMilliseconds(500))
        }
    }

    Context 'non-positive interval leaves SSH.NET default untouched' {

        It 'does not touch the property for a zero interval' {
            $client = New-FakeSshClient
            Set-SshClientKeepAlive -Client $client -Interval ([TimeSpan]::Zero)
            $client.KeepAliveInterval | Should -Be ([System.Threading.Timeout]::InfiniteTimeSpan)
        }

        It 'does not touch the property for a negative interval' {
            $client = New-FakeSshClient
            Set-SshClientKeepAlive -Client $client -Interval ([TimeSpan]::FromSeconds(-5))
            $client.KeepAliveInterval | Should -Be ([System.Threading.Timeout]::InfiniteTimeSpan)
        }
    }
}
