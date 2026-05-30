<#
.SYNOPSIS
    Runs SSH integration tests against a Docker target container.

.DESCRIPTION
    Delegates to the shared Run-IntegrationTests-AgainstDockerTarget.ps1 in
    PowerShell-Common. PowerShell-Common must be checked out at
    .ci-common before running this script locally:
        git clone https://github.com/VitaliiAndreev/PowerShell-Common .ci-common

.EXAMPLE
    .\Run-IntegrationTests-AgainstDockerTarget.ps1
#>

# Repo root is one level up now that this script lives under scripts\;
# the .ci-common checkout of PowerShell-Common also has this wrapper under
# scripts\ after the recent migration.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '.ci-common', 'scripts', 'Run-IntegrationTests-AgainstDockerTarget.ps1')) `
    -TestsRoot $repoRoot
