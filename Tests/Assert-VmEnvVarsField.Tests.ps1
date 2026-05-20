BeforeAll {
    # Pure function over the parsed VM object - no helpers to mock.
    # Dot-sourcing directly keeps the unit test boundary tight.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\EnvVars\Assert-VmEnvVarsField.ps1"

    function New-VmWithEnvVarsJson([string] $EnvVarsJson) {
        $json = if ($null -eq $EnvVarsJson) {
            '{ "vmName": "node-01" }'
        } else {
            "{ `"vmName`": `"node-01`", `"envVars`": $EnvVarsJson }"
        }
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutEnvVars {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }

    # Build a VM whose envVars[0].value contains the given literal char.
    # Done via the host-object route, not by hand-crafting JSON with a
    # NUL/CR/LF inside, because some of those bytes break the JSON
    # parser before the validator ever sees them.
    function New-VmWithSingleValue([string] $Value) {
        return [pscustomobject]@{
            vmName  = 'node-01'
            envVars = @([pscustomobject]@{ name = 'FOO'; value = $Value })
        }
    }
}

Describe 'Assert-VmEnvVarsField - presence and array shape' {

    It 'returns silently when envVars is absent' {
        { Assert-VmEnvVarsField -Vm (New-VmWithoutEnvVars) } | Should -Not -Throw
    }

    It 'returns silently for an empty array (transport handles the remove-block semantic)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[]') } | Should -Not -Throw
    }

    It 'returns silently for a valid single entry' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "1" }]') } |
            Should -Not -Throw
    }

    It 'returns silently for multiple valid entries' {
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO_HOME", "value": "/opt/foo" },
    { "name": "BAR_OPTS", "value": "-Xmx512m" }
]
"@
        { Assert-VmEnvVarsField -Vm $vm } | Should -Not -Throw
    }

    It 'throws when envVars is a JSON object instead of an array' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '{ "name": "X", "value": "1" }') } |
            Should -Throw -ExpectedMessage "*envVars must be a JSON array*"
    }

    It 'throws when envVars is a string' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '"FOO=1"') } |
            Should -Throw -ExpectedMessage "*envVars must be a JSON array*"
    }

    It 'throws when envVars is JSON null (distinct from absent)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson 'null') } |
            Should -Throw -ExpectedMessage "*envVars must be a JSON array*"
    }

    It 'names the VM in the error context' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson 'null') } |
            Should -Throw -ExpectedMessage "*VM 'node-01'*"
    }

    It "uses '(unknown)' when vmName is absent" {
        $vm = ('{ "envVars": null }' | ConvertFrom-Json)
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*VM '(unknown)'*"
    }
}

Describe 'Assert-VmEnvVarsField - per-entry shape' {

    It 'throws when an entry is JSON null' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[null]') } |
            Should -Throw -ExpectedMessage "*envVars[[]0[]] must be a JSON object*"
    }

    It 'throws when an entry is a string' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '["FOO=1"]') } |
            Should -Throw -ExpectedMessage "*envVars[[]0[]] must be a JSON object*"
    }

    It 'reports the offending entry index (off-by-one guard)' {
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO", "value": "1" },
    "oops"
]
"@
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*envVars[[]1[]]*"
    }

    It 'throws when name is missing' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'name'*"
    }

    It 'throws when value is missing' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO" }]') } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'value'*"
    }

    It 'throws on an unknown sub-field naming the offending key' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "1", "default": "x" }]') } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'default'*"
    }

    It "throws on an 'append' sub-field (no support in v1)" {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "1", "append": true }]') } |
            Should -Throw -ExpectedMessage "*unknown sub-field 'append'*"
    }
}

Describe 'Assert-VmEnvVarsField - name validation' {

    It 'rejects a name starting with a digit' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "1FOO", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name '1FOO'*POSIX identifier*"
    }

    It 'rejects a name containing a dash' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO-BAR", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name 'FOO-BAR'*POSIX identifier*"
    }

    It 'rejects a name containing whitespace' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO BAR", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name 'FOO BAR'*POSIX identifier*"
    }

    It 'rejects an empty name' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*POSIX identifier*"
    }

    It "rejects a name containing '=' (caught by the identifier regex)" {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO=", "value": "1" }]') } |
            Should -Throw -ExpectedMessage "*name 'FOO='*"
    }
}

Describe 'Assert-VmEnvVarsField - value validation' {

    It 'rejects an empty value' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "" }]') } |
            Should -Throw -ExpectedMessage "*value must be a non-empty string*"
    }

    It 'rejects a value containing a newline (LF)' {
        # JSON encodes the LF; ConvertFrom-Json decodes back to a real \n.
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "a\nb" }]') } |
            Should -Throw -ExpectedMessage "*newline (LF)*"
    }

    It 'rejects a value containing a carriage return (CR)' {
        { Assert-VmEnvVarsField -Vm (New-VmWithEnvVarsJson '[{ "name": "FOO", "value": "a\rb" }]') } |
            Should -Throw -ExpectedMessage "*carriage return (CR)*"
    }

    It 'rejects a value containing a NUL byte' {
        # Construct via host object so the source file stays clean
        # ASCII; the JSON path here would either be stripped or break
        # the parser depending on input encoding.
        $vm = New-VmWithSingleValue ("a" + [char]0 + "b")
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*NUL byte*"
    }
}

Describe 'Assert-VmEnvVarsField - duplicate name detection' {

    It 'throws when two entries share a name' {
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO", "value": "1" },
    { "name": "FOO", "value": "2" }
]
"@
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*duplicate entries for name 'FOO'*"
    }

    It 'surfaces a malformed-entry error before a duplicate-name error' {
        # Locks the documented ordering: shape first, dup-detection
        # second, so an operator chasing a 'duplicate' message is
        # never distracted from the real bug in a malformed entry.
        $vm = New-VmWithEnvVarsJson @"
[
    { "name": "FOO", "value": "1" },
    { "name": "FOO" }
]
"@
        { Assert-VmEnvVarsField -Vm $vm } |
            Should -Throw -ExpectedMessage "*missing required sub-field 'value'*"
    }
}
