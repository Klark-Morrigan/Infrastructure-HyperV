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
#   Centralised here so every SSH helper raises the same diagnostic and a
#   future change to the prerequisite (e.g. switching off Posh-SSH for the
#   DLL) only needs editing in one place.
# ---------------------------------------------------------------------------

function Assert-SshNetLoaded {
    [CmdletBinding()]
    param()

    if (-not ('Renci.SshNet.SshClient' -as [type])) {
        throw ("SSH.NET assembly not loaded. Import Posh-SSH first " +
               "(e.g. Invoke-ModuleInstall -ModuleName 'Posh-SSH') " +
               "so its bundled Renci.SshNet.dll is available.")
    }
}
