<#
.SYNOPSIS
    Writes a managed block of system-wide environment variables to
    /etc/environment on a Hyper-V VM over SSH.

.DESCRIPTION
    Reconciles the contents of a sentinel-delimited "managed block"
    inside /etc/environment with the desired set of entries:

      # BEGIN <BlockName>
      NAME1="VAL1"
      NAME2="VAL2"
      # END <BlockName>

    The BlockName is supplied per call so two consumers wiring this
    transport into the same VM can coexist in one /etc/environment
    under their own independent blocks - a single shared sentinel
    would let the last writer wipe every other consumer's keys.

    Lines outside the managed block (Ubuntu's default PATH=..., any
    operator additions, other consumers' blocks) are preserved
    byte-for-byte. By default the function skips the write entirely
    when the existing block already matches the desired block; pass
    -NoSkipUnchanged to force a write even on a match (useful when
    recovering from out-of-band tampering or when the file's mtime
    is itself meaningful).

    The whole reconcile + strip + append + atomic-write sequence is one
    SSH round-trip, mirroring the discipline used by Copy-VmFiles. The
    write goes via a temp file in /etc plus mv, so /etc/environment is
    either the old version or the new version at every observable
    moment - never a partial write.

    Entries are validated against Assert-VmEnvVarsField before any SSH
    call is made (single source of truth for the schema), so malformed
    input fails on the host without touching the wire. An empty entries
    array is a valid intent meaning "remove the managed block"; lines
    outside the block are still preserved.

.PARAMETER SshClient
    A live Renci.SshNet.SshClient. The caller owns the client's
    lifecycle - Set-VmEnvironmentVariables neither connects nor
    disposes it.

.PARAMETER Entries
    Array of { name, value } entries (PSCustomObjects, as
    ConvertFrom-Json produces). Empty array is allowed and means
    "remove the managed block". See Assert-VmEnvVarsField for the
    exact rules; this function calls that validator before sending
    anything to the VM.

.PARAMETER BlockName
    The name embedded in the BEGIN / END sentinel markers. Lets
    multiple unrelated consumers maintain their own managed blocks
    inside the same /etc/environment without colliding. Same rules
    as the JSON-side blockName (see Assert-VmEnvVarsField); the
    transport re-validates host-side so direct callers that bypass
    the JSON validator cannot smuggle ' / newline / NUL into the
    marker assignment.

.PARAMETER NoSkipUnchanged
    Forces the always-write path. Off by default - the skip-unchanged
    path produces the same observable state at lower cost. Use this
    switch when the file mtime itself matters or when recovering from
    drift inside the managed block whose detection the caller wants to
    bypass.

.EXAMPLE
    Set-VmEnvironmentVariables -SshClient $ssh -BlockName 'ci-agent' -Entries @(
        [PSCustomObject]@{ name = 'FOO_HOME'; value = '/opt/foo' },
        [PSCustomObject]@{ name = 'BAR_OPTS'; value = '-Xmx512m' }
    )

.NOTES
    All on-VM commands run under sudo so the function can write
    /etc/environment regardless of which user the SSH client
    authenticated as. The caller is responsible for ensuring that
    user has password-less sudo (cloud-init's default admin user
    does).
#>
function Set-VmEnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Entries,

        [Parameter(Mandatory)]
        [string] $BlockName,

        [switch] $NoSkipUnchanged
    )

    # Re-validate BlockName host-side using the same rules as
    # Assert-VmEnvVarsField. Direct callers may legitimately bypass
    # the JSON validator (e.g. tests, ad-hoc scripts) but no caller
    # may inject characters that would break out of the marker's
    # single-quoted bash assignment.
    $blockNameRegex = '^[A-Za-z0-9._ -]+$'
    if ([string]::IsNullOrEmpty($BlockName)) {
        throw "Set-VmEnvironmentVariables: -BlockName must be a non-empty string."
    }
    if ($BlockName.Length -gt 128) {
        throw "Set-VmEnvironmentVariables: -BlockName length $($BlockName.Length) exceeds the 128-char limit."
    }
    if ($BlockName -notmatch $blockNameRegex) {
        throw "Set-VmEnvironmentVariables: -BlockName '$BlockName' contains a disallowed character (allowed: $blockNameRegex)."
    }
    if ($BlockName.Trim() -ne $BlockName) {
        throw "Set-VmEnvironmentVariables: -BlockName '$BlockName' must not start or end with whitespace."
    }

    # Validate via the shared schema rule set so the regex / duplicate
    # checks have a single source of truth. Skip the synthetic wrap on
    # the empty-array branch because "remove the block" is a valid
    # intent with no entries to validate.
    if ($Entries.Count -gt 0) {
        Assert-VmEnvVarsField -Vm ([PSCustomObject]@{
            envVars = [PSCustomObject]@{
                blockName = $BlockName
                entries   = $Entries
            }
        })
    }

    # Build the desired block CONTENT (no markers). The markers live
    # on the VM side as bash variables so the skip-unchanged compare
    # operates on content only - any future change to marker text
    # would otherwise re-write every existing VM once just to migrate
    # the wrapper.
    $contentLines = foreach ($entry in $Entries) {
        # Escape backslash first, then double-quote. Order matters: a
        # later backslash escape would re-escape the backslashes we
        # just emitted to escape the quotes. pam_env / bash both
        # parse "..." with these two escapes.
        $escaped = $entry.value.Replace('\', '\\').Replace('"', '\"')
        "$($entry.name)=`"$escaped`""
    }
    $desiredBlock = if ($contentLines) { ($contentLines -join "`n") } else { '' }

    $vmHost = if ($SshClient.PSObject.Properties['ConnectionInfo'] -and $SshClient.ConnectionInfo) {
        $SshClient.ConnectionInfo.Host
    } else { '(unknown)' }
    $namesList = if ($Entries.Count -gt 0) { (($Entries | ForEach-Object { $_.name }) -join ', ') } else { '(none)' }

    # The reconcile block (block-extract + byte-equality + early
    # exit 0) is the whole point of skip-unchanged. -NoSkipUnchanged
    # omits it entirely so the script always writes - matches the
    # shape Copy-VmFiles uses for the same switch.
    $reconcileBlock = if ($NoSkipUnchanged) { '' } else {
@'

EXISTING=$(printf '%s\n' "$CURRENT" | awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '$0==b{f=1;next} $0==e{f=0;next} f')
if [ "$EXISTING" = "$DESIRED" ]; then
    exit 0
fi
'@
    }

    # The atomic-write tail (temp file + chown + chmod + mv) is shared
    # with the other VM-install primitives (profile.d scripts, tarball
    # markers). It is generated by New-AtomicWriteBashFragment so the
    # single source of truth for the pattern lives in one place. The
    # caller's job is to compose the final file content into a single
    # bash variable (FILE_CONTENT below) before the fragment runs.
    $atomicWrite = New-AtomicWriteBashFragment `
        -TargetPath '/etc/environment' `
        -ContentVar 'FILE_CONTENT'

    # Heredoc delimiter is namespaced + uppercase so a NAME="VALUE"
    # line - whose name is restricted to POSIX identifiers by the
    # validator - can never collide with it and prematurely close
    # the heredoc.
    $script = @"
set -euo pipefail
TARGET=/etc/environment
BEGIN_MARKER='# BEGIN $BlockName'
END_MARKER='# END $BlockName'
DESIRED=`$(cat <<'__INFRA_HYPERV_DESIRED_BLOCK__'
$desiredBlock
__INFRA_HYPERV_DESIRED_BLOCK__
)
if [ -f "`$TARGET" ]; then
    CURRENT=`$(sudo cat "`$TARGET")
else
    CURRENT=""
fi
$reconcileBlock
STRIPPED=`$(printf '%s\n' "`$CURRENT" | awk -v b="`$BEGIN_MARKER" -v e="`$END_MARKER" 'BEGIN{f=0} f==0 && `$0==b{f=1;next} f==1 && `$0==e{f=0;next} f==0')
if [ -n "`$DESIRED" ]; then
    FILE_CONTENT=`$(printf '%s\n%s\n%s\n%s' "`$STRIPPED" "`$BEGIN_MARKER" "`$DESIRED" "`$END_MARKER")
else
    FILE_CONTENT="`$STRIPPED"
fi
$atomicWrite
"@

    # Windows PowerShell here-strings use CRLF; remote bash interprets
    # the trailing \r as part of the token. Normalise to LF, same as
    # Copy-VmFiles.
    $script = $script -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $script
    if ($result.ExitStatus -ne 0) {
        throw ("Set-VmEnvironmentVariables failed (vm: $vmHost, " +
            "block: $BlockName, names: $namesList, exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)")
    }
}
