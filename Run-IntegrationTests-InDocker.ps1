<#
.SYNOPSIS
    Runs integration tests for the Infrastructure.HyperV module in Docker.

.DESCRIPTION
    Delegates to the shared Run-IntegrationTests.ps1 in Infrastructure-Common.
    Infrastructure-Common must be checked out at .ci-common before
    running this script locally:
        git clone https://github.com/VitaliiAndreev/Infrastructure-Common .ci-common

.PARAMETER DockerImage
    Docker image to run tests in. Defaults to
    mcr.microsoft.com/powershell:latest.

.EXAMPLE
    .\Run-IntegrationTests-InDocker.ps1
#>

param(
    [string] $DockerImage = 'mcr.microsoft.com/powershell:latest'
)

& ([IO.Path]::Combine($PSScriptRoot, '.ci-common', '.github', 'actions', 'run-integration-tests', 'Run-IntegrationTests.ps1')) `
    -TestsRoot   $PSScriptRoot `
    -DockerImage $DockerImage
