BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Get-VmSwitchHostIp.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Start-VmFileServer.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Stop-VmFileServer.ps1"
}

# Integration tests: these spin up a real HttpListener and require elevated
# privileges (admin) to bind to the port. On GitHub Actions Windows runners
# this is satisfied automatically.
Describe 'Start-VmFileServer' {

    BeforeAll {
        # Suppress OS-level side effects so the test host does not need
        # firewall admin rights beyond the HttpListener itself.
        Mock New-NetFirewallRule {}
        Mock Remove-NetFirewallRule {}

        $script:port   = Get-Random -Minimum 50000 -Maximum 59999
        $script:server = Start-VmFileServer -HostIp '127.0.0.1' -Port $script:port
    }

    AfterAll {
        if ($script:server) {
            Stop-VmFileServer -Server $script:server
        }
    }

    Context 'server handle' {

        It 'exposes HostIp' {
            $script:server.HostIp | Should -Be '127.0.0.1'
        }

        It 'exposes Port' {
            $script:server.Port | Should -Be $script:port
        }

        It 'exposes BaseUrl' {
            $script:server.BaseUrl | Should -Be "http://127.0.0.1:$($script:port)"
        }

        It 'creates the staging directory' {
            $script:server.StagingDir | Should -Exist
        }

        It 'stores the firewall rule name' {
            $script:server.FirewallRuleName | Should -Be "VmFileServer-$($script:port)"
        }
    }

    Context 'file serving' {

        It 'serves a file placed in the staging directory' {
            $filePath = Join-Path $script:server.StagingDir 'test.txt'
            # WriteAllText uses UTF-8 without BOM so the served bytes are
            # exactly the string with no preamble.
            [System.IO.File]::WriteAllText($filePath, 'hello-world')

            $response = Invoke-WebRequest `
                -Uri             "$($script:server.BaseUrl)/test.txt" `
                -UseBasicParsing `
                -ErrorAction     Stop

            $response.StatusCode | Should -Be 200
            # Invoke-WebRequest returns Content as byte[] when no Content-Type
            # is set; decode to string for a readable comparison.
            $content = if ($response.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($response.Content)
            } else {
                [string]$response.Content
            }
            $content | Should -Be 'hello-world'
        }

        It 'returns 404 for a file that is not in the staging directory' {
            $statusCode = $null
            try {
                Invoke-WebRequest `
                    -Uri             "$($script:server.BaseUrl)/no-such-file.txt" `
                    -UseBasicParsing `
                    -ErrorAction     Stop
            } catch {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $statusCode | Should -Be 404
        }
    }
}
