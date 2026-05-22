<#
.SYNOPSIS
    Generates the bash fragment for an atomic write of a file on a Linux
    VM under sudo (temp file + chown + chmod + mv).

.DESCRIPTION
    Code generator used by VM-install primitives that need to drop a file
    in place without an observable partial-write window. The emitted
    fragment assumes the enclosing script already runs under
    `set -euo pipefail` and that the bash variable named by -ContentVar
    has been defined earlier in the same script. The fragment writes the
    content to a sibling temp file (so the final `mv` is on the same
    filesystem, hence atomic at the directory-entry level), sets owner
    and mode on the temp file, then renames it over the target.

    The helper centralises a five-line pattern that previously lived
    inline in Set-VmEnvironmentVariables and is also needed by the
    profile.d and tarball-marker primitives. Three call sites is the
    threshold where a single source of truth wins over inlining: a
    future hardening (better tempfile naming, pipefail propagation,
    etc.) lands in one place.

    This is a private helper - it emits a string, it does not touch
    SSH. Validation here is anti-typo, not security: callers are
    trusted code in the same module, not user input. Anything that
    looks malformed throws before a single byte is emitted.

.PARAMETER TargetPath
    Absolute POSIX path of the file to write. No `..` segments, no NUL.

.PARAMETER ContentVar
    Name (no leading $) of the bash variable that holds the desired
    file content in the enclosing script. POSIX identifier rules apply
    (^[A-Za-z_][A-Za-z0-9_]*$) so the substitution cannot smuggle
    `$()` / backticks / spaces into the emitted printf invocation.

.PARAMETER Owner
    Owner spec passed to chown (e.g. 'root:root'). Restricted to
    POSIX-name:POSIX-name form.

.PARAMETER Mode
    Mode passed to chmod, in octal-with-leading-zero form (e.g. '0644').

.PARAMETER TempDir
    Directory in which to create the temp file. Defaults to the
    parent directory of TargetPath so the final rename stays on the
    same filesystem (atomic-rename requirement).

.EXAMPLE
    $fragment = New-AtomicWriteBashFragment -TargetPath '/etc/profile.d/foo.sh' `
                                            -ContentVar 'DESIRED'
    # Then embed $fragment after a `DESIRED=$(cat <<'EOF' ... EOF)` block.

.NOTES
    Not exported from the module. Dot-sourced by Infrastructure.HyperV.psm1
    under Private\Bash so callers inside the module pick it up; outside
    callers see no surface change.
#>
function New-AtomicWriteBashFragment {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TargetPath,

        [Parameter(Mandatory)]
        [string] $ContentVar,

        [string] $Owner = 'root:root',

        [string] $Mode = '0644',

        [string] $TempDir
    )

    # TargetPath: absolute POSIX path, no traversal, no NUL.
    if ([string]::IsNullOrEmpty($TargetPath)) {
        throw "New-AtomicWriteBashFragment: -TargetPath must be a non-empty string."
    }
    if (-not $TargetPath.StartsWith('/')) {
        throw "New-AtomicWriteBashFragment: -TargetPath '$TargetPath' must be absolute (start with '/')."
    }
    if ($TargetPath.Contains([char]0)) {
        throw "New-AtomicWriteBashFragment: -TargetPath contains a NUL byte."
    }
    if ($TargetPath.Split('/') -contains '..') {
        throw "New-AtomicWriteBashFragment: -TargetPath '$TargetPath' contains a '..' segment."
    }

    # ContentVar: POSIX identifier. The value is interpolated directly
    # into a `"$NAME"` reference in the emitted printf - a space or `$`
    # in it would corrupt the resulting bash.
    if ($ContentVar -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw ("New-AtomicWriteBashFragment: -ContentVar '$ContentVar' is not a POSIX " +
            "identifier (^[A-Za-z_][A-Za-z0-9_]*`$).")
    }

    # Owner: <user>:<group>, each a POSIX name (lowercase letters /
    # digits / underscore / hyphen, not starting with a digit / hyphen).
    if ($Owner -notmatch '^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$') {
        throw "New-AtomicWriteBashFragment: -Owner '$Owner' is not a valid 'user:group' spec."
    }

    # Mode: octal with leading zero, three or four digits, no 8/9.
    if ($Mode -notmatch '^0[0-7]{3,4}$') {
        throw "New-AtomicWriteBashFragment: -Mode '$Mode' is not a valid octal mode (e.g. '0644')."
    }

    # Default TempDir is the target's parent directory: same filesystem,
    # so `mv` is atomic at the directory-entry level. Splitting on '/'
    # by hand because Split-Path's behaviour on Windows is backslash-aware
    # and would mis-handle POSIX paths.
    $lastSlash = $TargetPath.LastIndexOf('/')
    $targetDir = if ($lastSlash -le 0) { '/' } else { $TargetPath.Substring(0, $lastSlash) }
    $basename  = $TargetPath.Substring($lastSlash + 1)
    if ([string]::IsNullOrEmpty($basename)) {
        throw "New-AtomicWriteBashFragment: -TargetPath '$TargetPath' has no file name component."
    }

    $effectiveTempDir = if ($PSBoundParameters.ContainsKey('TempDir')) {
        if ([string]::IsNullOrEmpty($TempDir)) {
            throw "New-AtomicWriteBashFragment: -TempDir must be a non-empty string when supplied."
        }
        if (-not $TempDir.StartsWith('/')) {
            throw "New-AtomicWriteBashFragment: -TempDir '$TempDir' must be absolute (start with '/')."
        }
        if ($TempDir.Contains([char]0)) {
            throw "New-AtomicWriteBashFragment: -TempDir contains a NUL byte."
        }
        if ($TempDir.Split('/') -contains '..') {
            throw "New-AtomicWriteBashFragment: -TempDir '$TempDir' contains a '..' segment."
        }
        $TempDir
    } else { $targetDir }

    # Strip any trailing slash from the temp dir so the emitted path has
    # exactly one separator between dir and basename.
    if ($effectiveTempDir.Length -gt 1 -and $effectiveTempDir.EndsWith('/')) {
        $effectiveTempDir = $effectiveTempDir.TrimEnd('/')
    }

    # Output: five-line fragment. No trailing newline so the caller
    # controls how it joins this into the enclosing script.
    @"
TMP="$effectiveTempDir/$basename.tmp.`$`$"
printf '%s\n' "`$$ContentVar" | sudo tee "`$TMP" >/dev/null
sudo chown $Owner "`$TMP"
sudo chmod $Mode "`$TMP"
sudo mv "`$TMP" "$TargetPath"
"@ -replace "`r`n", "`n"
}
