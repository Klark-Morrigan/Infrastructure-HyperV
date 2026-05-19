BeforeAll {
    # Stub the two collaborators before dot-sourcing the wrapper so command
    # resolution succeeds without loading the whole module. Mirrors the
    # pattern in Copy-VmFiles.Tests.ps1.
    function Resolve-VmFileEntries {
        param(
            $Pattern, $TargetDir,
            [switch] $Recurse, [switch] $PreserveRelativePath,
            $Owner, $Mode
        )
    }
    function Copy-VmFiles { param($SshClient, $Server, $Entries) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\FileTransfer\Copy-VmFilesByPattern.ps1"

    $script:FakeSshClient = [PSCustomObject]@{ Tag = 'ssh' }
    $script:FakeServer    = [PSCustomObject]@{ BaseUrl = 'http://192.168.1.1:8745' }
    $script:FakeEntries   = @(
        [PSCustomObject]@{ Source = 'C:\src\a'; Target = '/opt/a'; Owner = 'root:root'; Mode = '0644' },
        [PSCustomObject]@{ Source = 'C:\src\b'; Target = '/opt/b'; Owner = 'root:root'; Mode = '0644' }
    )
}

Describe 'Copy-VmFilesByPattern' {

    BeforeEach {
        Mock Resolve-VmFileEntries { $script:FakeEntries }
        Mock Copy-VmFiles { }
    }

    It 'forwards resolver entries verbatim to Copy-VmFiles together with SshClient and Server' {
        Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                              -Server    $script:FakeServer `
                              -Pattern   'C:\src\*.bin' `
                              -TargetDir '/opt/lib'

        Should -Invoke Copy-VmFiles -Times 1 -Exactly -ParameterFilter {
            $SshClient -eq $script:FakeSshClient -and
            $Server    -eq $script:FakeServer    -and
            $Entries.Count -eq $script:FakeEntries.Count -and
            $Entries[0].Target -eq '/opt/a' -and
            $Entries[1].Target -eq '/opt/b'
        }
    }

    It 'forwards Pattern and TargetDir to the resolver' {
        Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                              -Server    $script:FakeServer `
                              -Pattern   'C:\src\*.bin' `
                              -TargetDir '/opt/lib'

        Should -Invoke Resolve-VmFileEntries -Times 1 -Exactly -ParameterFilter {
            $Pattern -eq 'C:\src\*.bin' -and $TargetDir -eq '/opt/lib'
        }
    }

    It 'forwards -Recurse and -PreserveRelativePath to the resolver' {
        Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                              -Server    $script:FakeServer `
                              -Pattern   'C:\src\*.bin' `
                              -TargetDir '/opt/lib' `
                              -Recurse `
                              -PreserveRelativePath

        Should -Invoke Resolve-VmFileEntries -Times 1 -Exactly -ParameterFilter {
            $Recurse.IsPresent -and $PreserveRelativePath.IsPresent
        }
    }

    It 'forwards explicit Owner and Mode to the resolver' {
        Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                              -Server    $script:FakeServer `
                              -Pattern   'C:\src\*.bin' `
                              -TargetDir '/opt/lib' `
                              -Owner     'appuser:appgroup' `
                              -Mode      '0640'

        Should -Invoke Resolve-VmFileEntries -Times 1 -Exactly -ParameterFilter {
            $Owner -eq 'appuser:appgroup' -and $Mode -eq '0640'
        }
    }

    It 'does not pass Owner or Mode to the resolver when the caller omits them' {
        # Letting the resolver own its defaults keeps Copy-VmFilesByPattern
        # from drifting if those defaults change. The wrapper is a forwarder,
        # not a second source of truth.
        Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                              -Server    $script:FakeServer `
                              -Pattern   'C:\src\*.bin' `
                              -TargetDir '/opt/lib'

        Should -Invoke Resolve-VmFileEntries -Times 1 -Exactly -ParameterFilter {
            -not $PSBoundParameters.ContainsKey('Owner') -and
            -not $PSBoundParameters.ContainsKey('Mode')
        }
    }

    It 'does not pass the switches when the caller omits them' {
        Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                              -Server    $script:FakeServer `
                              -Pattern   'C:\src\*.bin' `
                              -TargetDir '/opt/lib'

        Should -Invoke Resolve-VmFileEntries -Times 1 -Exactly -ParameterFilter {
            -not $Recurse.IsPresent -and -not $PreserveRelativePath.IsPresent
        }
    }

    It 'propagates a resolver throw without invoking Copy-VmFiles (no transport on rejection)' {
        # Key contract: validation failures must not touch SSH or the
        # file server. Asserting -Times 0 on Copy-VmFiles is what makes
        # the test meaningful.
        Mock Resolve-VmFileEntries { throw 'no files matched pattern' }

        { Copy-VmFilesByPattern -SshClient $script:FakeSshClient `
                                -Server    $script:FakeServer `
                                -Pattern   'C:\nope\*' `
                                -TargetDir '/opt/lib' } |
            Should -Throw -ExpectedMessage '*no files matched pattern*'

        Should -Invoke Copy-VmFiles -Times 0 -Exactly
    }
}
