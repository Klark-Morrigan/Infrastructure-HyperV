BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so command resolution
    # succeeds without loading the whole module. The tests capture or
    # re-mock per case.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Filesystem\Remove-VmDirectory.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
}

Describe 'Remove-VmDirectory' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'allowlisted paths (happy path)' {

        It 'accepts /opt/{name}' {
            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo rm -rf --'
            }
        }

        It 'accepts /var/lib/infra-provisioner/{rest}' {
            Remove-VmDirectory -SshClient $script:FakeSshClient `
                -Path '/var/lib/infra-provisioner/manifests/x.json'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo rm -rf --'
            }
        }

        It 'accepts /usr/local/share/{name}' {
            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/usr/local/share/y'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo rm -rf --'
            }
        }

        It 'emits set -e at the top of the script' {
            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '(?m)^set -e\b'
            }
        }

        It 'contains the existence short-circuit (exit 0 when absent)' {
            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '\[ ! -e "\$path" \] && \[ ! -L "\$path" \]' -and
                $Command -match '(?m)^\s*exit 0\b'
            }
        }

        It 'contains the not-a-directory guard that exits 65' {
            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '\[ ! -d "\$path" \] \|\| \[ -L "\$path" \]' -and
                $Command -match 'exit 65'
            }
        }

        It 'embeds Path as a single-quoted bash assignment' {
            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "path='/opt/foo'"
            }
        }
    }

    Context 'host-side validation: malformed paths' {

        It 'throws before SSH on an empty Path' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a relative Path' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path 'opt/foo' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing ..' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient `
                -Path '/opt/../etc' } | Should -Throw -ExpectedMessage '*..*'
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on a Path containing NUL' {
            $bad = '/opt/foo' + [char]0 + 'bar'
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path $bad } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It "throws before SSH on a Path containing a single quote" {
            { Remove-VmDirectory -SshClient $script:FakeSshClient `
                -Path "/opt/foo'bar" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'host-side validation: outside allowlist' {

        # /optimist is the prefix-vs-trailing-slash regression: a naive
        # StartsWith('/opt') would admit it. The allowlist entries
        # include the trailing slash specifically to block this.
        It 'throws before SSH on /optimist (prefix-without-slash trap)' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/optimist' } |
                Should -Throw -ExpectedMessage '*outside the allowlist*'
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on /opt (allowlist prefix itself, no child)' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on /etc/passwd (not under any allowlist entry)' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/etc/passwd' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on /home/user (not under any allowlist entry)' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/home/user' } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'host-side validation: denylist enumeration' {

        # Mirrors the literal list in the cmdlet. The parity test below
        # surfaces any addition that lands in the cmdlet without a
        # matching case here.
        It "rejects denylist literal '<denied>'" -TestCases @(
            @{ denied = '/' }
            @{ denied = '/usr' }
            @{ denied = '/usr/local' }
            @{ denied = '/etc' }
            @{ denied = '/home' }
            @{ denied = '/var' }
            @{ denied = '/var/lib' }
            @{ denied = '/root' }
            @{ denied = '/boot' }
            @{ denied = '/lib' }
            @{ denied = '/lib64' }
            @{ denied = '/sbin' }
            @{ denied = '/bin' }
            @{ denied = '/proc' }
            @{ denied = '/sys' }
            @{ denied = '/dev' }
            @{ denied = '/run' }
            @{ denied = '/tmp' }
        ) {
            param($denied)
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path $denied } |
                Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'parity: every literal in the dot-sourced denylist has a TestCase above' {
            $expected = @(
                '/', '/usr', '/usr/local', '/etc', '/home', '/var', '/var/lib',
                '/root', '/boot', '/lib', '/lib64', '/sbin', '/bin', '/proc',
                '/sys', '/dev', '/run', '/tmp'
            ) | Sort-Object
            # $script:RemoveVmDirectory_DeniedPaths is populated by the
            # dot-source in BeforeAll. If a new literal is added to the
            # cmdlet without updating this list, the parity assertion
            # fails and points at the missing entry.
            $actual = @($script:RemoveVmDirectory_DeniedPaths) | Sort-Object
            ($actual -join ',') | Should -Be ($expected -join ',')
        }

        It 'parity: every literal in the allowlist is present' {
            $expected = @(
                '/opt/',
                '/var/lib/infra-provisioner/',
                '/usr/local/share/'
            ) | Sort-Object
            $actual = @($script:RemoveVmDirectory_AllowedParentPrefixes) | Sort-Object
            ($actual -join ',') | Should -Be ($expected -join ',')
        }
    }

    Context 'remote error handling' {

        It 'returns silently on ExitStatus 0' {
            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo' } |
                Should -Not -Throw
        }

        It 'throws naming the path on ExitStatus 65 (conflict)' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 65
                    Output     = ''
                    Error      = 'exists as regular file'
                }
            }

            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo' } |
                Should -Throw -ExpectedMessage '*/opt/foo*'
        }

        It 'includes the observed-type stderr in the conflict exception' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 65
                    Output     = ''
                    Error      = 'exists as symlink'
                }
            }

            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo' } |
                Should -Throw -ExpectedMessage '*exists as symlink*'
        }

        It 'throws with stderr on non-zero / non-65 ExitStatus' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = 'rm: permission denied'
                }
            }

            { Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo' } |
                Should -Throw -ExpectedMessage '*permission denied*'
        }
    }

    Context 'line-ending normalisation' {

        It 'emits no CR bytes in the command' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Remove-VmDirectory -SshClient $script:FakeSshClient -Path '/opt/foo'

            $script:captured | Should -Not -Match "`r"
        }
    }
}
