<#
.SYNOPSIS
    Removes a /etc/profile.d/<Name>.sh script from a Hyper-V VM under
    sudo. Idempotent: no-op when the target is absent.

.DESCRIPTION
    Single-round-trip uninstall primitive that mirrors
    Set-VmProfileDScript on the removal side. No atomic write is
    needed - `rm` of a single regular file is atomic at the directory-
    entry level - so the cmdlet is intentionally smaller than its
    install counterpart.

    Name is validated host-side by the shared
    Assert-VmProfileDScriptName helper so the install/uninstall pair
    accepts and rejects exactly the same set of inputs. Validation
    runs before any SSH call.

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - this function neither connects nor disposes it.

.PARAMETER Name
    Base name of the profile.d script to remove. The cmdlet derives
    /etc/profile.d/<Name>.sh; do not include the .sh suffix in this
    parameter.

.EXAMPLE
    Remove-VmProfileDScript -SshClient $ssh -Name 'foo'

.NOTES
    On-VM commands run under sudo. The caller is responsible for
    ensuring the SSH user has password-less sudo (cloud-init's default
    admin user does).
#>
function Remove-VmProfileDScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Name
    )

    Assert-VmProfileDScriptName -Name $Name -CmdletName 'Remove-VmProfileDScript'

    $targetPath = "/etc/profile.d/$Name.sh"

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }

    # The existence check makes the remote side a no-op when the file
    # is already gone, matching the idempotence contract of every
    # other VM-install primitive in this module. `set -e` ensures any
    # non-zero from `rm` itself (e.g. ENOENT race between the test and
    # the rm) propagates as a non-zero exit, which the host layer
    # surfaces as a diagnostic exception.
    $script = @"
set -e
TARGET='$targetPath'
if [ ! -e "`$TARGET" ]; then
    exit 0
fi
sudo rm "`$TARGET"
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # the rest of the module.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script
    if ($result.ExitStatus -ne 0) {
        throw ("Remove-VmProfileDScript failed (vm: $vmHost, name: $Name, " +
            "exit $($result.ExitStatus)). stdout: $($result.Output)  " +
            "stderr: $($result.Error)")
    }
}
