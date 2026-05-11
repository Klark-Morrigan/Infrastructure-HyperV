<#
.SYNOPSIS
    Runs SSH integration tests against a Docker target container.

.DESCRIPTION
    Delegates to the shared Run-IntegrationTests-AgainstDockerTarget.ps1 in
    Infrastructure-Common. Infrastructure-Common must be checked out at
    .ci-common before running this script locally:
        git clone https://github.com/VitaliiAndreev/Infrastructure-Common .ci-common

.EXAMPLE
    .\Run-IntegrationTests-AgainstDockerTarget.ps1
#>

& ([IO.Path]::Combine($PSScriptRoot, '.ci-common', 'Run-IntegrationTests-AgainstDockerTarget.ps1')) `
    -TestsRoot $PSScriptRoot
