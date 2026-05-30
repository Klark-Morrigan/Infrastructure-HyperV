<#
.SYNOPSIS
    Runs unit tests for the Infrastructure.HyperV module.

.DESCRIPTION
    Delegates to the shared Run-Tests.ps1 in PowerShell-Common.
    PowerShell-Common must be checked out at .ci-common before
    running this script locally:
        git clone https://github.com/VitaliiAndreev/PowerShell-Common .ci-common

.EXAMPLE
    .\Run-Tests.ps1
#>

# Repo root is one level up now that this script lives under scripts\.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '.ci-common', '.github', 'actions', 'run-unit-tests', 'Run-Tests.ps1')) `
    -TestsRoot $repoRoot
