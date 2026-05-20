<#
.SYNOPSIS
    Validates the shape of an 'envVars' array on a VM definition.

.DESCRIPTION
    Performs the schema checks for an 'envVars' array on a VM
    definition, mirroring the Assert-VmFilesField "shared rules,
    consumer opts in" pattern. The rule set is fixed in v1:

      - 'envVars' may be absent: returns silently.
      - When present, must be a JSON array (PSCustomObject or string
        is rejected with a message naming the VM).
      - Each entry must be a PSCustomObject with exactly the
        allowed sub-fields 'name' and 'value'.
      - 'name': required string, matches POSIX identifier syntax
        (^[A-Za-z_][A-Za-z0-9_]*$), must not contain '='.
      - 'value': required string, non-empty, no '\n', '\r', '\0'.
      - 'name' values must be unique across entries (duplicate
        writes to the same key would mask operator intent). The
        duplicate detection runs after per-entry shape checks so a
        malformed entry surfaces first.

    The validator is a pure function over the parsed VM object - no
    SSH, no host I/O - so failing the schema is the cheapest layer
    available and a typo in the JSON never reaches the wire.

.PARAMETER Vm
    The parsed VM definition object (the same object the rest of
    the schema sees).

.EXAMPLE
    Assert-VmEnvVarsField -Vm $vm
#>
function Assert-VmEnvVarsField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    if (-not $Vm.PSObject.Properties['envVars']) {
        return
    }

    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': envVars"

    $entries = $Vm.envVars

    # Reject anything that is not a "real" JSON array. ConvertFrom-Json
    # surfaces arrays as Object[] (IEnumerable, not a string and not a
    # PSCustomObject), so the strict checks below catch the null,
    # string, and object-instead-of-array cases that the user might
    # accidentally write.
    if ($null -eq $entries -or
        $entries -is [string] -or
        $entries -is [System.Management.Automation.PSCustomObject] -or
        -not ($entries -is [System.Collections.IEnumerable])) {
        throw "$ctx must be a JSON array of { name, value } entries."
    }

    $allowedSubFields = @('name', 'value')
    $nameRegex        = '^[A-Za-z_][A-Za-z0-9_]*$'

    $seenNames = @{}
    $i = 0
    foreach ($entry in $entries) {
        $entryCtx = "$ctx[$i]"
        $i++

        if ($null -eq $entry -or
            $entry -isnot [System.Management.Automation.PSCustomObject]) {
            throw "$entryCtx must be a JSON object."
        }

        # Strict allow-list: unknown sub-fields are a schema error so
        # a typo like 'default' or 'append' never silently becomes a
        # no-op write.
        foreach ($prop in $entry.PSObject.Properties) {
            if ($prop.Name -notin $allowedSubFields) {
                throw "$entryCtx has unknown sub-field '$($prop.Name)'; allowed: $($allowedSubFields -join ', ')."
            }
        }

        if (-not $entry.PSObject.Properties['name']) {
            throw "$entryCtx is missing required sub-field 'name'."
        }
        if (-not $entry.PSObject.Properties['value']) {
            throw "$entryCtx is missing required sub-field 'value'."
        }

        $name = $entry.name
        if ($name -isnot [string]) {
            throw "$entryCtx.name must be a string."
        }
        if ($name -notmatch $nameRegex) {
            throw "$entryCtx.name '$name' is not a POSIX identifier (must match $nameRegex)."
        }
        # The regex above already excludes '=', but the explicit check
        # makes the failure mode unambiguous for the most common
        # mistake (operator pasted 'KEY=VAL' into the name field).
        if ($name.Contains('=')) {
            throw "$entryCtx.name '$name' must not contain '='."
        }

        $value = $entry.value
        if ($value -isnot [string]) {
            throw "$entryCtx.value must be a string."
        }
        if ($value.Length -eq 0) {
            throw "$entryCtx.value must be a non-empty string."
        }
        if ($value.Contains("`n")) {
            throw "$entryCtx.value must not contain a newline (LF)."
        }
        if ($value.Contains("`r")) {
            throw "$entryCtx.value must not contain a carriage return (CR)."
        }
        if ($value.Contains("`0")) {
            throw "$entryCtx.value must not contain a NUL byte."
        }

        # Defer duplicate-name detection to a post-loop pass so per-entry
        # shape errors always surface first - an operator chasing a
        # 'duplicate' message on a malformed entry would otherwise miss
        # the real bug.
        $seenNames[$name] = ($seenNames[$name] ?? 0) + 1
    }

    foreach ($kv in $seenNames.GetEnumerator()) {
        if ($kv.Value -gt 1) {
            throw "$ctx has duplicate entries for name '$($kv.Key)' ($($kv.Value) occurrences)."
        }
    }
}
