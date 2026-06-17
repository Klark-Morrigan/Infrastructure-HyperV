<#
.SYNOPSIS
    Runs integration tests for the Infrastructure.HyperV module in Docker.

.DESCRIPTION
    Delegates to the shared Run-IntegrationTests.ps1 in Common-PowerShell.
    Common-PowerShell must be checked out at .ci-common before
    running this script locally:
        git clone https://github.com/Klark-Morrigan/Common-PowerShell .ci-common

.PARAMETER DockerImage
    Docker image to run tests in. Defaults to
    mcr.microsoft.com/powershell:latest.

.EXAMPLE
    .\Run-IntegrationTests-InDocker.ps1
#>

param(
    [string] $DockerImage = 'mcr.microsoft.com/powershell:latest'
)

# Repo root is one level up now that this script lives under scripts\.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '.ci-common', '.github', 'actions', 'run-integration-tests', 'Run-IntegrationTests.ps1')) `
    -TestsRoot   $repoRoot `
    -DockerImage $DockerImage
