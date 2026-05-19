BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\FileServer\Start-VmFileServer.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\FileServer\Stop-VmFileServer.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\FileServer\Invoke-WithVmFileServer.ps1"

    $script:fakeHandle = [PSCustomObject]@{ HostIp = '10.10.0.1'; Port = 8745 }

    Mock Start-VmFileServer { $script:fakeHandle }
    Mock Stop-VmFileServer {}
}

Describe 'Invoke-WithVmFileServer' {

    Context 'server startup' {

        It 'calls Start-VmFileServer with VmIpAddress and Port' {
            Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -Port 9000 -ScriptBlock {}
            Should -Invoke Start-VmFileServer -Times 1 -Exactly `
                -ParameterFilter { $VmIpAddress -eq '10.10.0.50' -and $Port -eq 9000 }
        }

        It 'calls Start-VmFileServer with HostIp and Port' {
            Invoke-WithVmFileServer -HostIp '10.10.0.1' -Port 9001 -ScriptBlock {}
            Should -Invoke Start-VmFileServer -Times 1 -Exactly `
                -ParameterFilter { $HostIp -eq '10.10.0.1' -and $Port -eq 9001 }
        }

        It 'uses the default port when none is specified' {
            Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {}
            Should -Invoke Start-VmFileServer -Times 1 -Exactly `
                -ParameterFilter { $Port -eq 8745 }
        }
    }

    Context 'script block execution' {

        It 'passes the server handle to the script block' {
            $script:received = $null
            Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
                param($server)
                $script:received = $server
            }
            $script:received | Should -Be $script:fakeHandle
        }

        It 'returns the script block output to the caller' {
            $result = Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
                'expected-output'
            }
            $result | Should -Be 'expected-output'
        }
    }

    Context 'server shutdown' {

        It 'calls Stop-VmFileServer with the server handle on success' {
            Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {}
            Should -Invoke Stop-VmFileServer -Times 1 -Exactly `
                -ParameterFilter { $Server -eq $script:fakeHandle }
        }

        It 'calls Stop-VmFileServer even when the script block throws' {
            { Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
                throw 'script block error'
            } } | Should -Throw
            Should -Invoke Stop-VmFileServer -Times 1 -Exactly
        }

        It 'propagates the script block exception to the caller' {
            { Invoke-WithVmFileServer -VmIpAddress '10.10.0.50' -ScriptBlock {
                throw 'script block error'
            } } | Should -Throw -ExpectedMessage '*script block error*'
        }
    }
}
