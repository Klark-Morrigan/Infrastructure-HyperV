<#
.SYNOPSIS
    Validates a single-form file entry inside a VM 'files' array.

.DESCRIPTION
    Extracted from Assert-VmFilesField so the public dispatcher stays
    small and the two entry forms (single vs bulk) can evolve
    independently. Rules:
      - All entry sub-fields must be in -AllowedSubFields. Unknown
        sub-fields throw - catches typos like 'src' or 'dest'.
      - 'source' is required, non-empty string, and must exist on
        the host. Existence is checked at validation time so an
        operator typo fails fast before any VM work begins.
      - 'target' is required, non-empty string, absolute Linux path.

.PARAMETER EntryCtx
    Error-message prefix identifying this entry (e.g.
    "VM 'node-01': files[2]"). Built by the caller.

.PARAMETER Entry
    The PSCustomObject parsed from the JSON entry.

.PARAMETER AllowedSubFields
    Allow-list for entry sub-fields. Caller-controlled so consumers
    can extend the single-form schema (e.g. add 'owner').
#>
function Assert-VmFileSingleEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $EntryCtx,
        [Parameter(Mandatory)] [object]   $Entry,
        [Parameter(Mandatory)] [string[]] $AllowedSubFields
    )

    foreach ($prop in $Entry.PSObject.Properties) {
        if ($prop.Name -notin $AllowedSubFields) {
            throw "$EntryCtx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($AllowedSubFields -join ', ')."
        }
    }

    if (-not $Entry.PSObject.Properties['source']) {
        throw "$EntryCtx is missing required sub-field 'source'."
    }
    if ($Entry.source -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.source)) {
        throw "$EntryCtx.source must be a non-empty string (host path)."
    }
    if (-not (Test-Path -LiteralPath $Entry.source)) {
        throw "$EntryCtx.source path does not exist on the host: '$($Entry.source)'."
    }

    if (-not $Entry.PSObject.Properties['target']) {
        throw "$EntryCtx is missing required sub-field 'target'."
    }
    if ($Entry.target -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.target)) {
        throw "$EntryCtx.target must be a non-empty string (absolute Linux path)."
    }
    if ($Entry.target -notmatch '^/') {
        throw "$EntryCtx.target must be an absolute Linux path starting with '/' (got '$($Entry.target)')."
    }
}
