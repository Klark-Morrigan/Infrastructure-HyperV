BeforeAll {
    # Dot-source the private helper directly. The function is SSH-free and
    # depends on no other module functions, so no stubs are required.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\FileTransfer\Resolve-VmFileEntries.ps1"

    function New-TestFile {
        param([string] $Path)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -Path $Path -Value 'x' -NoNewline
    }
}

Describe 'Resolve-VmFileEntries' {

    Context 'flatten mode (default), non-recursive' {

        It 'returns one entry per matched file with the basename appended to TargetDir' {
            $root = Join-Path $TestDrive 'flat'
            New-TestFile (Join-Path $root 'a.json')
            New-TestFile (Join-Path $root 'b.json')
            New-TestFile (Join-Path $root 'c.txt')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.json') `
                -TargetDir '/opt/data'

            $entries.Count | Should -Be 2
            $targets = @($entries | ForEach-Object Target)
            $targets | Should -Contain '/opt/data/a.json'
            $targets | Should -Contain '/opt/data/b.json'
        }

        It 'omits directories from the matched set' {
            # Guards the file-vs-directory filter the resolver applies up
            # front so directory entries never reach Copy-VmFiles.
            $root = Join-Path $TestDrive 'with-dirs'
            New-TestFile (Join-Path $root 'a.json')
            New-Item -ItemType Directory -Path (Join-Path $root 'sub') `
                     -Force | Out-Null

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*') `
                -TargetDir '/opt'

            $entries.Count    | Should -Be 1
            $entries[0].Target | Should -Be '/opt/a.json'
        }

        It 'tolerates a trailing slash on TargetDir' {
            $root = Join-Path $TestDrive 'trailing'
            New-TestFile (Join-Path $root 'a.bin')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.bin') `
                -TargetDir '/opt/data/'

            $entries[0].Target | Should -Be '/opt/data/a.bin'
        }
    }

    Context 'flatten mode, recursive' {

        It 'flattens basenames from nested directories under one TargetDir' {
            $root = Join-Path $TestDrive 'tree-flat'
            New-TestFile (Join-Path $root 'top.json')
            New-TestFile (Join-Path $root 'sub\inner.json')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.json') `
                -TargetDir '/opt/data' `
                -Recurse

            $entries.Count | Should -Be 2
            $targets = @($entries | ForEach-Object Target)
            $targets | Should -Contain '/opt/data/top.json'
            $targets | Should -Contain '/opt/data/inner.json'
        }
    }

    Context 'preserve-relative-path mode' {

        It 'mirrors the host subtree under TargetDir using forward slashes' {
            $root = Join-Path $TestDrive 'tree-mirror'
            New-TestFile (Join-Path $root 'top.json')
            New-TestFile (Join-Path $root 'sub\inner.json')
            New-TestFile (Join-Path $root 'sub\deep\leaf.json')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.json') `
                -TargetDir '/opt/data' `
                -Recurse -PreserveRelativePath

            $entries.Count | Should -Be 3
            $targets = @($entries | ForEach-Object Target)
            $targets | Should -Contain '/opt/data/top.json'
            $targets | Should -Contain '/opt/data/sub/inner.json'
            $targets | Should -Contain '/opt/data/sub/deep/leaf.json'
        }
    }

    Context 'Owner / Mode propagation' {

        It 'applies defaults root:root and 0644 when not specified' {
            $root = Join-Path $TestDrive 'defaults'
            New-TestFile (Join-Path $root 'a.bin')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.bin') `
                -TargetDir '/opt'

            $entries[0].Owner | Should -Be 'root:root'
            $entries[0].Mode  | Should -Be '0644'
        }

        It 'propagates explicit Owner / Mode uniformly to every entry' {
            $root = Join-Path $TestDrive 'explicit'
            New-TestFile (Join-Path $root 'a.bin')
            New-TestFile (Join-Path $root 'b.bin')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.bin') `
                -TargetDir '/opt' `
                -Owner     'app:app' `
                -Mode      '0640'

            $uniqueOwners = @($entries | ForEach-Object Owner | Sort-Object -Unique)
            $uniqueModes  = @($entries | ForEach-Object Mode  | Sort-Object -Unique)
            $uniqueOwners | Should -Be 'app:app'
            $uniqueModes  | Should -Be '0640'
        }
    }

    Context 'validation failures (throw before returning entries)' {

        It 'throws when the pattern matches no files' {
            $root = Join-Path $TestDrive 'empty'
            New-Item -ItemType Directory -Path $root -Force | Out-Null

            { Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.json') `
                -TargetDir '/opt' } |
                Should -Throw -ExpectedMessage '*no files matched*'
        }

        It 'throws when the pattern matches only directories' {
            # The -File filter drops directory matches; with nothing left
            # the zero-files guard fires, as documented in problem.md.
            $root = Join-Path $TestDrive 'only-dirs'
            New-Item -ItemType Directory -Path (Join-Path $root 'a') `
                     -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'b') `
                     -Force | Out-Null

            { Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*') `
                -TargetDir '/opt' } |
                Should -Throw -ExpectedMessage '*no files matched*'
        }

        It 'throws on flatten basename collision across subdirectories' {
            $root = Join-Path $TestDrive 'collide-flat'
            New-TestFile (Join-Path $root 'one\dup.json')
            New-TestFile (Join-Path $root 'two\dup.json')

            { Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.json') `
                -TargetDir '/opt' `
                -Recurse } |
                Should -Throw -ExpectedMessage '*duplicate*'
        }
    }

    Context 'cross-platform path safety' {

        It 'returns Target paths using forward slashes only' {
            # The VM runs Linux. Backslashes leaking into Target would
            # break the downstream sudo mkdir / curl commands.
            $root = Join-Path $TestDrive 'slashes'
            New-TestFile (Join-Path $root 'sub\file.bin')

            $entries = Resolve-VmFileEntries `
                -Pattern   (Join-Path $root '*.bin') `
                -TargetDir '/opt/x' `
                -Recurse -PreserveRelativePath

            foreach ($entry in $entries) {
                $entry.Target | Should -Not -Match '\\'
                $entry.Target | Should -Match '^/'
            }
        }
    }
}
