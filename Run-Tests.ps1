<#
.SYNOPSIS
    Runs unit tests for the Infrastructure.HyperV module.

.DESCRIPTION
    Delegates to the shared Run-Tests.ps1 in Infrastructure-Common.
    Infrastructure-Common must be checked out at .ci-common before
    running this script locally:
        git clone https://github.com/VitaliiAndreev/Infrastructure-Common .ci-common

.EXAMPLE
    .\Run-Tests.ps1
#>

& ([IO.Path]::Combine($PSScriptRoot, '.ci-common', '.github', 'actions', 'run-unit-tests', 'Run-Tests.ps1')) `
    -TestsRoot $PSScriptRoot
