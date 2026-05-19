<#
.SYNOPSIS
    Validates the shape of a 'files' array on a VM definition.

.DESCRIPTION
    Performs the shared shape checks for a 'files' array:
      - 'files' may be absent (returns silently).
      - When present, must be a JSON array (PSCustomObject or string
        is rejected).
      - Each entry must be a JSON object.

    Two entry forms are supported. The bulk form is gated behind
    -AllowBulkEntries so existing consumers keep their stricter
    single-form contract by default.

    Single form (always allowed) - see Assert-VmFileSingleEntry:
        { source, target [, ...consumer fields] }

    Bulk form (enabled by -AllowBulkEntries; targets
    Copy-VmFilesByPattern) - see Assert-VmFileBulkEntry:
        { pattern, targetDir [, recurse] [, preserveRelativePath] }

    Discrimination between the two forms is by the presence of
    'source' vs 'pattern'. An entry containing both is ambiguous and
    rejected; an entry containing neither is rejected with a message
    that names both options.

    Additional per-entry rules can be supplied via -PostEntryValidator:
    a scriptblock that receives ($entry, $context) and throws on any
    violation. It runs after the shared shape checks for whichever
    form matched.

.PARAMETER Vm
    The parsed VM definition object (the same object the rest of
    the schema sees).

.PARAMETER AllowedSubFields
    Strict allow-list for sub-fields on each single-form entry.
    Defaults to @('source', 'target'). Pass a wider list when the
    schema is being extended (e.g. @('source', 'target', 'owner')).
    Does not affect bulk-form entries: those always use the fixed
    bulk allow-list owned by this function.

.PARAMETER AllowBulkEntries
    Opt-in switch that enables the bulk entry form. Off by default
    so every existing caller keeps behaving exactly as before -
    this is the backward-compatibility guarantee for consumers
    that have not migrated their schemas.

.PARAMETER PostEntryValidator
    Optional scriptblock invoked once per entry after all shared
    checks pass. Receives ($entry, $context). Should throw on
    violation.

.PARAMETER PostEntryValidatorContext
    Optional value passed as the second argument to -PostEntryValidator.
    Use it to hand the validator any data it needs from the surrounding
    schema.

.EXAMPLE
    # Default shape, single form only.
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

.EXAMPLE
    # Mixed single + bulk entries (e.g. Vm-Provisioner schema).
    Assert-VmFilesField -Vm $vm -AllowBulkEntries
#>
function Assert-VmFilesField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter()]
        [string[]] $AllowedSubFields = @('source', 'target'),

        [Parameter()]
        [switch] $AllowBulkEntries,

        [Parameter()]
        [scriptblock] $PostEntryValidator,

        [Parameter()]
        [object] $PostEntryValidatorContext
    )

    # Fixed bulk allow-list. Not exposed via a parameter: the bulk
    # form's sub-field set IS the contract with Copy-VmFilesByPattern,
    # not a per-consumer concern.
    $bulkAllowedSubFields = @('pattern', 'targetDir', 'recurse', 'preserveRelativePath')

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

    $i = 0
    foreach ($entry in $files) {
        $entryCtx = "$ctx[$i]"
        $i++

        if ($null -eq $entry -or
            $entry -isnot [System.Management.Automation.PSCustomObject]) {
            throw "$entryCtx must be a JSON object."
        }

        if ($AllowBulkEntries) {
            # Discriminate by presence of 'source' vs 'pattern'. Done
            # before the per-form sub-field check so an ambiguous or
            # missing-discriminator entry produces an error that names
            # the intended form, instead of an 'unknown sub-field
            # pattern' that hides the real choice.
            $hasSource  = [bool] $entry.PSObject.Properties['source']
            $hasPattern = [bool] $entry.PSObject.Properties['pattern']

            if ($hasSource -and $hasPattern) {
                throw "$entryCtx has both 'source' and 'pattern'; only one is allowed (single vs bulk form)."
            }
            if (-not $hasSource -and -not $hasPattern) {
                throw "$entryCtx is missing required sub-field; expected 'source' (single form) or 'pattern' (bulk form)."
            }

            if ($hasPattern) {
                Assert-VmFileBulkEntry `
                    -EntryCtx         $entryCtx `
                    -Entry            $entry `
                    -AllowedSubFields $bulkAllowedSubFields
            }
            else {
                Assert-VmFileSingleEntry `
                    -EntryCtx         $entryCtx `
                    -Entry            $entry `
                    -AllowedSubFields $AllowedSubFields
            }
        }
        else {
            Assert-VmFileSingleEntry `
                -EntryCtx         $entryCtx `
                -Entry            $entry `
                -AllowedSubFields $AllowedSubFields
        }

        # Called after the shared checks pass so the validator can
        # assume the entry is well-formed for its matched form.
        if ($null -ne $PostEntryValidator) {
            & $PostEntryValidator $entry $PostEntryValidatorContext
        }
    }
}
