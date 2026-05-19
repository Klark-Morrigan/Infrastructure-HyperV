BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\FileTransfer\Assert-VmFileBulkEntry.ps1"

    function New-Entry([string] $Json) {
        return ($Json | ConvertFrom-Json)
    }

    # The bulk allow-list mirrors what the dispatcher passes in.
    # Duplicated here on purpose: the contract under test is "given
    # this allow-list, enforce these rules" - not "look up the list
    # from somewhere".
    $script:BulkAllow = @('pattern', 'targetDir', 'recurse', 'preserveRelativePath')
    $script:Ctx       = "VM 'node-01': files[0]"
}

Describe 'Assert-VmFileBulkEntry - happy path' {

    It 'accepts a minimal entry (pattern + targetDir only)' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*.txt", "targetDir": "/opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } | Should -Not -Throw
    }

    It 'accepts recurse and preserveRelativePath when both are booleans' {
        $entry = New-Entry @"
{ "pattern": "C:\\src\\**\\*", "targetDir": "/opt/x", "recurse": true, "preserveRelativePath": false }
"@
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } | Should -Not -Throw
    }

    It 'does not check pattern existence on the host' {
        # By design: globs are time-varying, and the resolver
        # re-evaluates them on every provision run. Surfacing a
        # zero-match at schema time would require globbing here too -
        # the resolver is the single source of truth for that.
        $entry = New-Entry '{ "pattern": "C:\\nope-xyz\\*", "targetDir": "/opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } | Should -Not -Throw
    }
}

Describe 'Assert-VmFileBulkEntry - unknown sub-field (typo guard)' {

    It "throws on a typo like 'recursive'" {
        # Casing-only typos (e.g. 'targetdir' vs 'targetDir') are NOT
        # caught here: -in / PSCustomObject property access in
        # PowerShell are case-insensitive, matching the single form's
        # default behaviour. The bulk allow-list catches genuine
        # spelling differences only.
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": "/opt/x", "recursive": true }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'recursive'*"
    }
}

Describe 'Assert-VmFileBulkEntry - pattern rules' {

    It 'throws when pattern is missing' {
        $entry = New-Entry '{ "targetDir": "/opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'pattern'*"
    }

    It 'throws when pattern is a JSON number instead of a string' {
        $entry = New-Entry '{ "pattern": 42, "targetDir": "/opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*pattern must be a non-empty string*"
    }

    It 'throws when pattern is a whitespace-only string' {
        $entry = New-Entry '{ "pattern": "   ", "targetDir": "/opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*pattern must be a non-empty string*"
    }
}

Describe 'Assert-VmFileBulkEntry - targetDir rules' {

    It 'throws when targetDir is missing' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'targetDir'*"
    }

    It 'throws when targetDir is a JSON number instead of a string' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": 42 }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*targetDir must be a non-empty string*"
    }

    It 'throws when targetDir is a whitespace-only string' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": "   " }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*targetDir must be a non-empty string*"
    }

    It 'throws when targetDir is a relative path' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": "opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*absolute Linux path*"
    }

    It 'throws when targetDir is a Windows-style path' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": "C:\\opt\\x" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*absolute Linux path*"
    }
}

Describe 'Assert-VmFileBulkEntry - boolean flag rules' {

    It 'throws when recurse is a string instead of a boolean' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": "/opt/x", "recurse": "yes" }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*recurse must be a boolean*"
    }

    It 'throws when preserveRelativePath is a number instead of a boolean' {
        $entry = New-Entry '{ "pattern": "C:\\src\\*", "targetDir": "/opt/x", "preserveRelativePath": 1 }'
        { Assert-VmFileBulkEntry -EntryCtx $Ctx -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*preserveRelativePath must be a boolean*"
    }
}

Describe 'Assert-VmFileBulkEntry - error context propagation' {

    It 'embeds the supplied EntryCtx prefix in every message' {
        $entry = New-Entry '{ "targetDir": "/opt/x" }'
        { Assert-VmFileBulkEntry -EntryCtx "VM 'node-07': files[5]" -Entry $entry `
            -AllowedSubFields $BulkAllow } |
            Should -Throw -ExpectedMessage "*VM 'node-07': files[[]5[]]*missing required sub-field 'pattern'*"
    }
}
