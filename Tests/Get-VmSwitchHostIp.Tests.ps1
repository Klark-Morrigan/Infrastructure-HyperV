BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Get-VmSwitchHostIp.ps1"
}

Describe 'Get-VmSwitchHostIp' {

    Context 'when a host adapter exists on the same /24' {

        It 'returns the matching adapter IP' {
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '10.10.0.1'; AddressFamily = 'IPv4' },
                    [PSCustomObject]@{ IPAddress = '192.168.1.5'; AddressFamily = 'IPv4' }
                )
            }

            Get-VmSwitchHostIp -VmIpAddress '10.10.0.50' | Should -Be '10.10.0.1'
        }
    }

    Context 'when no adapter shares the /24 prefix' {

        It 'throws a descriptive error' {
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '192.168.1.5'; AddressFamily = 'IPv4' }
                )
            }

            { Get-VmSwitchHostIp -VmIpAddress '10.10.0.50' } |
                Should -Throw -ExpectedMessage "*No host adapter found*'10.10.0.50'*"
        }
    }

    Context 'when the VM IP itself appears in Get-NetIPAddress output' {

        It 'excludes the VM IP and returns the host adapter IP' {
            # Get-NetIPAddress may list the VM's own address if this host is
            # simultaneously acting as a guest (unusual, but possible in nested
            # Hyper-V). The function must not return the VM's own IP as the host.
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '10.10.0.50'; AddressFamily = 'IPv4' },
                    [PSCustomObject]@{ IPAddress = '10.10.0.1';  AddressFamily = 'IPv4' }
                )
            }

            Get-VmSwitchHostIp -VmIpAddress '10.10.0.50' | Should -Be '10.10.0.1'
        }

        It 'throws when the only matching address is the VM IP itself' {
            Mock Get-NetIPAddress {
                @(
                    [PSCustomObject]@{ IPAddress = '10.10.0.50'; AddressFamily = 'IPv4' }
                )
            }

            { Get-VmSwitchHostIp -VmIpAddress '10.10.0.50' } |
                Should -Throw -ExpectedMessage "*No host adapter found*"
        }
    }
}
