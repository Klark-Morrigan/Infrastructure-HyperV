# Integration tests for Copy-VmFilesByPattern against a real SSH target.
# See Initialize-DockerTargetEnvironment.ps1 for environment details.
#
# Each It block lays down its own host-side source tree under
# $Script:HostSourceRoot and its own VM target dir under /tmp, then asserts
# the file set, contents, ownership and mode that landed on the VM. The
# unit tests already cover validation rejection paths against mocks, so
# we deliberately do not retest those here (per plan.md Step 3).

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Copy-VmFilesByPattern (integration)' {

    BeforeEach {
        # Per-test directories keep scenarios independent. New-Guid avoids
        # any chance of cross-test pollution if Pester reruns within the
        # same Describe.
        $Script:CaseId      = (New-Guid).Guid
        $Script:HostCaseDir = Join-Path $Script:HostSourceRoot $Script:CaseId
        New-Item -ItemType Directory -Path $Script:HostCaseDir -Force | Out-Null

        $Script:VmTargetDir = "/tmp/copy-vmfiles-bypattern-$Script:CaseId"
        # Pre-create the target dir as deploy-user-writable so curl can
        # land files there even when Owner is not the deploy user. mkdir -p
        # inside Copy-VmFiles uses sudo, so the parent always materialises
        # regardless of this seed; we still create it explicitly to keep
        # AfterEach's rm idempotent.
        Invoke-SshQuery "sudo mkdir -p '$Script:VmTargetDir'" | Out-Null
    }

    AfterEach {
        Invoke-SshQuery "sudo rm -rf '$Script:VmTargetDir'" | Out-Null
        if (Test-Path -LiteralPath $Script:HostCaseDir) {
            Remove-Item -LiteralPath $Script:HostCaseDir -Recurse -Force
        }
    }

    It 'copies a flat directory by wildcard without recursion' {
        # Two .txt files plus a .skip file we do NOT want transferred -
        # this guards against the wildcard accidentally matching too wide.
        'alpha' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'a.txt')
        'beta'  | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'b.txt')
        'noisy' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'c.skip')

        Copy-VmFilesByPattern `
            -SshClient $Script:SshClient `
            -Server    $Script:FileServer `
            -Pattern   (Join-Path $Script:HostCaseDir '*.txt') `
            -TargetDir $Script:VmTargetDir

        $listed = Invoke-SshQuery "find '$Script:VmTargetDir' -type f -printf '%P\n' | sort"
        $listed | Should -Be "a.txt`nb.txt"

        (Invoke-SshQuery "cat '$Script:VmTargetDir/a.txt'") | Should -Be 'alpha'
        (Invoke-SshQuery "cat '$Script:VmTargetDir/b.txt'") | Should -Be 'beta'
    }

    It 'flattens a recursive wildcard across nested directories' {
        # Tree shape:
        #   <case>/top.txt
        #   <case>/sub1/mid.txt
        #   <case>/sub1/sub2/deep.txt
        New-Item -ItemType Directory -Path (Join-Path $Script:HostCaseDir 'sub1/sub2') -Force | Out-Null
        'top'  | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'top.txt')
        'mid'  | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'sub1/mid.txt')
        'deep' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'sub1/sub2/deep.txt')

        Copy-VmFilesByPattern `
            -SshClient $Script:SshClient `
            -Server    $Script:FileServer `
            -Pattern   (Join-Path $Script:HostCaseDir '*.txt') `
            -TargetDir $Script:VmTargetDir `
            -Recurse

        $listed = Invoke-SshQuery "find '$Script:VmTargetDir' -type f -printf '%P\n' | sort"
        $listed | Should -Be "deep.txt`nmid.txt`ntop.txt"
    }

    It 'mirrors the host subtree under -PreserveRelativePath' {
        New-Item -ItemType Directory -Path (Join-Path $Script:HostCaseDir 'a/b') -Force | Out-Null
        'root-content' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'r.txt')
        'leaf-content' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'a/b/leaf.txt')

        Copy-VmFilesByPattern `
            -SshClient $Script:SshClient `
            -Server    $Script:FileServer `
            -Pattern   (Join-Path $Script:HostCaseDir '*.txt') `
            -TargetDir $Script:VmTargetDir `
            -Recurse `
            -PreserveRelativePath

        # Path mirroring is the key property here - both depths must be
        # preserved exactly under TargetDir, not flattened.
        $listed = Invoke-SshQuery "find '$Script:VmTargetDir' -type f -printf '%P\n' | sort"
        $listed | Should -Be "a/b/leaf.txt`nr.txt"

        (Invoke-SshQuery "cat '$Script:VmTargetDir/r.txt'")        | Should -Be 'root-content'
        (Invoke-SshQuery "cat '$Script:VmTargetDir/a/b/leaf.txt'") | Should -Be 'leaf-content'
    }

    It 'propagates explicit Owner and Mode to every entry' {
        New-Item -ItemType Directory -Path (Join-Path $Script:HostCaseDir 'sub') -Force | Out-Null
        'one' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'one.txt')
        'two' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'sub/two.txt')

        $expectedOwner = "$Script:RunnerUser`:$Script:RunnerUser"
        $expectedMode  = '0640'

        Copy-VmFilesByPattern `
            -SshClient $Script:SshClient `
            -Server    $Script:FileServer `
            -Pattern   (Join-Path $Script:HostCaseDir '*.txt') `
            -TargetDir $Script:VmTargetDir `
            -Recurse `
            -Owner     $expectedOwner `
            -Mode      $expectedMode

        # %m is the octal mode (%a is atime in find -printf); %u:%g are the
        # symbolic user/group names (%U:%G are numeric ids). Sorting by name
        # keeps the assertion stable regardless of find's traversal order.
        # Recurse without PreserveRelativePath flattens 'sub/two.txt' to
        # 'two.txt' under TargetDir, hence the basenames-only expectation.
        $stat = Invoke-SshQuery (
            "find '$Script:VmTargetDir' -type f -printf '%P %m %u:%g\n' | sort")

        $expected = @(
            "one.txt 640 $expectedOwner",
            "two.txt 640 $expectedOwner"
        ) -join "`n"

        $stat | Should -Be $expected
    }

    It 'skips directories matched by the pattern and copies only files' {
        # A '*' pattern matches both files and directories at the top
        # level. Resolve-VmFileEntries drops directories at the source
        # via Get-ChildItem -File; this scenario proves nothing leaks out
        # of that filter into the transport step.
        New-Item -ItemType Directory -Path (Join-Path $Script:HostCaseDir 'plain-dir') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Script:HostCaseDir 'another-dir') -Force | Out-Null
        'keep' | Set-Content -LiteralPath (Join-Path $Script:HostCaseDir 'keep.txt')

        Copy-VmFilesByPattern `
            -SshClient $Script:SshClient `
            -Server    $Script:FileServer `
            -Pattern   (Join-Path $Script:HostCaseDir '*') `
            -TargetDir $Script:VmTargetDir

        # Only keep.txt should exist on the VM. Directories should not
        # have been created as empty entries under TargetDir.
        $files = Invoke-SshQuery "find '$Script:VmTargetDir' -type f -printf '%P\n' | sort"
        $files | Should -Be 'keep.txt'

        $dirs  = Invoke-SshQuery (
            "find '$Script:VmTargetDir' -mindepth 1 -type d -printf '%P\n' | sort")
        $dirs | Should -Be ''
    }
}
