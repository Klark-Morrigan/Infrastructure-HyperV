<#
.SYNOPSIS
    Creates or reconciles a symbolic link on a Hyper-V VM under sudo.

.DESCRIPTION
    Single-round-trip primitive that ensures <Path> is a symlink pointing
    at <Target>. Idempotent on a matching link; throws when <Path> exists
    as anything else (regular file, directory, symlink to a different
    target). The conflict refusal is intentional: silently replacing a
    real file with a symlink is the worst class of bug (data loss with
    no audit trail), so the cmdlet is a primitive and leaves the
    "what now" routing to the caller.

    The remote script runs under `set -e` and uses exit code 65
    (EX_DATAERR from sysexits) to signal a conflict back to the host
    layer, which surfaces it as a PowerShell exception naming the path
    and the observed file type.

    Path and target are validated host-side before any SSH call: both
    must be non-empty absolute paths with no `..` segments, no NUL byte,
    and no single quote (the remote script embeds both inside
    single-quoted bash assignments).

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - this function neither connects nor disposes it.

.PARAMETER Path
    Absolute path on the VM where the symlink should exist.

.PARAMETER Target
    Absolute path on the VM that the symlink should point at.

.EXAMPLE
    New-VmSymlink -SshClient $ssh -Path '/usr/local/bin/foo' -Target '/opt/foo/bin/foo'

.NOTES
    The on-VM commands run under sudo so the function can write to
    privileged locations regardless of which user the SSH client
    authenticated as. The caller is responsible for ensuring that user
    has password-less sudo.
#>
function New-VmSymlink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Target
    )

    # Host-side path validation. Both ends embed into a single-quoted
    # bash assignment in the emitted script, so a single quote in either
    # would break out of the quoting and let the value be interpreted as
    # shell syntax. NUL and `..` are rejected for the usual reasons
    # (truncation in C-string parsers, traversal). The validator
    # intentionally runs before any SSH call so malformed input never
    # touches the wire.
    foreach ($pair in @(@{ Name = 'Path'; Value = $Path }, @{ Name = 'Target'; Value = $Target })) {
        $name  = $pair.Name
        $value = $pair.Value
        if ([string]::IsNullOrEmpty($value)) {
            throw "New-VmSymlink: -$name must be a non-empty string."
        }
        if (-not $value.StartsWith('/')) {
            throw "New-VmSymlink: -$name '$value' must be an absolute path (start with '/')."
        }
        if ($value.Contains([char]0)) {
            throw "New-VmSymlink: -$name contains a NUL byte."
        }
        if ($value.Contains("'")) {
            throw "New-VmSymlink: -$name '$value' contains a single quote, which is not allowed."
        }
        $segments = $value.Split('/')
        if ($segments -contains '..') {
            throw "New-VmSymlink: -$name '$value' contains a '..' segment."
        }
    }

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }

    # EX_DATAERR from sysexits.h - used as the conflict signal so the
    # host layer can distinguish "wrong file type at Path" from generic
    # remote failures (which surface as their own exit codes).
    $conflictExitCode = 65

    $script = @"
set -e
path='$Path'
target='$Target'
if [ -L "`$path" ] && [ "`$(readlink "`$path")" = "`$target" ]; then
    exit 0
fi
if [ -e "`$path" ] || [ -L "`$path" ]; then
    if [ -L "`$path" ]; then
        echo "exists as symlink to `$(readlink "`$path")" >&2
    elif [ -d "`$path" ]; then
        echo "exists as directory" >&2
    elif [ -f "`$path" ]; then
        echo "exists as regular file" >&2
    else
        echo "exists as other (not a regular file, directory, or symlink)" >&2
    fi
    exit $conflictExitCode
fi
sudo ln -s "`$target" "`$path"
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # the rest of the module.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script

    if ($result.ExitStatus -eq 0) { return }

    if ($result.ExitStatus -eq $conflictExitCode) {
        throw ("New-VmSymlink: conflict at '$Path' on VM $vmHost - " +
            "$($result.Error.Trim()). Target was '$Target'.")
    }

    throw ("New-VmSymlink failed (vm: $vmHost, path: $Path, target: $Target, " +
        "exit $($result.ExitStatus)). stdout: $($result.Output)  stderr: $($result.Error)")
}
