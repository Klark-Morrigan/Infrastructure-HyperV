<#
.SYNOPSIS
    Runs unit tests for the Infrastructure.HyperV module.

.DESCRIPTION
    Delegates to the shared Run-Tests.ps1 in Common-PowerShell.
    Common-PowerShell must be checked out at .ci-common before
    running this script locally:
        git clone https://github.com/VitaliiAndreev/Common-PowerShell .ci-common

.EXAMPLE
    .\Run-Tests.ps1

.EXAMPLE
    .\Run-Tests.ps1 -LogPath c:/tmp/p.log
#>

param(
    # Forwarded to the shared runner, which redirects every stream into this
    # file internally. Lets callers self-log with a bare call instead of
    # wrapping the invocation in an external *> redirect.
    [string] $LogPath,

    # Log-retention controls passed straight through; the shared runner owns
    # their default values, so they stay undeclared here (single source).
    [int]    $LogRetention,
    [string] $LogRetentionFilter
)

# Repo root is one level up now that this script lives under scripts\.
$repoRoot = Split-Path -Parent $PSScriptRoot

# Pin TestsRoot to this repo, then forward whatever log params the caller
# actually passed. No [CmdletBinding()] here, so only the declared params can
# appear in $PSBoundParameters - common params cannot leak into the splat.
$forwarded = @{ TestsRoot = $repoRoot }
foreach ($bound in $PSBoundParameters.GetEnumerator()) {
    $forwarded[$bound.Key] = $bound.Value
}

& ([IO.Path]::Combine($repoRoot, '.ci-common', '.github', 'actions',
    'run-unit-tests', 'Run-Tests.ps1')) @forwarded
