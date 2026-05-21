# ---------------------------------------------------------------------------
# Assert-PsModuleLoaded
#   Shared "ensure a PowerShell module is in scope, or throw with an install
#   hint" primitive. Used by per-prerequisite guards (e.g. SSH, Hyper-V) so
#   the loaded -> available -> install cascade lives in one place and every
#   guard surfaces the same diagnostic shape.
#
#   Three-step cascade, in order:
#     1. Already loaded?         Get-Module -Name <Name>                -> return
#     2. Installed but not in?   Get-Module -Name <Name> -ListAvailable -> import
#     3. Not installed.          throw with the caller-supplied InstallHint
#
#   Why not Get-Command <cmdletName>: false negative when
#   $PSModuleAutoloadingPreference = 'None' (cmdlet not discovered until
#   imported), and false positive when an unrelated module exports a function
#   of the same name (e.g. VMware PowerCLI's Get-VM colliding with the
#   Hyper-V cmdlet). Asking the module system about the module by name
#   avoids both failure modes.
#
#   The InstallHint is mandatory and inlined verbatim into the error so each
#   consumer supplies its own SKU-appropriate wording (e.g. server vs client
#   feature names) instead of this helper trying to know them all.
# ---------------------------------------------------------------------------

function Assert-PsModuleLoaded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $InstallHint
    )

    # Step 1: already loaded. No -ListAvailable so we only see imported
    # modules; this is the no-side-effect happy path.
    if (Get-Module -Name $Name) {
        return
    }

    # Step 2: installed on disk but not in scope. Import it so the caller
    # can use the cmdlets immediately afterwards. Stop on import failure so
    # we can wrap it with a distinct, actionable message rather than letting
    # the operator chase the wrong fix for a half-installed feature.
    if (Get-Module -Name $Name -ListAvailable) {
        try {
            Import-Module -Name $Name -ErrorAction Stop
        }
        catch {
            throw [System.Management.Automation.RuntimeException]::new(
                "PowerShell module '$Name' is present but failed to load. $InstallHint",
                $_.Exception
            )
        }
        return
    }

    # Step 3: not installed anywhere PowerShell can find it.
    throw "Required PowerShell module '$Name' is not installed. $InstallHint"
}
