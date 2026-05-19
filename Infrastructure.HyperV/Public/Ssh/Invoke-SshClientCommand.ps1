# ---------------------------------------------------------------------------
# Invoke-SshClientCommand
#   Runs a shell command on a remote host via an SSH.NET SshClient and
#   returns a normalised result object.
#
#   $SshClient is typed [object] rather than [Renci.SshNet.SshClient] to
#   avoid resolving the Renci type at module import time. The Renci assembly
#   is bundled with Posh-SSH and may not yet be loaded when this module is
#   imported. Callers must load Posh-SSH before passing a client instance.
#
#   Return shape matches Posh-SSH's Invoke-SshClientCommand output so callers that
#   previously used Posh-SSH cmdlets need only swap the call site.
# ---------------------------------------------------------------------------

function Invoke-SshClientCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Command
    )

    Assert-SshNetLoaded

    $cmd = $SshClient.RunCommand($Command)

    [PSCustomObject]@{
        Output     = $cmd.Result
        Error      = $cmd.Error
        ExitStatus = $cmd.ExitStatus
    }
}
