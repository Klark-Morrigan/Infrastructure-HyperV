BeforeAll {
    # Stub the two collaborators before dot-sourcing the cmdlet so command
    # resolution succeeds without loading the whole module. Individual
    # tests re-mock as needed.
    function Invoke-SshClientCommand { param($SshClient, $Command) }
    function Add-VmFileServerFile { param($Server, $LocalPath) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\FileServer\Expand-VmTarball.ps1"

    $script:FakeSshClient = [PSCustomObject]@{
        ConnectionInfo = [PSCustomObject]@{ Host = '10.10.0.50' }
    }
    $script:FakeServer = [PSCustomObject]@{
        BaseUrl    = 'http://10.10.0.1:8745'
        StagingDir = 'C:\fake-staging'
    }

    # A real host file so Test-Path inside the cmdlet succeeds. The
    # bytes do not matter - Add-VmFileServerFile is mocked away.
    $script:FakeTarball = Join-Path ([System.IO.Path]::GetTempPath()) `
        "expand-vmtarball-tests-$([guid]::NewGuid()).tar.gz"
    'fixture' | Set-Content -LiteralPath $script:FakeTarball -NoNewline
}

AfterAll {
    if (Test-Path -LiteralPath $script:FakeTarball) {
        Remove-Item -LiteralPath $script:FakeTarball -Force
    }
}

Describe 'Expand-VmTarball' {

    BeforeEach {
        Mock Add-VmFileServerFile {
            "http://10.10.0.1:8745/$(Split-Path $LocalPath -Leaf)"
        }
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    Context 'happy path' {

        It 'emits set -euo pipefail at the top of the script' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match '(?m)^set -euo pipefail\b'
            }
        }

        It 'creates a sibling tempdir under the destination parent via mktemp -d' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            # The mktemp template must point at <dirname(destination)>
            # so the final mv is a single-filesystem rename. The leading
            # dot is the .expand.* sibling convention.
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo mktemp -d "\$parent/\.expand\.XXXXXX"'
            }
        }

        It 'pipes curl into sudo tar -xzf - with --strip-components' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' `
                -StripComponents 1

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'curl -fsSL "\$url" \| sudo tar -xzf - -C "\$tmpdir" --strip-components="\$strip"'
            }
        }

        It 'removes any existing destination before the rename' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'if \[ -e "\$destination" \] \|\| \[ -L "\$destination" \]; then[\s\S]*sudo rm -rf -- "\$destination"'
            }
        }

        It 'finishes with sudo mv from tmpdir to destination' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo mv "\$tmpdir" "\$destination"'
            }
        }

        It 'widens tmpdir to 0755 BEFORE the rename so the install dir is traversable for non-root' {
            # mktemp -d defaults to 0700, which would carry over to the
            # install dir and lock out non-root processes (/usr/local/bin/
            # symlinks unreachable, JDK java binary not runnable). The
            # chmod 0755 must run after the extract but before the mv so
            # the swap is atomic with the wider mode.
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                # 0755 chmod present AND ordered after the curl|tar pipe
                # AND before the mv.
                $cmd = $Command
                $cmd -match 'sudo chmod 0755 "\$tmpdir"' -and
                $cmd.IndexOf('sudo chmod 0755') -gt
                    $cmd.IndexOf('sudo tar -xzf') -and
                $cmd.IndexOf('sudo chmod 0755') -lt
                    $cmd.IndexOf('sudo mv "$tmpdir"')
            }
        }

        It 'embeds Destination as a single-quoted bash assignment' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "destination='/opt/jdk-21'"
            }
        }

        It 'stages the tarball via Add-VmFileServerFile and forwards its URL' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            $expectedName = Split-Path $script:FakeTarball -Leaf
            Should -Invoke Add-VmFileServerFile -Times 1 -ParameterFilter {
                $LocalPath -eq $script:FakeTarball -and $Server -eq $script:FakeServer
            }
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "url='http://10\.10\.0\.1:8745/$([regex]::Escape($expectedName))'"
            }
        }
    }

    Context 'StripComponents parameter' {

        # The plan calls out 0, 1, 2 as the values that must flow through
        # verbatim. Default is 0 - asserted by omitting the parameter.
        It 'defaults to 0 when not specified' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "strip='0'"
            }
        }

        It 'flows -StripComponents <value> through verbatim' -TestCases @(
            @{ value = 0 }
            @{ value = 1 }
            @{ value = 2 }
        ) {
            param($value)
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' `
                -StripComponents $value

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "strip='$value'"
            }
        }
    }

    Context 'host-side validation: malformed Destination' {

        It 'throws before SSH on an empty Destination' {
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '' } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
            Should -Not -Invoke Add-VmFileServerFile
        }

        It 'throws before SSH on a relative Destination' {
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination 'opt/jdk-21' } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
            Should -Not -Invoke Add-VmFileServerFile
        }

        It 'throws before SSH on a Destination containing ..' {
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/../etc' } |
                Should -Throw -ExpectedMessage '*..*'
            Should -Not -Invoke Invoke-SshClientCommand
            Should -Not -Invoke Add-VmFileServerFile
        }

        It 'throws before SSH on a Destination containing NUL' {
            $bad = '/opt/jdk' + [char]0 + '-21'
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination $bad } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
            Should -Not -Invoke Add-VmFileServerFile
        }

        It 'throws before SSH on a Destination containing a single quote' {
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination "/opt/jdk'21" } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
            Should -Not -Invoke Add-VmFileServerFile
        }

        It 'throws before SSH on a negative -StripComponents' {
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' `
                -StripComponents -1 } | Should -Throw
            Should -Not -Invoke Invoke-SshClientCommand
            Should -Not -Invoke Add-VmFileServerFile
        }
    }

    Context 'host-side validation: TarballPath' {

        It 'throws before Add-VmFileServerFile when TarballPath is missing' {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) `
                "no-such-file-$([guid]::NewGuid()).tar.gz"
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $missing `
                -Destination '/opt/jdk-21' } | Should -Throw
            Should -Not -Invoke Add-VmFileServerFile
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'collaborator failure surfaces' {

        # If staging fails the SSH call must not be attempted - the URL
        # would be missing and the remote script would be malformed.
        It 'surfaces an Add-VmFileServerFile failure without calling SSH' {
            Mock Add-VmFileServerFile { throw 'staging failed' }

            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' } |
                Should -Throw -ExpectedMessage '*staging failed*'
            Should -Not -Invoke Invoke-SshClientCommand
        }
    }

    Context 'remote error handling' {

        It 'returns silently on ExitStatus 0' {
            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' } | Should -Not -Throw
        }

        It 'throws with stderr on non-zero ExitStatus' {
            Mock Invoke-SshClientCommand {
                [PSCustomObject]@{
                    ExitStatus = 2
                    Output     = ''
                    Error      = 'tar: invalid argument'
                }
            }

            { Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' } |
                Should -Throw -ExpectedMessage '*tar: invalid argument*'
        }
    }

    Context 'skip-unchanged marker (default)' {

        # The marker pre-check is the headline behaviour of this step.
        # Asserted via emitted-script inspection because the actual
        # short-circuit happens VM-side - the mocked SSH call cannot
        # observe whether bash chose the early-exit branch.

        It 'embeds the host-computed SHA-256 of the tarball bytes' {
            $expected = (Get-FileHash -LiteralPath $script:FakeTarball `
                -Algorithm SHA256).Hash.ToLowerInvariant()

            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "desired_digest='$expected'"
            }
        }

        It 'emits the marker pre-check that exits 0 on a digest match' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            # The check reads the marker through `sudo cat ... || true`
            # so a missing-or-unreadable file becomes an empty string;
            # the -n guard then short-circuits before the equality test
            # so an empty marker never spuriously matches an empty
            # desired_digest. See the cmdlet's skip-block comment.
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'marker="\$destination/\.infra-hyperv-tarball\.sha256"' -and
                $Command -match 'existing_digest="\$\(sudo cat "\$marker" 2>/dev/null \|\| true\)"' -and
                $Command -match 'if \[ -n "\$existing_digest" \] && \[ "\$existing_digest" = "\$desired_digest" \]; then[\s\S]*exit 0'
            }
        }

        It 'writes the marker file inside the tempdir before the rename' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            $script:captured |
                Should -Match 'printf ''%s\\n'' "\$desired_digest" \| sudo tee "\$tmpdir/\$marker_name" >/dev/null'

            # Ordering: marker write must precede the final mv so the
            # dir-swap lands the marker alongside the tree.
            $markerIdx = $script:captured.IndexOf('sudo tee "$tmpdir/$marker_name"')
            $mvIdx     = $script:captured.IndexOf('sudo mv "$tmpdir" "$destination"')
            $markerIdx | Should -BeGreaterThan 0
            $mvIdx     | Should -BeGreaterThan $markerIdx
        }

        It 'computes the SHA-256 once per call' {
            Mock Get-FileHash -MockWith {
                [PSCustomObject]@{ Hash = 'ABCDEF0123456789' }
            }

            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Get-FileHash -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq $script:FakeTarball -and $Algorithm -eq 'SHA256'
            }
        }

        It 'lower-cases the host-computed digest' {
            Mock Get-FileHash -MockWith {
                [PSCustomObject]@{ Hash = 'ABCDEF0123456789' }
            }

            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match "desired_digest='abcdef0123456789'"
            }
        }
    }

    Context '-NoSkipUnchanged' {

        It 'omits the marker pre-check from the emitted script' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' `
                -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -notmatch 'existing_digest="\$\(sudo cat "\$marker"'
            }
        }

        It 'still writes the marker file inside the tempdir' {
            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21' `
                -NoSkipUnchanged

            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -match 'sudo tee "\$tmpdir/\$marker_name"'
            }
        }
    }

    Context 'line-ending normalisation' {

        It 'emits no CR bytes in the command' {
            $script:captured = $null
            Mock Invoke-SshClientCommand {
                $script:captured = $Command
                [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
            }

            Expand-VmTarball -SshClient $script:FakeSshClient `
                -Server $script:FakeServer `
                -TarballPath $script:FakeTarball `
                -Destination '/opt/jdk-21'

            $script:captured | Should -Not -Match "`r"
        }
    }
}
