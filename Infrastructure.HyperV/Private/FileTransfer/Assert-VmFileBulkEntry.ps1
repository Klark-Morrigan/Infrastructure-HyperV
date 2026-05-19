<#
.SYNOPSIS
    Validates a bulk-form file entry inside a VM 'files' array.

.DESCRIPTION
    Extracted from Assert-VmFilesField so the public dispatcher stays
    small. Bulk entries target Copy-VmFilesByPattern. Rules:
      - All entry sub-fields must be in -AllowedSubFields (the fixed
        bulk allow-list owned by Assert-VmFilesField). Unknown
        sub-fields throw - catches typos like 'recursive' or
        'targetdir'.
      - 'pattern' is required, non-empty string. Existence is NOT
        checked: globs are time-varying and the resolver
        re-evaluates them on every provision run, so a zero-match
        surfaces there - still before any SSH I/O.
      - 'targetDir' is required, non-empty string, absolute Linux
        path.
      - 'recurse' and 'preserveRelativePath' are optional booleans.

.PARAMETER EntryCtx
    Error-message prefix identifying this entry (e.g.
    "VM 'node-01': files[2]"). Built by the caller.

.PARAMETER Entry
    The PSCustomObject parsed from the JSON entry.

.PARAMETER AllowedSubFields
    Fixed bulk allow-list passed in by the dispatcher. Not
    consumer-overridable: the bulk form's sub-field set IS the
    contract with Copy-VmFilesByPattern.
#>
function Assert-VmFileBulkEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $EntryCtx,
        [Parameter(Mandatory)] [object]   $Entry,
        [Parameter(Mandatory)] [string[]] $AllowedSubFields
    )

    foreach ($prop in $Entry.PSObject.Properties) {
        if ($prop.Name -notin $AllowedSubFields) {
            throw "$EntryCtx has unknown sub-field '$($prop.Name)'. Allowed bulk sub-fields: $($AllowedSubFields -join ', ')."
        }
    }

    if (-not $Entry.PSObject.Properties['pattern']) {
        throw "$EntryCtx is missing required sub-field 'pattern'."
    }
    if ($Entry.pattern -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.pattern)) {
        throw "$EntryCtx.pattern must be a non-empty string (host glob)."
    }

    if (-not $Entry.PSObject.Properties['targetDir']) {
        throw "$EntryCtx is missing required sub-field 'targetDir'."
    }
    if ($Entry.targetDir -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.targetDir)) {
        throw "$EntryCtx.targetDir must be a non-empty string (absolute Linux path)."
    }
    if ($Entry.targetDir -notmatch '^/') {
        throw "$EntryCtx.targetDir must be an absolute Linux path starting with '/' (got '$($Entry.targetDir)')."
    }

    if ($Entry.PSObject.Properties['recurse'] -and $Entry.recurse -isnot [bool]) {
        throw "$EntryCtx.recurse must be a boolean."
    }
    if ($Entry.PSObject.Properties['preserveRelativePath'] -and
        $Entry.preserveRelativePath -isnot [bool]) {
        throw "$EntryCtx.preserveRelativePath must be a boolean."
    }
}
