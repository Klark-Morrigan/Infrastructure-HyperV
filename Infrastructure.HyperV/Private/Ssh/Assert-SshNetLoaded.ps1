# ---------------------------------------------------------------------------
# Assert-SshNetLoaded
#   Guards SSH-facing public functions against being called before the
#   Renci.SshNet assembly is loaded.
#
#   The Renci.SshNet types are referenced inside function bodies (not as
#   parameter types) so the module imports cleanly on hosts without
#   Posh-SSH. The guard converts the otherwise opaque "Unable to find
#   type" error into an actionable message that names the missing
#   prerequisite and how to install it.
#
#   Delegates the loaded -> available -> install cascade to the shared
#   Assert-PsModuleLoaded helper so every prerequisite guard in the module
#   surfaces the same diagnostic shape and a future change to the cascade
#   lands in one place.
#
#   After the helper returns, a belt-and-braces sanity check confirms the
#   SSH.NET type is reachable. Posh-SSH bundles Renci.SshNet.dll and loads
#   it on import today; the check makes a future Posh-SSH restructure that
#   loads cleanly but no longer ships the DLL fail loud at this guard
#   rather than silently at the first SSH call.
# ---------------------------------------------------------------------------

function Assert-SshNetLoaded {
    [CmdletBinding()]
    param()

    Assert-PsModuleLoaded `
        -Name        'Posh-SSH' `
        -InstallHint ("Import Posh-SSH first " +
                      "(e.g. Invoke-ModuleInstall -ModuleName 'Posh-SSH') " +
                      "so its bundled Renci.SshNet.dll is available.")

    # Posh-SSH is in scope but the bundled SSH.NET type is not - a
    # half-installed or restructured Posh-SSH. Name the type so the
    # regression is unambiguous to whoever reads the error.
    if (-not ('Renci.SshNet.SshClient' -as [type])) {
        throw ("Posh-SSH is loaded but the Renci.SshNet.SshClient type " +
               "is not available. The bundled Renci.SshNet.dll appears " +
               "to be missing from the installed Posh-SSH package; " +
               "reinstall Posh-SSH to restore it.")
    }
}
