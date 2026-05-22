BeforeAll {
    # Stub the module's other public functions that Set-VmEnvironmentVariables
    # calls (Invoke-SshClientCommand) before dot-sourcing so command resolution
    # succeeds without loading the whole module. Assert-VmEnvVarsField is real:
    # the transport's contract is "validation happens before SSH", which can
    # only be locked in with the real validator participating.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    # The cmdlet calls New-AtomicWriteBashFragment (private helper) to
    # build the temp-file + chown + chmod + mv tail. Dot-source it here
    # so command resolution succeeds without loading the whole module.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Bash\New-AtomicWriteBashFragment.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\EnvVars\Assert-VmEnvVarsField.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\EnvVars\Set-VmEnvironmentVariables.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }

    # Stable default used by tests that do not exercise BlockName-specific
    # behaviour, so the marker assertions have a known string to match.
    $script:DefaultBlockName = 'test-block'
}

Describe 'Set-VmEnvironmentVariables' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'default (skip-unchanged on)' {

        It 'emits set -euo pipefail at the top of the script' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'set -euo pipefail'
            }
        }

        It 'embeds the BEGIN / END sentinel strings built from -BlockName' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match [regex]::Escape("# BEGIN $script:DefaultBlockName") -and
                $Command -match [regex]::Escape("# END $script:DefaultBlockName")
            }
        }

        It 'emits one NAME="VALUE" line per entry, in input order' {
            $entries = @(
                [PSCustomObject]@{ name = 'ALPHA'; value = 'one' },
                [PSCustomObject]@{ name = 'BETA';  value = 'two' }
            )

            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            $script:captured | Should -Match 'ALPHA="one"'
            $script:captured | Should -Match 'BETA="two"'
            $script:captured.IndexOf('ALPHA="one"') | Should -BeLessThan $script:captured.IndexOf('BETA="two"')
        }

        It 'escapes backslash and double-quote in values' {
            # Lock the escape sequences so a future regression in the
            # escape order (or a missed escape character) fails loudly.
            # Input value: he said "hi" \ path
            # Expected on the wire: he said \"hi\" \\ path
            $entries = @(
                [PSCustomObject]@{ name = 'MSG'; value = 'he said "hi" \ path' }
            )

            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            $script:captured | Should -Match ([regex]::Escape('MSG="he said \"hi\" \\ path"'))
        }

        It 'emits the reconcile block (block-extract + byte-equality + early exit 0) BEFORE the write' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            # Reconcile primitives present
            $script:captured | Should -Match 'EXISTING='
            $script:captured | Should -Match '\[ "\$EXISTING" = "\$DESIRED" \]'
            $script:captured | Should -Match 'exit 0'

            # And the exit 0 sits BEFORE the strip + write, otherwise the
            # short-circuit would never fire.
            $script:captured.IndexOf('exit 0') | Should -BeLessThan $script:captured.IndexOf('sudo mv')
        }

        It 'emits the atomic-write trio in order: write temp -> chown -> chmod -> mv' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            $iTee   = $script:captured.IndexOf('sudo tee')
            $iChown = $script:captured.IndexOf('sudo chown root:root')
            $iChmod = $script:captured.IndexOf('sudo chmod 0644')
            $iMv    = $script:captured.IndexOf('sudo mv')

            $iTee   | Should -BeGreaterThan -1
            $iChown | Should -BeGreaterThan $iTee
            $iChmod | Should -BeGreaterThan $iChown
            $iMv    | Should -BeGreaterThan $iChmod
        }

        It 'writes to a temp file in /etc and mv-s it over /etc/environment' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                # Temp must live in /etc so the final rename is on the same
                # filesystem (atomic). The trailing $$ namespaces by PID.
                $Command -match [regex]::Escape('/etc/environment.tmp.') -and
                $Command -match [regex]::Escape('TARGET=/etc/environment')
            }
        }

        It 'sends LF-only line endings (no CR) so remote bash does not see \r tokens' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -notmatch "`r" -and $Command -match "`n"
            }
        }
    }

    Context '-NoSkipUnchanged' {

        It 'omits the reconcile block - no EXISTING extract, no early exit 0' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries `
                                       -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -notmatch 'EXISTING=' -and
                $Command -notmatch 'exit 0'    -and
                $Command -notmatch '\$EXISTING'
            }
        }

        It 'still embeds the desired block and runs the atomic-write trio' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries $entries `
                                       -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'FOO="bar"'           -and
                $Command -match 'sudo tee'            -and
                $Command -match 'sudo chown root:root' -and
                $Command -match 'sudo chmod 0644'     -and
                $Command -match 'sudo mv'
            }
        }
    }

    Context 'empty entries (remove managed block)' {

        It 'still issues an SSH call (the file may already have a stale block to strip)' {
            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries @()

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly
        }

        It 'emits the strip branch with no NAME="..." lines in the desired block' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName $script:DefaultBlockName `
                                       -Entries @()

            # Strip branch present: the script still references the markers
            # for awk-based stripping of any pre-existing block.
            $script:captured | Should -Match 'STRIPPED='
            # Heredoc body between the namespaced delimiters carries the
            # block's content. For empty entries it must be empty so the
            # write branch lays no managed lines back down on the file.
            # The first delimiter is wrapped in the heredoc opening
            # quotes (<<'DELIM'), so skip past the closing single quote
            # plus the line break before capturing the body.
            $heredoc = [regex]::Match($script:captured,
                "__INFRA_HYPERV_DESIRED_BLOCK__'?\n(?<body>.*?)\n__INFRA_HYPERV_DESIRED_BLOCK__",
                [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $heredoc.Success | Should -BeTrue
            $heredoc.Groups['body'].Value | Should -BeExactly ''
        }
    }

    Context 'validation short-circuits before SSH' {

        It 'throws on duplicate names and never invokes the SSH transport' {
            $entries = @(
                [PSCustomObject]@{ name = 'FOO'; value = 'one' },
                [PSCustomObject]@{ name = 'FOO'; value = 'two' }
            )

            { Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                         -BlockName $script:DefaultBlockName `
                                         -Entries $entries } |
                Should -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }

        It 'throws on a name that is not a POSIX identifier and never invokes SSH' {
            $entries = @([PSCustomObject]@{ name = '1BAD'; value = 'x' })

            { Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                         -BlockName $script:DefaultBlockName `
                                         -Entries $entries } |
                Should -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }
    }

    Context 'SSH failure surfaces a diagnostic error' {

        It 'throws with VM IP, block name, names list, and captured stderr on non-zero exit' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 5; Output = ''; Error = 'permission denied' }
            }
            $entries = @(
                [PSCustomObject]@{ name = 'FOO'; value = 'one' },
                [PSCustomObject]@{ name = 'BAR'; value = 'two' }
            )

            { Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                         -BlockName $script:DefaultBlockName `
                                         -Entries $entries } |
                Should -Throw -ExpectedMessage "*10.10.0.50*$script:DefaultBlockName*FOO*BAR*permission denied*"
        }
    }

    Context '-BlockName' {

        It 'is mandatory - omitting it is a parameter binder error' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            # The binder, not the function body, raises this. Pester's
            # Should -Throw catches both, which is the point: no SSH
            # call can ever happen with a missing BlockName.
            { Set-VmEnvironmentVariables -SshClient $script:FakeSshClient -Entries $entries } |
                Should -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }

        It 'places the supplied name in BOTH marker assignments' {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName 'app-a' `
                                       -Entries $entries

            $script:captured | Should -Match ([regex]::Escape("BEGIN_MARKER='# BEGIN app-a'"))
            $script:captured | Should -Match ([regex]::Escape("END_MARKER='# END app-a'"))
        }

        It "two calls with different -BlockName values produce different marker assignments" {
            # Locks the wiring: a refactor that accidentally substituted
            # a constant for the parameter would emit byte-identical
            # marker assignments across the two calls and trip this
            # test.
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            $script:captures = @()
            Mock Invoke-SshClientCommand {
                $script:captures += ,$Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName 'app-a' -Entries $entries
            Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                       -BlockName 'app-b' -Entries $entries

            $script:captures.Count | Should -Be 2
            $script:captures[0]    | Should -Match ([regex]::Escape("BEGIN_MARKER='# BEGIN app-a'"))
            $script:captures[1]    | Should -Match ([regex]::Escape("BEGIN_MARKER='# BEGIN app-b'"))
            $script:captures[0]    | Should -Not -Match ([regex]::Escape("# BEGIN app-b"))
            $script:captures[1]    | Should -Not -Match ([regex]::Escape("# BEGIN app-a"))
        }

        It "rejects a -BlockName containing a single-quote before any SSH call" {
            # Guards direct callers (tests, ad-hoc scripts) that bypass
            # the JSON-side validator: a ' would break out of the
            # single-quoted bash marker assignment.
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            { Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                         -BlockName "bad'name" `
                                         -Entries $entries } |
                Should -Throw -ExpectedMessage "*disallowed character*"

            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }

        It "rejects an empty -BlockName before any SSH call" {
            $entries = @([PSCustomObject]@{ name = 'FOO'; value = 'bar' })

            # PowerShell's parameter binder catches [string] '' on a
            # Mandatory parameter at bind time; the explicit host-side
            # IsNullOrEmpty check is a belt-and-braces guard in case a
            # future signature loses the Mandatory attribute.
            { Set-VmEnvironmentVariables -SshClient $script:FakeSshClient `
                                         -BlockName '' `
                                         -Entries $entries } |
                Should -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -Exactly
        }
    }
}
