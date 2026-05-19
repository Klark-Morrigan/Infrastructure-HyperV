BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\FileServer\Add-VmFileServerFile.ps1"

    # Create a real temp staging directory so Copy-Item can operate normally.
    $script:stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "AddVmFileServerFile-Tests-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:stagingDir -Force | Out-Null

    $script:fakeServer = [PSCustomObject]@{
        BaseUrl    = 'http://10.10.0.1:8745'
        StagingDir = $script:stagingDir
    }

    # A real source file so size checks work.
    $script:sourceDir = Join-Path ([System.IO.Path]::GetTempPath()) "AddVmFileServerFile-Source-$(New-Guid)"
    New-Item -ItemType Directory -Path $script:sourceDir -Force | Out-Null

    $script:sourceFile = Join-Path $script:sourceDir 'tarball.tar.gz'
    [System.IO.File]::WriteAllBytes($script:sourceFile, [byte[]](1..16))
}

AfterAll {
    Remove-Item -Recurse -Force -LiteralPath $script:stagingDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $script:sourceDir  -ErrorAction SilentlyContinue
}

Describe 'Add-VmFileServerFile' {

    BeforeEach {
        # Start each test with a clean staging directory.
        Remove-Item -Path "$script:stagingDir\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies the file to Server.StagingDir when not already staged' {
        Add-VmFileServerFile -Server $script:fakeServer -LocalPath $script:sourceFile | Out-Null

        $staged = Join-Path $script:stagingDir 'tarball.tar.gz'
        $staged | Should -Exist
    }

    It 'returns the correct download URL' {
        $url = Add-VmFileServerFile -Server $script:fakeServer -LocalPath $script:sourceFile
        $url | Should -Be 'http://10.10.0.1:8745/tarball.tar.gz'
    }

    It 'skips the copy when an identical file is already staged' {
        # Stage once.
        Add-VmFileServerFile -Server $script:fakeServer -LocalPath $script:sourceFile | Out-Null

        $staged    = Join-Path $script:stagingDir 'tarball.tar.gz'
        $timeBefore = (Get-Item -LiteralPath $staged).LastWriteTimeUtc

        # A small sleep so LastWriteTime would differ if the file were overwritten.
        Start-Sleep -Milliseconds 50

        Add-VmFileServerFile -Server $script:fakeServer -LocalPath $script:sourceFile | Out-Null

        $timeAfter = (Get-Item -LiteralPath $staged).LastWriteTimeUtc
        $timeAfter | Should -Be $timeBefore
    }

    It 'throws when LocalPath does not exist' {
        {
            Add-VmFileServerFile -Server $script:fakeServer -LocalPath 'C:\does-not-exist.tar.gz'
        } | Should -Throw '*File not found*'
    }
}
