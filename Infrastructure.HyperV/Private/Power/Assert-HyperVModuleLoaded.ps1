# ---------------------------------------------------------------------------
# Assert-HyperVModuleLoaded
#   Guards Power\ public functions against being called on a host where the
#   Hyper-V PowerShell module is not installed or not in scope. Converts the
#   otherwise opaque "Get-VM is not recognized" error into an actionable
#   message that names both the server and client SKU install paths.
#
#   Delegates the loaded -> available -> install cascade to the shared
#   Assert-PsModuleLoaded helper so every prerequisite guard in the module
#   surfaces the same diagnostic shape and a future change to the cascade
#   lands in one place.
#
#   The install hint lives inline here so this file remains the single
#   source of truth for the Hyper-V-specific wording; the shared helper
#   does not try to know per-module SKU details.
# ---------------------------------------------------------------------------

function Assert-HyperVModuleLoaded {
    [CmdletBinding()]
    param()

    Assert-PsModuleLoaded `
        -Name        'Hyper-V' `
        -InstallHint ("Install the Hyper-V PowerShell module: on Windows " +
                      "Server run 'Install-WindowsFeature " +
                      "Hyper-V-PowerShell'; on Windows client run " +
                      "'Enable-WindowsOptionalFeature -Online -FeatureName " +
                      "Microsoft-Hyper-V-Management-PowerShell'.")
}
