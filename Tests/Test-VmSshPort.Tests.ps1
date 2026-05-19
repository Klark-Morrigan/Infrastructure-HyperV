BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Ssh\Test-VmSshPort.ps1"
}

Describe 'Test-VmSshPort' {

    Context 'against a locally bound listener' {

        BeforeAll {
            # Bind to a system-assigned free port on the loopback interface
            # so the test exercises the real ConnectAsync path against a
            # real socket without needing root or external network access.
            $Script:listener = [System.Net.Sockets.TcpListener]::new(
                [System.Net.IPAddress]::Loopback, 0)
            $Script:listener.Start()
            $Script:openPort = ([System.Net.IPEndPoint] $Script:listener.LocalEndpoint).Port
        }

        AfterAll {
            if ($null -ne $Script:listener) { $Script:listener.Stop() }
        }

        It 'returns $true when the port accepts a connection' {
            Test-VmSshPort -IpAddress '127.0.0.1' -Port $Script:openPort `
                | Should -BeTrue
        }
    }

    Context 'against a closed port' {

        It 'returns $false within the configured timeout' {
            # Port 1 on loopback is reserved and not bound by any service
            # in the CI image - the OS rejects the SYN immediately, so
            # the connect fails fast without waiting out the timeout.
            Test-VmSshPort -IpAddress '127.0.0.1' -Port 1 `
                -TimeoutMilliseconds 500 | Should -BeFalse
        }
    }

    Context 'against an unroutable address' {

        It 'returns $false when the connect times out' {
            # 192.0.2.0/24 is TEST-NET-1 (RFC 5737) - guaranteed not to be
            # routed. ConnectAsync sits until the timeout fires, which is
            # the slow path the timeout parameter exists to bound.
            Test-VmSshPort -IpAddress '192.0.2.1' -Port 22 `
                -TimeoutMilliseconds 200 | Should -BeFalse
        }
    }
}
