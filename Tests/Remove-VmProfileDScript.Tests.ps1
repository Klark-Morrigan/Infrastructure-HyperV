BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so command
    # resolution succeeds without loading the whole module. The tests
    # re-mock it per case to capture or shape the emitted script and
    # the simulated remote exit.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\ProfileD\Assert-VmProfileDScriptName.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\ProfileD\Remove-VmProfileDScript.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
}

Describe 'Remove-VmProfileDScript' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'emitted script shape' {

        It 'targets /etc/profile.d/{Name}.sh and contains the existence guard + sudo rm' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo'

            $script:captured | Should -Match 'set -e'
            $script:captured | Should -Match ([regex]::Escape("TARGET='/etc/profile.d/foo.sh'"))
            $script:captured | Should -Match '\[ ! -e "\$TARGET" \]'
            $script:captured | Should -Match ([regex]::Escape('sudo rm "$TARGET"'))
        }

        It 'orders the existence guard before sudo rm so an absent file is a no-op' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo'

            $iGuard = $script:captured.IndexOf('! -e "$TARGET"')
            $iRm    = $script:captured.IndexOf('sudo rm')

            $iGuard | Should -BeGreaterThan -1
            $iRm    | Should -BeGreaterThan $iGuard
        }

        It 'sends LF-only line endings (no CR bytes)' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo'

            $script:captured | Should -Not -Match "`r"
            $script:captured | Should -Match "`n"
        }
    }

    Context 'remote exit handling' {

        It 'returns silently on ExitStatus 0 (file removed or already absent)' {
            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo' } |
                Should -Not -Throw
        }

        It 'throws with VM IP, name, exit code, and captured stderr on non-zero exit' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 5; Output = ''; Error = 'permission denied' }
            }

            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo' } |
                Should -Throw -ExpectedMessage '*10.10.0.50*foo*permission denied*'
        }
    }

    Context 'host-side name validation (one case per shape - matches Set-VmProfileDScript)' {

        It 'throws before SSH on empty Name' {
            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name '' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name containing /' {
            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo/bar' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name ending in .sh' {
            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo.sh' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name containing a space' {
            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name 'foo bar' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name equal to ..' {
            { Remove-VmProfileDScript -SshClient $script:FakeSshClient -Name '..' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }
}
