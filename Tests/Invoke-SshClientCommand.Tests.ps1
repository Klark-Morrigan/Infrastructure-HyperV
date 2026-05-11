BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Invoke-SshClientCommand.ps1"

    # Replace the SSH.NET load guard with a no-op so tests can run on hosts
    # without Posh-SSH installed. Assert-SshNetLoaded itself is covered by
    # its own test file.
    function Assert-SshNetLoaded { }

    # Builds a fake SshClient whose RunCommand method returns a controlled
    # result. Uses GetNewClosure() so each call to New-FakeClient captures
    # its own $fakeResult rather than sharing a single variable.
    function New-FakeClient {
        param(
            [string] $Result     = '',
            [string] $Error      = '',
            [int]    $ExitStatus = 0
        )
        $fakeResult = [PSCustomObject]@{
            Result     = $Result
            Error      = $Error
            ExitStatus = $ExitStatus
        }
        $client = [PSCustomObject]@{}
        Add-Member -InputObject $client -MemberType ScriptMethod -Name 'RunCommand' `
            -Value ({ param($cmd) $fakeResult }.GetNewClosure())
        $client
    }
}

Describe 'Invoke-SshClientCommand' {

    # ------------------------------------------------------------------
    Context 'result mapping' {
    # ------------------------------------------------------------------

        It 'maps Result to Output' {
            $r = Invoke-SshClientCommand -SshClient (New-FakeClient -Result 'hello') -Command 'echo hello'
            $r.Output | Should -Be 'hello'
        }

        It 'maps Error to Error' {
            $r = Invoke-SshClientCommand -SshClient (New-FakeClient -Error 'oops') -Command 'bad'
            $r.Error | Should -Be 'oops'
        }

        It 'maps ExitStatus to ExitStatus on success' {
            $r = Invoke-SshClientCommand -SshClient (New-FakeClient -ExitStatus 0) -Command 'true'
            $r.ExitStatus | Should -Be 0
        }

        It 'maps ExitStatus to ExitStatus on failure' {
            $r = Invoke-SshClientCommand -SshClient (New-FakeClient -ExitStatus 1) -Command 'false'
            $r.ExitStatus | Should -Be 1
        }

        It 'maps a non-zero exit code other than 1' {
            $r = Invoke-SshClientCommand -SshClient (New-FakeClient -ExitStatus 127) -Command 'missing'
            $r.ExitStatus | Should -Be 127
        }

        It 'maps all three fields correctly when all are populated' {
            $r = Invoke-SshClientCommand `
                -SshClient (New-FakeClient -Result 'out' -Error 'err' -ExitStatus 2) `
                -Command 'cmd'
            $r.Output     | Should -Be 'out'
            $r.Error      | Should -Be 'err'
            $r.ExitStatus | Should -Be 2
        }
    }

    # ------------------------------------------------------------------
    Context 'command forwarding' {
    # ------------------------------------------------------------------

        It 'passes the Command string verbatim to RunCommand' {
            # Capture the argument that RunCommand receives so we can assert
            # Invoke-SshClientCommand does not modify or re-encode it.
            $script:_captured = $null
            $client = [PSCustomObject]@{}
            Add-Member -InputObject $client -MemberType ScriptMethod -Name 'RunCommand' -Value {
                param($cmd)
                $script:_captured = $cmd
                [PSCustomObject]@{ Result = ''; Error = ''; ExitStatus = 0 }
            }
            $raw = "sudo getent group 'docker'"
            Invoke-SshClientCommand -SshClient $client -Command $raw | Out-Null
            $script:_captured | Should -Be $raw
        }
    }

    # ------------------------------------------------------------------
    Context 'output shape' {
    # ------------------------------------------------------------------

        It 'returns an object with exactly Output, Error, and ExitStatus properties' {
            $r = Invoke-SshClientCommand -SshClient (New-FakeClient) -Command 'id'
            ($r | Get-Member -MemberType NoteProperty).Name | Sort-Object |
                Should -Be @('Error', 'ExitStatus', 'Output')
        }
    }
}
