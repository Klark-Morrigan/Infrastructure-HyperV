<#
.SYNOPSIS
    Removes a directory tree from a Hyper-V VM under sudo, gated by a
    hard-coded allowlist of safe parent prefixes.

.DESCRIPTION
    Single-round-trip primitive that runs `sudo rm -rf -- <Path>` on the
    VM after two host-side guards:

      1. Allowlist: <Path> must live under one of the prefixes in
         $script:RemoveVmDirectory_AllowedParentPrefixes. The trailing
         slash is part of the prefix, so /optimist does not match /opt.
      2. Denylist: <Path> must not be equal to any literal in
         $script:RemoveVmDirectory_DeniedPaths and must not be an
         ancestor of any such literal. The denylist is a defense in
         depth: most of these literals already fail the allowlist, but
         keeping them explicit makes the security-review boundary
         visible and survives any future allowlist extension.

    The cmdlet refuses to delete a non-directory at <Path> (regular
    file, symlink, other): the remote script exits 65 (EX_DATAERR) and
    the host layer surfaces a PowerShell exception. No-op when <Path>
    does not exist.

    Path is validated host-side before any SSH call: must be a
    non-empty absolute path with no `..` segments, no NUL byte, and no
    single quote (the remote script embeds it inside a single-quoted
    bash assignment).

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - this function neither connects nor disposes it.

.PARAMETER Path
    Absolute path on the VM of the directory tree to remove. Must live
    under an allowlisted parent prefix.

.EXAMPLE
    Remove-VmDirectory -SshClient $ssh -Path '/opt/jdk-21'

.NOTES
    The on-VM `rm -rf` runs under sudo so the function can delete
    directories in privileged locations regardless of which user the
    SSH client authenticated as. The caller is responsible for ensuring
    that user has password-less sudo. The allowlist is the security
    review for "this module can rm -rf on a VM" - any extension goes
    through code review on the script-scope constants below.
#>

# Hard-coded allowlist of parent prefixes under which Remove-VmDirectory
# is willing to operate. The trailing slash is required so /optimist
# does not match /opt. Extending this list is a security decision and
# must be reviewed.
$script:RemoveVmDirectory_AllowedParentPrefixes = @(
    '/opt/',
    '/var/lib/infra-provisioner/',
    '/usr/local/share/'
)

# Defense-in-depth denylist of paths that must never be removed even if
# the allowlist somehow admits them. A deletion target is rejected if
# it equals any of these literals or is an ancestor of one (because
# rm -rf on an ancestor would take the denylisted path with it).
$script:RemoveVmDirectory_DeniedPaths = @(
    '/',
    '/usr',
    '/usr/local',
    '/etc',
    '/home',
    '/var',
    '/var/lib',
    '/root',
    '/boot',
    '/lib',
    '/lib64',
    '/sbin',
    '/bin',
    '/proc',
    '/sys',
    '/dev',
    '/run',
    '/tmp'
)

function Remove-VmDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $Path
    )

    # Host-side validation. The validator runs before any SSH call so
    # malformed or out-of-policy input never touches the wire. The
    # single-quote rejection matches the rest of the module: <Path>
    # embeds into a single-quoted bash assignment in the emitted script.
    if ([string]::IsNullOrEmpty($Path)) {
        throw "Remove-VmDirectory: -Path must be a non-empty string."
    }
    if (-not $Path.StartsWith('/')) {
        throw "Remove-VmDirectory: -Path '$Path' must be an absolute path (start with '/')."
    }
    if ($Path.Contains([char]0)) {
        throw "Remove-VmDirectory: -Path contains a NUL byte."
    }
    if ($Path.Contains("'")) {
        throw "Remove-VmDirectory: -Path '$Path' contains a single quote, which is not allowed."
    }
    if ($Path.Split('/') -contains '..') {
        throw "Remove-VmDirectory: -Path '$Path' contains a '..' segment."
    }

    # Allowlist check. The trailing slash on each prefix is what
    # prevents /optimist from matching /opt - the StartsWith comparison
    # would otherwise admit any path that shared a prefix-as-string
    # with an allowlisted ancestor.
    $allowed = $false
    foreach ($prefix in $script:RemoveVmDirectory_AllowedParentPrefixes) {
        if ($Path.StartsWith($prefix)) { $allowed = $true; break }
    }
    if (-not $allowed) {
        throw ("Remove-VmDirectory: -Path '$Path' is outside the allowlist. " +
            "Allowed parent prefixes: " +
            ($script:RemoveVmDirectory_AllowedParentPrefixes -join ', ') + '.')
    }

    # Denylist check. Reject on exact match (deleting the protected
    # path directly) and on ancestor-of-protected (rm -rf on an
    # ancestor would take the protected path with it).
    foreach ($denied in $script:RemoveVmDirectory_DeniedPaths) {
        if ($Path -eq $denied) {
            throw "Remove-VmDirectory: -Path '$Path' is on the protected-paths denylist."
        }
        if ($denied.StartsWith($Path + '/')) {
            throw ("Remove-VmDirectory: -Path '$Path' is an ancestor of the " +
                "protected path '$denied'.")
        }
    }

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }

    # EX_DATAERR from sysexits.h - same conflict signal the rest of
    # the install-primitive family uses for "wrong file type at Path".
    $conflictExitCode = 65

    $script = @"
set -e
path='$Path'
if [ ! -e "`$path" ] && [ ! -L "`$path" ]; then
    exit 0
fi
if [ ! -d "`$path" ] || [ -L "`$path" ]; then
    if [ -L "`$path" ]; then
        echo "exists as symlink" >&2
    elif [ -f "`$path" ]; then
        echo "exists as regular file" >&2
    else
        echo "exists as other (not a directory)" >&2
    fi
    exit $conflictExitCode
fi
sudo rm -rf -- "`$path"
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # the rest of the module.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script

    if ($result.ExitStatus -eq 0) { return }

    if ($result.ExitStatus -eq $conflictExitCode) {
        throw ("Remove-VmDirectory: conflict at '$Path' on VM $vmHost - " +
            "$($result.Error.Trim()) (refusing to remove a non-directory).")
    }

    throw ("Remove-VmDirectory failed (vm: $vmHost, path: $Path, " +
        "exit $($result.ExitStatus)). stdout: $($result.Output)  stderr: $($result.Error)")
}
