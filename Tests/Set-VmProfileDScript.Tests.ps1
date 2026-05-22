BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so command
    # resolution succeeds without loading the whole module. The tests
    # re-mock it per case to capture or shape the emitted script and
    # the simulated remote exit.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    # The cmdlet composes the atomic-write tail via the private helper.
    # Dot-source it directly so the test does not need to import the
    # whole module.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Bash\New-AtomicWriteBashFragment.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\ProfileD\Assert-VmProfileDScriptName.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\ProfileD\Set-VmProfileDScript.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
}

Describe 'Set-VmProfileDScript' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'default (skip-unchanged on)' {

        It 'emits set -euo pipefail at the top of the script' {
            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'set -euo pipefail'
            }
        }

        It 'derives the target path /etc/profile.d/{Name}.sh from the Name parameter' {
            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match [regex]::Escape("TARGET='/etc/profile.d/foo.sh'") -and
                $Command -match [regex]::Escape('sudo mv "$TMP" "/etc/profile.d/foo.sh"')
            }
        }

        It 'emits the reconcile branch (EXISTING extract + byte-equality + early exit 0) BEFORE the write' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            $script:captured | Should -Match 'EXISTING='
            $script:captured | Should -Match '\[ "\$EXISTING" = "\$DESIRED" \]'
            # The exit 0 short-circuit sits before the atomic-mv;
            # otherwise it would never fire.
            $script:captured.IndexOf('exit 0') | Should -BeGreaterThan -1
            $script:captured.IndexOf('exit 0') | Should -BeLessThan $script:captured.IndexOf('sudo mv')
        }

        It 'embeds the atomic-write fragment produced by New-AtomicWriteBashFragment' {
            # The reason this test composes the expected fragment via the
            # helper instead of asserting on substrings is the plan's
            # contract: this cmdlet must use the helper byte-for-byte so
            # a future hardening of the atomic-write pattern lands in one
            # place. The match is therefore intentionally exact.
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            $expectedFragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/profile.d/foo.sh' `
                -ContentVar 'DESIRED'

            $script:captured | Should -BeLike "*$expectedFragment*"
        }

        It 'emits the atomic-write order: tee -> chown -> chmod -> mv' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            $iTee   = $script:captured.IndexOf('sudo tee')
            $iChown = $script:captured.IndexOf('sudo chown root:root')
            $iChmod = $script:captured.IndexOf('sudo chmod 0644')
            $iMv    = $script:captured.IndexOf('sudo mv')

            $iTee   | Should -BeGreaterThan -1
            $iChown | Should -BeGreaterThan $iTee
            $iChmod | Should -BeGreaterThan $iChown
            $iMv    | Should -BeGreaterThan $iChmod
        }

        It 'sends LF-only line endings (no CR bytes)' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            $script:captured | Should -Not -Match "`r"
            $script:captured | Should -Match "`n"
        }
    }

    Context '-NoSkipUnchanged' {

        It 'omits the reconcile branch entirely' {
            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n" `
                                 -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -notmatch 'EXISTING=' -and
                $Command -notmatch '\$EXISTING' -and
                $Command -notmatch '(?m)^exit 0$'
            }
        }

        It 'still embeds the atomic-write fragment' {
            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n" `
                                 -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo tee' -and
                $Command -match 'sudo chown root:root' -and
                $Command -match 'sudo chmod 0644' -and
                $Command -match 'sudo mv'
            }
        }
    }

    Context 'trailing-newline normalisation' {

        It 'appends a trailing LF to Content if missing (visible in the embedded heredoc body)' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content 'export FOO=1'

            # Heredoc body is between the namespaced delimiters; the body
            # ends with the (normalised) Content so it must contain
            # "export FOO=1\n" - a trailing LF after the line.
            $body = [regex]::Match($script:captured,
                "__INFRA_HYPERV_PROFILED_CONTENT__'?\n(?<body>.*?)\n__INFRA_HYPERV_PROFILED_CONTENT__",
                [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $body.Success | Should -BeTrue
            $body.Groups['body'].Value | Should -BeExactly "export FOO=1`n"
        }

        It 'does not double a newline when Content already ends with LF' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content "export FOO=1`n"

            $body = [regex]::Match($script:captured,
                "__INFRA_HYPERV_PROFILED_CONTENT__'?\n(?<body>.*?)\n__INFRA_HYPERV_PROFILED_CONTENT__",
                [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $body.Success | Should -BeTrue
            $body.Groups['body'].Value | Should -BeExactly "export FOO=1`n"
        }
    }

    Context 'content with shell metacharacters' {

        It 'embeds single-quote, double-quote, dollar, and backslash literally (single-quoted heredoc protects them)' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            $payload = "echo `"`$HOME`" 'literal' \\ end"
            Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                 -Name 'foo' `
                                 -Content $payload

            $body = [regex]::Match($script:captured,
                "__INFRA_HYPERV_PROFILED_CONTENT__'?\n(?<body>.*?)\n__INFRA_HYPERV_PROFILED_CONTENT__",
                [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $body.Success | Should -BeTrue
            # Trailing LF appended by the normaliser; otherwise the body
            # must equal the input byte-for-byte.
            $body.Groups['body'].Value | Should -BeExactly "$payload`n"
        }
    }

    Context 'host-side name validation' {

        It 'throws before SSH on empty Name' {
            { Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                   -Name '' `
                                   -Content "x`n" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name containing /' {
            { Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                   -Name 'foo/bar' `
                                   -Content "x`n" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name ending in .sh' {
            { Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                   -Name 'foo.sh' `
                                   -Content "x`n" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name containing a space' {
            { Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                   -Name 'foo bar' `
                                   -Content "x`n" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }

        It 'throws before SSH on Name equal to ..' {
            { Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                   -Name '..' `
                                   -Content "x`n" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'SSH failure surfaces a diagnostic error' {

        It 'throws with VM IP, name, exit code, and captured stderr on non-zero exit' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 5; Output = ''; Error = 'permission denied' }
            }

            { Set-VmProfileDScript -SshClient $script:FakeSshClient `
                                   -Name 'foo' `
                                   -Content "export FOO=1`n" } |
                Should -Throw -ExpectedMessage '*10.10.0.50*foo*permission denied*'
        }
    }
}
