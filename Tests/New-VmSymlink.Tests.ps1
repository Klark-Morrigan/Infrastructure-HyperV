BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so command resolution
    # succeeds without loading the whole module. The tests capture or
    # re-mock per case.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Symlinks\New-VmSymlink.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
}

Describe 'New-VmSymlink' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'happy path' {

        It 'emits set -e at the top of the script' {
            New-VmSymlink -SshClient $script:FakeSshClient `
                          -Path '/usr/local/bin/foo' `
                          -Target '/opt/foo/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '(?m)^set -e\b'
            }
        }

        It 'contains the readlink-equality short-circuit' {
            New-VmSymlink -SshClient $script:FakeSshClient `
                          -Path '/usr/local/bin/foo' `
                          -Target '/opt/foo/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'readlink "\$path"' -and
                $Command -match '= "\$target"'
            }
        }

        It 'contains the conflict guard that exits 65 when path exists' {
            New-VmSymlink -SshClient $script:FakeSshClient `
                          -Path '/usr/local/bin/foo' `
                          -Target '/opt/foo/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '\[ -e "\$path" \] \|\| \[ -L "\$path" \]' -and
                $Command -match 'exit 65'
            }
        }

        It 'invokes sudo ln -s with target then path' {
            New-VmSymlink -SshClient $script:FakeSshClient `
                          -Path '/usr/local/bin/foo' `
                          -Target '/opt/foo/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo ln -s "\$target" "\$path"'
            }
        }

        It 'embeds Path and Target as single-quoted bash assignments' {
            New-VmSymlink -SshClient $script:FakeSshClient `
                          -Path '/usr/local/bin/foo' `
                          -Target '/opt/foo/bin/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "path='/usr/local/bin/foo'" -and
                $Command -match "target='/opt/foo/bin/foo'"
            }
        }
    }

    Context 'remote error handling' {

        It 'returns silently on ExitStatus 0' {
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target '/opt/foo/bin/foo' } | Should -Not -Throw
        }

        It 'throws naming the path on ExitStatus 65 (conflict)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 65
                    Output     = ''
                    Error      = 'exists as regular file'
                }
            }

            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target '/opt/foo/bin/foo' } |
                Should -Throw -ExpectedMessage '*/usr/local/bin/foo*'
        }

        It 'includes the observed-type stderr in the conflict exception' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 65
                    Output     = ''
                    Error      = 'exists as directory'
                }
            }

            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target '/opt/foo/bin/foo' } |
                Should -Throw -ExpectedMessage '*exists as directory*'
        }

        It 'throws with stderr on non-zero / non-65 ExitStatus' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = 'ln: permission denied'
                }
            }

            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target '/opt/foo/bin/foo' } |
                Should -Throw -ExpectedMessage '*permission denied*'
        }
    }

    Context 'host-side validation' {

        It 'throws before SSH on a relative Path' {
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path 'usr/local/bin/foo' `
                            -Target '/opt/foo/bin/foo' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing ..' {
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/../etc/passwd' `
                            -Target '/opt/foo' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing NUL' {
            $bad = "/usr/local/bin/foo" + [char]0 + "bar"
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path $bad `
                            -Target '/opt/foo' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It "throws before SSH on a Path containing a single quote" {
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path "/usr/local/bin/foo'bar" `
                            -Target '/opt/foo' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a relative Target' {
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target 'opt/foo/bin/foo' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Target containing ..' {
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target '/opt/../etc/passwd' } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Target containing NUL' {
            $bad = "/opt/foo" + [char]0 + "bar"
            { New-VmSymlink -SshClient $script:FakeSshClient `
                            -Path '/usr/local/bin/foo' `
                            -Target $bad } | Should -Throw

            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'line-ending normalisation' {

        It 'emits no CR bytes in the command' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            New-VmSymlink -SshClient $script:FakeSshClient `
                          -Path '/usr/local/bin/foo' `
                          -Target '/opt/foo/bin/foo'

            $script:captured | Should -Not -Match "`r"
        }
    }
}
