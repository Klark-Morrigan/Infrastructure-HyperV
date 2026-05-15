<#
.SYNOPSIS
    Validates the shape of a 'files' array on a VM definition.

.DESCRIPTION
    Performs the shared shape checks for a 'files' array:
      - 'files' may be absent (returns silently).
      - When present, must be a JSON array (PSCustomObject or string
        is rejected).
      - Each entry must be a JSON object.
      - Each entry may only contain sub-fields listed in
        -AllowedSubFields. Unknown sub-fields throw - catches typos
        like 'src' or 'dest'.
      - 'source' is required, non-empty string, and must exist on the
        host at validation time. Existence is checked here, not at
        copy time, so an operator typo fails fast before any VM work
        begins.
      - 'target' is required, non-empty string, and must be an
        absolute Linux path (starts with '/'). Windows-style and
        relative targets are rejected.

    Additional per-entry rules can be supplied via -PostEntryValidator:
    a scriptblock that receives ($entry, $context) and throws on any
    violation.

.PARAMETER Vm
    The parsed VM definition object (the same object the rest of
    the schema sees).

.PARAMETER AllowedSubFields
    Strict allow-list for sub-fields on each entry. Defaults to
    @('source', 'target'). Pass a wider list when the schema is
    being extended (e.g. @('source', 'target', 'owner')).

.PARAMETER PostEntryValidator
    Optional scriptblock invoked once per entry after all shared
    checks pass. Receives ($entry, $context). Should throw on
    violation.

.PARAMETER PostEntryValidatorContext
    Optional value passed as the second argument to -PostEntryValidator.
    Use it to hand the validator any data it needs from the surrounding
    schema.

.EXAMPLE
    # Default shape, no extras.
    Assert-VmFilesField -Vm $vm

.EXAMPLE
    # Allow 'owner', require it, and validate against a known set.
    $context = @{ KnownUsers = $vm.users.name }
    Assert-VmFilesField `
        -Vm                        $vm `
        -AllowedSubFields          @('source', 'target', 'owner') `
        -PostEntryValidator        {
            param($entry, $context)
            if (-not $entry.PSObject.Properties['owner']) {
                throw "files[*].owner is required."
            }
            if ($entry.owner -notin $context.KnownUsers) {
                throw "files[*].owner '$($entry.owner)' is not a known user."
            }
        } `
        -PostEntryValidatorContext $context
#>
function Assert-VmFilesField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter()]
        [string[]] $AllowedSubFields = @('source', 'target'),

        [Parameter()]
        [scriptblock] $PostEntryValidator,

        [Parameter()]
        [object] $PostEntryValidatorContext
    )

    if (-not $Vm.PSObject.Properties['files']) {
        return
    }

    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': files"

    $files = $Vm.files

    if ($null -eq $files -or -not ($files -is [System.Collections.IEnumerable]) -or
        $files -is [string]) {
        throw "$ctx must be a JSON array of file entries."
    }

    # 'source' and 'target' are always required and never overridable
    # by the AllowedSubFields parameter - those two fields ARE the
    # contract.
    $i = 0
    foreach ($entry in $files) {
        $entryCtx = "$ctx[$i]"
        $i++

        if ($null -eq $entry -or
            $entry -isnot [System.Management.Automation.PSCustomObject]) {
            throw "$entryCtx must be a JSON object."
        }

        foreach ($prop in $entry.PSObject.Properties) {
            if ($prop.Name -notin $AllowedSubFields) {
                throw "$entryCtx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($AllowedSubFields -join ', ')."
            }
        }

        if (-not $entry.PSObject.Properties['source']) {
            throw "$entryCtx is missing required sub-field 'source'."
        }
        if ($entry.source -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.source)) {
            throw "$entryCtx.source must be a non-empty string (host path)."
        }
        if (-not (Test-Path -LiteralPath $entry.source)) {
            throw "$entryCtx.source path does not exist on the host: '$($entry.source)'."
        }

        if (-not $entry.PSObject.Properties['target']) {
            throw "$entryCtx is missing required sub-field 'target'."
        }
        if ($entry.target -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.target)) {
            throw "$entryCtx.target must be a non-empty string (absolute Linux path)."
        }
        if ($entry.target -notmatch '^/') {
            throw "$entryCtx.target must be an absolute Linux path starting with '/' (got '$($entry.target)')."
        }

        # Called after the shared checks pass so the validator can
        # assume source / target are already valid and only reason
        # about the fields the caller introduced.
        if ($null -ne $PostEntryValidator) {
            & $PostEntryValidator $entry $PostEntryValidatorContext
        }
    }
}
