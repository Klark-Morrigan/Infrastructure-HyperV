BeforeAll {
    # Stub the module's other public functions that Copy-VmFiles calls
    # (Add-VmFileServerFile, Invoke-SshClientCommand) before dot-sourcing
    # so command resolution succeeds without loading the whole module.
    # Get-FileHash is shadowed too so Mock can intercept it without the
    # tests needing real files on disk for every made-up source path.
    function Add-VmFileServerFile    { param($Server, $LocalPath) }
    function Invoke-SshClientCommand { param($SshClient, $Command) }
    function Get-FileHash            { param($Path, $Algorithm) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\FileTransfer\Copy-VmFiles.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:FakeServer    = [PSCustomObject]@{ BaseUrl = 'http://192.168.1.1:8745' }
}

Describe 'Copy-VmFiles' {

    BeforeEach {
        Mock Add-VmFileServerFile {
            "$($Server.BaseUrl)/$(Split-Path -Leaf $LocalPath)"
        }
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
        # Per-path deterministic SHA-256 stub: the function lowercases the
        # hash before embedding it, so tests assert on the lowercase form.
        # Encoding the leaf in the hash gives two distinct entries two
        # distinct hashes, which the per-entry-SHA test relies on.
        Mock Get-FileHash {
            $leaf = Split-Path -Leaf $Path
            $hex  = ([System.BitConverter]::ToString(
                        [System.Text.Encoding]::UTF8.GetBytes($leaf)) -replace '-','')
            [PSCustomObject]@{ Hash = ($hex + ('0' * 64)).Substring(0, 64) }
        }
    }

    It 'stages each entry once via the file server' {
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/lib/a.bin' },
            [PSCustomObject]@{ Source = 'C:\src\b.bin'; Target = '/opt/lib/b.bin' }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Add-VmFileServerFile -Times 2 -Exactly
    }

    It 'issues one SSH command per entry' {
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a'; Target = '/opt/a' },
            [PSCustomObject]@{ Source = 'C:\src\b'; Target = '/opt/b' }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Invoke-SshClientCommand -Times 2 -Exactly
    }

    It 'runs mkdir -p + curl + chown + chmod (all under sudo)' {
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/lib/sub/a.bin' }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'sudo mkdir -p' -and
            $Command -match 'sudo curl'    -and
            $Command -match 'sudo chown'   -and
            $Command -match 'sudo chmod'
        }
    }

    It 'defaults Owner to root:root and Mode to 0644 when entry omits them' {
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a'; Target = '/opt/a' }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match "owner='root:root'" -and
            $Command -match "mode='0644'"
        }
    }

    It 'honours an explicit Owner and Mode on the entry' {
        $entries = @(
            [PSCustomObject]@{
                Source = 'C:\src\a'
                Target = '/opt/a'
                Owner  = 'appuser:appgroup'
                Mode   = '0640'
            }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match "owner='appuser:appgroup'" -and
            $Command -match "mode='0640'"
        }
    }

    It 'references the staged URL in the curl command' {
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match [regex]::Escape('http://192.168.1.1:8745/a.bin') -and
            $Command -match [regex]::Escape('/opt/a.bin')
        }
    }

    It 'sends LF-only line endings (no CR) so remote bash does not see \r tokens' {
        # PowerShell here-strings on Windows produce CRLF. Sending those
        # straight to bash makes 'set -e\r' an invalid option, 'root:root\r'
        # an invalid group, etc. The function must normalise to LF.
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a'; Target = '/opt/a' }
        )

        Copy-VmFiles -SshClient $script:FakeSshClient `
                     -Server    $script:FakeServer `
                     -Entries   $entries

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -notmatch "`r" -and $Command -match "`n"
        }
    }

    It 'accepts a hashtable entry just like a PSCustomObject' {
        # Hashtables expose properties via .PSObject.Properties so the
        # code path is the same - this test guards against an accidental
        # regression that requires PSCustomObject specifically.
        $entries = @(
            @{ Source = 'C:\src\a'; Target = '/opt/a' }
        )

        { Copy-VmFiles -SshClient $script:FakeSshClient `
                       -Server    $script:FakeServer `
                       -Entries   $entries } |
            Should -Not -Throw
    }

    It 'throws naming both source and target when an SSH command exits non-zero' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 22; Output = ''; Error = 'curl: (22)' }
        }
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
        )

        { Copy-VmFiles -SshClient $script:FakeSshClient `
                       -Server    $script:FakeServer `
                       -Entries   $entries } |
            Should -Throw -ExpectedMessage '*source: C:\src\a.bin*target: /opt/a.bin*'
    }

    It 'aborts on first failure and does not attempt subsequent entries' {
        # Mirrors "set -e" semantics so the operator gets a clear single
        # failure to fix, not a cascade of follow-up errors.
        $script:_calls = 0
        Mock Invoke-SshClientCommand {
            $script:_calls++
            [PSCustomObject]@{ ExitStatus = 1; Output = ''; Error = '' }
        }
        $entries = @(
            [PSCustomObject]@{ Source = 'C:\src\a'; Target = '/opt/a' },
            [PSCustomObject]@{ Source = 'C:\src\b'; Target = '/opt/b' }
        )

        { Copy-VmFiles -SshClient $script:FakeSshClient `
                       -Server    $script:FakeServer `
                       -Entries   $entries } | Should -Throw

        $script:_calls | Should -Be 1
    }

    Context 'skip-unchanged (default)' {

        It 'emits a reconcile block (sha256sum + stat + early exit 0) ahead of the curl' {
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/lib/a.bin' }
            )

            Copy-VmFiles -SshClient $script:FakeSshClient `
                         -Server    $script:FakeServer `
                         -Entries   $entries

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                # Reconcile primitives are all present
                $Command -match 'sudo sha256sum' -and
                $Command -match "sudo stat -c '%U:%G %a'" -and
                $Command -match 'exit 0' -and
                # And the exit 0 sits BEFORE the curl line, otherwise the
                # short-circuit would never fire.
                $Command.IndexOf('exit 0') -lt $Command.IndexOf('sudo curl')
            }
        }

        It 'embeds the host-computed SHA-256 as a literal in the script' {
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
            )

            # Matches the BeforeEach Get-FileHash stub: 'a.bin' UTF-8 bytes
            # 61 2E 62 69 6E -> '612E62696E', then padded with zeros and
            # lowercased by Copy-VmFiles.
            $expectedHashPrefix = '612e62696e'

            Copy-VmFiles -SshClient $script:FakeSshClient `
                         -Server    $script:FakeServer `
                         -Entries   $entries

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "expected_hash='$expectedHashPrefix"
            }
        }

        It 'embeds a per-entry SHA so two sources get two different hash literals' {
            # Catches a caching bug where a loop reused the previous entry's
            # hash. The stub returns a leaf-derived hash so distinct sources
            # produce distinct hex prefixes (a.bin -> 612e..., b.bin -> 622e...).
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' },
                [PSCustomObject]@{ Source = 'C:\src\b.bin'; Target = '/opt/b.bin' }
            )

            $script:capturedCommands = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-SshClientCommand {
                $script:capturedCommands.Add($Command)
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Copy-VmFiles -SshClient $script:FakeSshClient `
                         -Server    $script:FakeServer `
                         -Entries   $entries

            $script:capturedCommands.Count | Should -Be 2
            $script:capturedCommands[0]    | Should -Match "expected_hash='612e62696e"
            $script:capturedCommands[1]    | Should -Match "expected_hash='622e62696e"
        }

        It 'still throws naming source + target when the reconcile-path script exits non-zero' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 7; Output = ''; Error = 'boom' }
            }
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
            )

            { Copy-VmFiles -SshClient $script:FakeSshClient `
                           -Server    $script:FakeServer `
                           -Entries   $entries } |
                Should -Throw -ExpectedMessage '*source: C:\src\a.bin*target: /opt/a.bin*'
        }
    }

    Context '-NoSkipUnchanged' {

        It 'omits the reconcile block - no sha256sum, no stat, no early exit' {
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
            )

            Copy-VmFiles -SshClient $script:FakeSshClient `
                         -Server    $script:FakeServer `
                         -Entries   $entries `
                         -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -notmatch 'sha256sum' -and
                $Command -notmatch 'stat -c'   -and
                $Command -notmatch 'exit 0'    -and
                $Command -notmatch 'expected_hash'
            }
        }

        It 'does not even hash the source host-side' {
            # The hash is wasted work when there is no reconcile block to
            # compare it against. Pin that the function shortcut around
            # Get-FileHash in the opt-out path.
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
            )

            Copy-VmFiles -SshClient $script:FakeSshClient `
                         -Server    $script:FakeServer `
                         -Entries   $entries `
                         -NoSkipUnchanged

            Should -Invoke Get-FileHash -Times 0 -Exactly
        }

        It 'emits the byte-for-byte pre-change script' {
            # Pinned with a string-equality check so accidental drift in
            # the always-write branch (whitespace, quoting, ordering)
            # fails loudly rather than silently changing what the VM runs.
            $entries = @(
                [PSCustomObject]@{
                    Source = 'C:\src\a.bin'
                    Target = '/opt/lib/a.bin'
                    Owner  = 'root:root'
                    Mode   = '0644'
                }
            )

            $script:capturedCommand = $null
            Mock Invoke-SshClientCommand {
                $script:capturedCommand = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Copy-VmFiles -SshClient $script:FakeSshClient `
                         -Server    $script:FakeServer `
                         -Entries   $entries `
                         -NoSkipUnchanged

            $expected = @"
set -e
target='/opt/lib/a.bin'
url='http://192.168.1.1:8745/a.bin'
owner='root:root'
mode='0644'
sudo mkdir -p "`$(dirname "`$target")"
sudo curl -fsSL -o "`$target" "`$url"
sudo chown "`$owner" "`$target"
sudo chmod "`$mode" "`$target"
"@ -replace "`r`n", "`n"

            $script:capturedCommand | Should -BeExactly $expected
        }

        It 'still throws naming source + target when the always-write script exits non-zero' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{ ExitStatus = 9; Output = ''; Error = 'nope' }
            }
            $entries = @(
                [PSCustomObject]@{ Source = 'C:\src\a.bin'; Target = '/opt/a.bin' }
            )

            { Copy-VmFiles -SshClient $script:FakeSshClient `
                           -Server    $script:FakeServer `
                           -Entries   $entries `
                           -NoSkipUnchanged } |
                Should -Throw -ExpectedMessage '*source: C:\src\a.bin*target: /opt/a.bin*'
        }
    }
}
