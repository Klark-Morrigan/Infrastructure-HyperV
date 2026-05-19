BeforeAll {
    # Stub the two private helpers BEFORE dot-sourcing the dispatcher
    # so command resolution succeeds without loading the real helpers
    # or the whole module. Per-form rules are covered in
    # Assert-VmFileSingleEntry.Tests.ps1 / Assert-VmFileBulkEntry.Tests.ps1;
    # this file tests orchestration only - which helper is invoked,
    # with which arguments, and which paths short-circuit before any
    # helper runs.
    function Assert-VmFileSingleEntry {
        param(
            [string]   $EntryCtx,
            [object]   $Entry,
            [string[]] $AllowedSubFields
        )
    }
    function Assert-VmFileBulkEntry {
        param(
            [string]   $EntryCtx,
            [object]   $Entry,
            [string[]] $AllowedSubFields
        )
    }

    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\FileTransfer\Assert-VmFilesField.ps1"

    function New-VmWithFilesJson([string] $FilesJson) {
        $json = if ($null -eq $FilesJson) {
            '{ "vmName": "node-01" }'
        } else {
            "{ `"vmName`": `"node-01`", `"files`": $FilesJson }"
        }
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutFiles {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }
}

Describe 'Assert-VmFilesField - top-level files array' {

    BeforeEach {
        Mock Assert-VmFileSingleEntry { }
        Mock Assert-VmFileBulkEntry   { }
    }

    Context 'absent / empty short-circuit before any helper runs' {

        It 'returns silently and invokes no helper when files is absent' {
            Assert-VmFilesField -Vm (New-VmWithoutFiles)
            Should -Invoke Assert-VmFileSingleEntry -Times 0
            Should -Invoke Assert-VmFileBulkEntry   -Times 0
        }

        It 'returns silently and invokes no helper when files is an empty array' {
            Assert-VmFilesField -Vm (New-VmWithFilesJson '[]')
            Should -Invoke Assert-VmFileSingleEntry -Times 0
            Should -Invoke Assert-VmFileBulkEntry   -Times 0
        }
    }

    Context 'array-shape rejection happens before any helper runs' {

        It 'throws when files is a JSON object instead of an array' {
            { Assert-VmFilesField -Vm (New-VmWithFilesJson '{ "source": "x", "target": "/y" }') } |
                Should -Throw -ExpectedMessage "*files must be a JSON array*"
            Should -Invoke Assert-VmFileSingleEntry -Times 0
        }

        It 'throws when files is JSON null (distinct from absent)' {
            # A literal "files": null is distinct from "files absent"
            # and must fail loudly so the operator does not assume the
            # field was silently ignored.
            { Assert-VmFilesField -Vm (New-VmWithFilesJson 'null') } |
                Should -Throw -ExpectedMessage "*files must be a JSON array*"
            Should -Invoke Assert-VmFileSingleEntry -Times 0
        }

        It 'throws when an entry is JSON null' {
            { Assert-VmFilesField -Vm (New-VmWithFilesJson '[null]') } |
                Should -Throw -ExpectedMessage "*files[[]0[]] must be a JSON object*"
            Should -Invoke Assert-VmFileSingleEntry -Times 0
        }

        It 'throws when an entry is a string' {
            { Assert-VmFilesField -Vm (New-VmWithFilesJson '["just-a-string"]') } |
                Should -Throw -ExpectedMessage "*files[[]0[]] must be a JSON object*"
            Should -Invoke Assert-VmFileSingleEntry -Times 0
        }
    }

    Context 'EntryCtx string built by the dispatcher' {

        It 'passes a per-entry index inside the EntryCtx prefix' {
            # Pins the off-by-one guard: the second entry must report
            # files[1], not files[0].
            $vm = New-VmWithFilesJson @"
[
    { "source": "x", "target": "/a" },
    { "source": "y", "target": "/b" }
]
"@
            Assert-VmFilesField -Vm $vm

            Should -Invoke Assert-VmFileSingleEntry -Times 1 -ParameterFilter {
                $EntryCtx -eq "VM 'node-01': files[0]"
            }
            Should -Invoke Assert-VmFileSingleEntry -Times 1 -ParameterFilter {
                $EntryCtx -eq "VM 'node-01': files[1]"
            }
        }

        It "uses '(unknown)' in EntryCtx when vmName is absent" {
            # Bypass New-VmWithFilesJson because it always injects vmName.
            $vm = ('{ "files": [{ "source": "x", "target": "/a" }] }' | ConvertFrom-Json)
            Assert-VmFilesField -Vm $vm

            Should -Invoke Assert-VmFileSingleEntry -Times 1 -ParameterFilter {
                $EntryCtx -like "*VM '(unknown)'*"
            }
        }
    }
}

Describe 'Assert-VmFilesField - dispatch with -AllowBulkEntries off (default)' {

    BeforeEach {
        Mock Assert-VmFileSingleEntry { }
        Mock Assert-VmFileBulkEntry   { }
    }

    It 'routes every entry to the single-form helper' {
        $vm = New-VmWithFilesJson @"
[
    { "source": "x", "target": "/a" },
    { "source": "y", "target": "/b" }
]
"@
        Assert-VmFilesField -Vm $vm

        Should -Invoke Assert-VmFileSingleEntry -Times 2 -Exactly
        Should -Invoke Assert-VmFileBulkEntry   -Times 0
    }

    It 'forwards the default AllowedSubFields when none is supplied' {
        Assert-VmFilesField -Vm (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]')

        Should -Invoke Assert-VmFileSingleEntry -Times 1 -ParameterFilter {
            ($AllowedSubFields -join ',') -eq 'source,target'
        }
    }

    It 'forwards a consumer-supplied AllowedSubFields verbatim' {
        Assert-VmFilesField `
            -Vm               (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]') `
            -AllowedSubFields @('source','target','owner')

        Should -Invoke Assert-VmFileSingleEntry -Times 1 -ParameterFilter {
            ($AllowedSubFields -join ',') -eq 'source,target,owner'
        }
    }

    It 'propagates a helper throw unchanged' {
        # The dispatcher must not wrap or swallow helper errors:
        # consumers rely on the helper's message text for diagnostics.
        Mock Assert-VmFileSingleEntry { throw 'boom-from-helper' }

        { Assert-VmFilesField -Vm (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]') } |
            Should -Throw -ExpectedMessage "*boom-from-helper*"
    }
}

Describe 'Assert-VmFilesField - dispatch with -AllowBulkEntries on' {

    BeforeEach {
        Mock Assert-VmFileSingleEntry { }
        Mock Assert-VmFileBulkEntry   { }
    }

    Context 'form discrimination by source vs pattern' {

        It "routes a 'source'-only entry to the single helper" {
            Assert-VmFilesField -AllowBulkEntries `
                -Vm (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]')

            Should -Invoke Assert-VmFileSingleEntry -Times 1
            Should -Invoke Assert-VmFileBulkEntry   -Times 0
        }

        It "routes a 'pattern'-only entry to the bulk helper" {
            Assert-VmFilesField -AllowBulkEntries `
                -Vm (New-VmWithFilesJson '[{ "pattern": "x", "targetDir": "/a" }]')

            Should -Invoke Assert-VmFileBulkEntry   -Times 1
            Should -Invoke Assert-VmFileSingleEntry -Times 0
        }

        It 'routes a mixed array per-entry' {
            $vm = New-VmWithFilesJson @"
[
    { "source": "x", "target": "/a" },
    { "pattern": "y", "targetDir": "/b" }
]
"@
            Assert-VmFilesField -Vm $vm -AllowBulkEntries

            Should -Invoke Assert-VmFileSingleEntry -Times 1
            Should -Invoke Assert-VmFileBulkEntry   -Times 1
        }
    }

    Context 'discriminator rejection happens before any helper runs' {

        It 'throws on an entry with both source and pattern' {
            { Assert-VmFilesField -AllowBulkEntries `
                -Vm (New-VmWithFilesJson @"
[{ "source": "x", "target": "/a", "pattern": "y", "targetDir": "/b" }]
"@) } |
                Should -Throw -ExpectedMessage "*both 'source' and 'pattern'*"

            Should -Invoke Assert-VmFileSingleEntry -Times 0
            Should -Invoke Assert-VmFileBulkEntry   -Times 0
        }

        It 'throws on an entry with neither source nor pattern' {
            { Assert-VmFilesField -AllowBulkEntries `
                -Vm (New-VmWithFilesJson '[{ "target": "/a" }]') } |
                Should -Throw -ExpectedMessage "*expected 'source'*or 'pattern'*"

            Should -Invoke Assert-VmFileSingleEntry -Times 0
            Should -Invoke Assert-VmFileBulkEntry   -Times 0
        }
    }

    Context 'AllowedSubFields routing' {

        It 'passes the fixed bulk allow-list to the bulk helper' {
            # The bulk form's sub-field set IS the contract with
            # Copy-VmFilesByPattern, not a per-consumer concern, so the
            # dispatcher must not forward consumer AllowedSubFields to
            # the bulk helper.
            Assert-VmFilesField -AllowBulkEntries `
                -Vm               (New-VmWithFilesJson '[{ "pattern": "x", "targetDir": "/a" }]') `
                -AllowedSubFields @('source','target','owner')

            Should -Invoke Assert-VmFileBulkEntry -Times 1 -ParameterFilter {
                ($AllowedSubFields -join ',') -eq 'pattern,targetDir,recurse,preserveRelativePath'
            }
        }

        It 'still forwards consumer AllowedSubFields to the single helper' {
            Assert-VmFilesField -AllowBulkEntries `
                -Vm               (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]') `
                -AllowedSubFields @('source','target','owner')

            Should -Invoke Assert-VmFileSingleEntry -Times 1 -ParameterFilter {
                ($AllowedSubFields -join ',') -eq 'source,target,owner'
            }
        }
    }
}

Describe 'Assert-VmFilesField - PostEntryValidator orchestration' {

    BeforeEach {
        Mock Assert-VmFileSingleEntry { }
        Mock Assert-VmFileBulkEntry   { }
    }

    It 'is invoked once per entry with the supplied context' {
        $vm = New-VmWithFilesJson @"
[
    { "source": "x", "target": "/a" },
    { "source": "y", "target": "/b" }
]
"@
        $script:_seenTargets = @()
        $script:_seenCtx     = $null

        Assert-VmFilesField `
            -Vm                        $vm `
            -PostEntryValidator        {
                param($entry, $context)
                $script:_seenTargets += $entry.target
                $script:_seenCtx      = $context
            } `
            -PostEntryValidatorContext @{ Tag = 'ok' }

        $script:_seenTargets | Should -Be @('/a', '/b')
        $script:_seenCtx.Tag | Should -Be 'ok'
    }

    It 'lets the validator throw to enforce a consumer-specific rule' {
        { Assert-VmFilesField `
            -Vm                 (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]') `
            -PostEntryValidator { param($e, $c) throw "rule-violated: $($e.target)" } } |
            Should -Throw -ExpectedMessage "*rule-violated: /a*"
    }

    It 'is not invoked when files is absent' {
        $script:_called = $false
        Assert-VmFilesField `
            -Vm                 (New-VmWithoutFiles) `
            -PostEntryValidator { param($e, $c) $script:_called = $true }

        $script:_called | Should -BeFalse
    }

    It 'is not invoked when the matched form helper throws' {
        # Documented contract: the hook runs only after the shared
        # shape checks for the matched form pass.
        Mock Assert-VmFileSingleEntry { throw 'helper-rejection' }
        $script:_called = $false

        { Assert-VmFilesField `
            -Vm                 (New-VmWithFilesJson '[{ "source": "x", "target": "/a" }]') `
            -PostEntryValidator { param($e, $c) $script:_called = $true } } |
            Should -Throw

        $script:_called | Should -BeFalse
    }

    It 'is invoked after the bulk helper too, for bulk entries' {
        # Confirms the contract is uniform across forms - the hook
        # author should not have to care whether an entry was single
        # or bulk.
        $script:_called = $false
        Assert-VmFilesField -AllowBulkEntries `
            -Vm                 (New-VmWithFilesJson '[{ "pattern": "x", "targetDir": "/a" }]') `
            -PostEntryValidator { param($e, $c) $script:_called = $true }

        $script:_called | Should -BeTrue
    }

    It 'is not invoked when the discriminator rejects (both source and pattern)' {
        $script:_called = $false
        { Assert-VmFilesField -AllowBulkEntries `
            -Vm (New-VmWithFilesJson @"
[{ "source": "x", "target": "/a", "pattern": "y", "targetDir": "/b" }]
"@) `
            -PostEntryValidator { param($e, $c) $script:_called = $true } } |
            Should -Throw

        $script:_called | Should -BeFalse
    }
}
