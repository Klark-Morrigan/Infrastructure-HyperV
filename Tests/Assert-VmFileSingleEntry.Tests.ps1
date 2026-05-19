BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\FileTransfer\Assert-VmFileSingleEntry.ps1"

    function New-Entry([string] $Json) {
        return ($Json | ConvertFrom-Json)
    }

    # Real on-disk source for happy-path tests - the helper runs
    # Test-Path so the path must actually exist. WriteAllBytes is used
    # instead of Set-Content -Encoding Byte because the Byte encoding
    # was removed from Set-Content in PowerShell 7.
    function New-ExistingSourcePath {
        $path = Join-Path $TestDrive 'src.bin'
        [System.IO.File]::WriteAllBytes($path, [byte[]](1..16))
        return ($path -replace '\\', '\\')
    }

    $script:DefaultAllow = @('source', 'target')
    $script:Ctx          = "VM 'node-01': files[0]"
}

Describe 'Assert-VmFileSingleEntry - happy path' {

    It 'accepts a minimal entry with an existing source and absolute target' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": `"/opt/x.bin`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } | Should -Not -Throw
    }

    It 'accepts an entry whose extras are in a consumer-extended allow-list' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": `"/y`", `"owner`": `"app`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields @('source','target','owner') } | Should -Not -Throw
    }
}

Describe 'Assert-VmFileSingleEntry - unknown sub-field' {

    It 'throws on a sub-field outside the default allow-list' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"src`": `"$src`", `"target`": `"/y`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'src'*"
    }

    It 'still rejects extras outside a consumer-supplied allow-list' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": `"/y`", `"hax`": `"x`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields @('source','target','owner') } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'hax'*"
    }
}

Describe 'Assert-VmFileSingleEntry - source rules' {

    It 'throws when source is missing' {
        $entry = New-Entry '{ "target": "/y" }'
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'source'*"
    }

    It 'throws when source is a JSON number instead of a string' {
        $entry = New-Entry '{ "source": 42, "target": "/y" }'
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*source must be a non-empty string*"
    }

    It 'throws when source is a whitespace-only string' {
        $entry = New-Entry '{ "source": "   ", "target": "/y" }'
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*source must be a non-empty string*"
    }

    It 'throws when source does not exist on the host' {
        $entry = New-Entry '{ "source": "C:\\does-not-exist-xyz\\f.bin", "target": "/y" }'
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*source path does not exist*"
    }
}

Describe 'Assert-VmFileSingleEntry - target rules' {

    It 'throws when target is missing' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'target'*"
    }

    It 'throws when target is a JSON number instead of a string' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": 42 }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*target must be a non-empty string*"
    }

    It 'throws when target is a whitespace-only string' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": `"   `" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*target must be a non-empty string*"
    }

    It 'throws when target is a relative path' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": `"opt/x`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*absolute Linux path*"
    }

    It 'throws when target is a Windows-style path' {
        $src = New-ExistingSourcePath
        $entry = New-Entry "{ `"source`": `"$src`", `"target`": `"C:\\opt\\x`" }"
        { Assert-VmFileSingleEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*absolute Linux path*"
    }
}

Describe 'Assert-VmFileSingleEntry - error context propagation' {

    It 'embeds the supplied EntryCtx prefix in every message' {
        # The dispatcher owns building the EntryCtx string (VM name +
        # index). The helper has only one job here: thread it into the
        # error verbatim. Pin that with a distinctive prefix.
        $entry = New-Entry '{ "target": "/y" }'
        { Assert-VmFileSingleEntry -EntryCtx "VM 'node-07': files[3]" -Entry $entry `
            -AllowedSubFields $DefaultAllow } |
            Should -Throw -ExpectedMessage "*VM 'node-07': files[[]3[]]*missing required sub-field 'source'*"
    }
}
