BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Assert-VmFilesField.ps1"

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

    # Real on-disk source for happy-path tests - the validator runs
    # Test-Path so the path must actually exist.
    function New-ExistingSourcePath {
        $path = Join-Path $TestDrive 'src.bin'
        Set-Content -Path $path -Value 'unit-test-bytes' -Encoding Byte
        return ($path -replace '\\', '\\')
    }
}

Describe 'Assert-VmFilesField - shared shape' {

    Context 'optional field absent or empty' {

        It 'returns silently when files is absent' {
            { Assert-VmFilesField -Vm (New-VmWithoutFiles) } | Should -Not -Throw
        }

        It 'returns silently when files is an empty array' {
            { Assert-VmFilesField -Vm (New-VmWithFilesJson '[]') } | Should -Not -Throw
        }
    }

    Context 'happy path with defaults (source + target only)' {

        It 'accepts a single entry with an existing source and absolute target' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"/opt/lib/x.bin`" }]"
            { Assert-VmFilesField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts multiple entries' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson @"
[
    { "source": "$src", "target": "/opt/lib/a.bin" },
    { "source": "$src", "target": "/opt/lib/b.bin" }
]
"@
            { Assert-VmFilesField -Vm $vm } | Should -Not -Throw
        }
    }

    Context 'shape rejection' {

        It 'throws when files is a JSON object instead of an array' {
            $vm = New-VmWithFilesJson '{ "source": "x", "target": "/y" }'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files must be a JSON array*"
        }

        It 'throws when files is JSON null' {
            # A literal "files": null is distinct from "files absent" and
            # must fail loudly so the operator does not assume the field
            # was silently ignored.
            $vm = New-VmWithFilesJson 'null'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files must be a JSON array*"
        }

        It 'throws when an entry is JSON null' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[null, { `"source`": `"$src`", `"target`": `"/y`" }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files[0] must be a JSON object*"
        }

        It 'throws when an entry is not an object' {
            $vm = New-VmWithFilesJson '["just-a-string"]'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files[0] must be a JSON object*"
        }

        It 'throws on unknown sub-field with the default allow-list' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"src`": `"$src`", `"target`": `"/y`" }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*unknown sub-field 'src'*"
        }
    }

    Context 'source rules' {

        It 'throws when source is missing' {
            $vm = New-VmWithFilesJson '[{ "target": "/y" }]'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*missing required sub-field 'source'*"
        }

        It 'throws when source is a JSON number instead of a string' {
            $vm = New-VmWithFilesJson '[{ "source": 42, "target": "/y" }]'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*source must be a non-empty string*"
        }

        It 'throws when source is a whitespace-only string' {
            $vm = New-VmWithFilesJson '[{ "source": "   ", "target": "/y" }]'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*source must be a non-empty string*"
        }

        It 'throws when source path does not exist on the host' {
            $vm = New-VmWithFilesJson `
                '[{ "source": "C:\\does-not-exist-xyz\\f.bin", "target": "/y" }]'
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*source path does not exist*"
        }
    }

    Context 'target rules' {

        It 'throws when target is missing' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`" }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*missing required sub-field 'target'*"
        }

        It 'throws when target is a JSON number instead of a string' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": 42 }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*target must be a non-empty string*"
        }

        It 'throws when target is a whitespace-only string' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"   `" }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*target must be a non-empty string*"
        }

        It 'throws when target is a relative path' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"opt/x`" }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*absolute Linux path*"
        }

        It 'throws when target is a Windows-style path' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"C:\\opt\\x`" }]"
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*absolute Linux path*"
        }
    }

    Context 'error context' {

        It 'reports the correct index when the second entry fails' {
            # Guards against an off-by-one in the index counter that
            # otherwise would silently report all failures as files[0].
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson @"
[
    { "source": "$src", "target": "/a" },
    { "source": "$src", "target": "relative-bad" }
]
"@
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files[1]*absolute Linux path*"
        }

        It 'reports VM name as (unknown) when vmName is absent on the VM' {
            $src = New-ExistingSourcePath
            # Bypass New-VmWithFilesJson because it always injects vmName.
            $vm = ("{ `"files`": [{ `"source`": `"$src`", `"target`": `"bad`" }] }" |
                ConvertFrom-Json)
            { Assert-VmFilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*VM '(unknown)'*"
        }
    }
}

Describe 'Assert-VmFilesField - consumer extensions' {

    Context 'custom AllowedSubFields' {

        It 'accepts an extra field that the consumer added to the allow-list' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"/y`", `"owner`": `"app`" }]"
            { Assert-VmFilesField -Vm $vm `
                -AllowedSubFields @('source','target','owner') } |
                Should -Not -Throw
        }

        It 'still rejects fields outside the consumer-supplied allow-list' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"/y`", `"hax`": `"x`" }]"
            { Assert-VmFilesField -Vm $vm `
                -AllowedSubFields @('source','target','owner') } |
                Should -Throw -ExpectedMessage "*unknown sub-field 'hax'*"
        }
    }

    Context 'PostEntryValidator' {

        It 'is invoked once per entry with the supplied context' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson @"
[
    { "source": "$src", "target": "/a", "owner": "app1" },
    { "source": "$src", "target": "/b", "owner": "app2" }
]
"@
            $script:_seenOwners = @()
            $script:_seenCtx    = $null

            Assert-VmFilesField `
                -Vm                        $vm `
                -AllowedSubFields          @('source','target','owner') `
                -PostEntryValidator        {
                    param($entry, $context)
                    $script:_seenOwners += $entry.owner
                    $script:_seenCtx     = $context
                } `
                -PostEntryValidatorContext @{ Pass = 'ok' }

            $script:_seenOwners | Should -Be @('app1', 'app2')
            $script:_seenCtx.Pass | Should -Be 'ok'
        }

        It 'lets the validator throw to enforce a consumer-specific rule' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"/a`", `"owner`": `"ghost`" }]"

            {
                Assert-VmFilesField `
                    -Vm                        $vm `
                    -AllowedSubFields          @('source','target','owner') `
                    -PostEntryValidator        {
                        param($entry, $context)
                        if ($entry.owner -notin $context.KnownUsers) {
                            throw "owner '$($entry.owner)' is not a known user."
                        }
                    } `
                    -PostEntryValidatorContext @{ KnownUsers = @('appuser') }
            } | Should -Throw -ExpectedMessage "*owner 'ghost' is not a known user*"
        }

        It 'is not invoked when files is absent' {
            $script:_called = $false
            Assert-VmFilesField `
                -Vm                 (New-VmWithoutFiles) `
                -PostEntryValidator { param($e, $c) $script:_called = $true }
            $script:_called | Should -BeFalse
        }

        It 'is not invoked when a shared check fails before reaching it' {
            # Documented contract: the hook runs only after the shared
            # source/target rules have passed, so a hook author can rely
            # on those fields being well-formed.
            $vm = New-VmWithFilesJson '[{ "source": "missing.bin", "target": "/a" }]'
            $script:_called = $false
            {
                Assert-VmFilesField `
                    -Vm                 $vm `
                    -PostEntryValidator { param($e, $c) $script:_called = $true }
            } | Should -Throw
            $script:_called | Should -BeFalse
        }
    }
}
