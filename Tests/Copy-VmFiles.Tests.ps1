BeforeAll {
    # Stub the module's other public functions that Copy-VmFiles calls
    # (Add-VmFileServerFile, Invoke-SshClientCommand) before dot-sourcing
    # so command resolution succeeds without loading the whole module.
    function Add-VmFileServerFile    { param($Server, $LocalPath) }
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Copy-VmFiles.ps1"

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
}
