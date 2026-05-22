<#
.SYNOPSIS
    Validates a profile.d script Name value before it is interpolated
    into a remote bash script or appended to a VM-side file path.

.DESCRIPTION
    Shared host-side validator for the Set-VmProfileDScript and
    Remove-VmProfileDScript cmdlets. Both compose Name into
    /etc/profile.d/<Name>.sh and into a single-quoted bash assignment;
    the validation rules must therefore stay byte-identical across the
    pair so an install accepted by one cmdlet cannot be rejected by the
    other (or vice versa).

    Rules:
      - Name is a non-empty string.
      - Name matches `^[A-Za-z0-9._-]+$` (the tight character class
        keeps it safe for single-quoted bash embedding and for use as
        a POSIX path segment).
      - Name is not '.' or '..' (the cmdlets would derive a directory-
        like path that is not a regular profile.d file).
      - Name does not end with '.sh' (the cmdlets append the suffix
        themselves; accepting it would let callers double-suffix).

    The helper is private because it has no responsibility outside this
    module's profile.d cmdlets and offers no behaviour beyond shape
    validation.

.PARAMETER Name
    The Name parameter value to validate.

.PARAMETER CmdletName
    Caller identity prefixed to every thrown message so the operator
    sees which public cmdlet rejected the input. Defaults to the
    generic 'Assert-VmProfileDScriptName' label.

.EXAMPLE
    Assert-VmProfileDScriptName -Name $Name -CmdletName 'Remove-VmProfileDScript'
#>
function Assert-VmProfileDScriptName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name,

        [string] $CmdletName = 'Assert-VmProfileDScriptName'
    )

    if ([string]::IsNullOrEmpty($Name)) {
        throw "${CmdletName}: -Name must be a non-empty string."
    }
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw ("${CmdletName}: -Name '$Name' must match " +
            "^[A-Za-z0-9._-]+`$ (no '/', spaces, or other characters).")
    }
    if ($Name -eq '.' -or $Name -eq '..') {
        throw "${CmdletName}: -Name '$Name' is a reserved directory name."
    }
    if ($Name.EndsWith('.sh')) {
        throw ("${CmdletName}: -Name '$Name' must not end with '.sh' - " +
            "the cmdlet appends the suffix.")
    }
}
