# Integration tests for Set-VmProfileDScript against a real SSH target.
# See Initialize-DockerTargetEnvironment.ps1 for environment details.
#
# Unit tests already pin the emitted script shape (atomic-write fragment,
# heredoc delimiter, reconcile branch). This file proves the live shell
# round-trip: atomic write lands the file with the correct owner/mode,
# the skip-unchanged byte comparison genuinely suppresses writes, and
# content carrying shell metacharacters survives the heredoc transport.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    # Use a fixed Name across all It blocks so BeforeEach/AfterEach
    # cleanup needs only one target. /etc/profile.d/ is root-owned,
    # which exercises the sudo'd tee/chown/chmod/mv path the cmdlet
    # relies on.
    $Script:ScriptName = 'infra-integration-test'
    $Script:ScriptPath = "/etc/profile.d/$Script:ScriptName.sh"

    function Get-FileMeta {
        # %U:%G owner/group, %a octal mode. lstat-equivalent on a
        # regular file.
        return Invoke-SshQuery "stat -c '%U:%G %a' '$Script:ScriptPath'"
    }

    function Get-FileMtime {
        # Full-precision mtime ('%y' = "YYYY-MM-DD HH:MM:SS.nnnnnnnnn +ZZZZ")
        # so a re-write within the same second is still distinguishable
        # on filesystems that record nanosecond mtimes.
        return Invoke-SshQuery "stat -c '%y' '$Script:ScriptPath'"
    }

    function Get-FileContent {
        # /etc/profile.d/<name>.sh is 0644 root:root so plain cat (no
        # sudo) is enough, matching the read-back style used by
        # Set-VmEnvironmentVariables.Tests.ps1.
        return Invoke-SshQuery "cat '$Script:ScriptPath'"
    }

    function Get-FileSha {
        # Byte-exact comparator for content round-trip checks. cat
        # over Invoke-SshQuery is fine for printable ASCII, but for
        # round-trips through a heredoc we want a hash that does not
        # care about transport-layer trimming.
        return Invoke-SshQuery "sha256sum '$Script:ScriptPath' | awk '{print `$1}'"
    }

    function Test-FileExists {
        $rc = Invoke-SshQuery "test -f '$Script:ScriptPath' && echo yes || echo no"
        return ($rc -eq 'yes')
    }

    # Host-side SHA-256 of a string written exactly as the cmdlet would
    # write it (trailing newline appended if missing). Lets us compare
    # the on-VM file against the desired bytes without trusting cat to
    # preserve trailing whitespace through SSH.
    function Get-DesiredSha {
        param([string] $Content)
        $normalised = if ($Content.EndsWith("`n")) { $Content } else { "$Content`n" }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalised)
        $sha   = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($bytes)
            return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    }

    # See Set-VmEnvironmentVariables.Tests.ps1: 1.1s comfortably
    # distinguishes a write-induced mtime tick from a fast-replay no-op
    # on overlayfs (1s mtime resolution on some kernels).
    function Wait-ForMtimeTick { Start-Sleep -Milliseconds 1100 }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Set-VmProfileDScript (integration)' {

    BeforeEach {
        # Each It starts from "absent" so the first-run create path is
        # exercised explicitly when needed and not by side effect of a
        # prior test.
        Invoke-ContainerCommand "rm -f '$Script:ScriptPath'" | Out-Null
    }

    AfterEach {
        Invoke-ContainerCommand "rm -f '$Script:ScriptPath'" | Out-Null
    }

    It 'creates the script with root:root 0644 and byte-equal content on first run' {
        $content = "export FOO=1`n"

        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $content

        Test-FileExists | Should -BeTrue
        Get-FileMeta    | Should -Be 'root:root 644'

        # SHA over the cmdlet's expected on-disk bytes (with the
        # cmdlet's trailing-newline normalisation applied) proves the
        # atomic mv landed the right content, not just SOME content.
        Get-FileSha | Should -Be (Get-DesiredSha $content)
    }

    It 'is idempotent on an unchanged re-run (mtime stays put)' {
        $content = "export FOO=1`n"

        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $content
        $mtimeBefore = Get-FileMtime

        Wait-ForMtimeTick
        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $content

        # Same mtime before and after proves the reconcile branch
        # fired and the atomic-write tail did NOT run.
        Get-FileMtime | Should -Be $mtimeBefore
    }

    It '-NoSkipUnchanged forces a write (mtime advances; content unchanged)' {
        $content = "export FOO=1`n"

        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $content
        $mtimeBefore = Get-FileMtime
        $shaBefore   = Get-FileSha

        Wait-ForMtimeTick
        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $content `
                             -NoSkipUnchanged

        Get-FileMtime | Should -Not -Be $mtimeBefore
        Get-FileSha   | Should -Be     $shaBefore
    }

    It 'rewrites when the content changes (mtime advances; bytes match new desired)' {
        $first  = "export FOO=1`n"
        $second = "export FOO=2`nexport BAR=baz`n"

        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $first
        $mtimeBefore = Get-FileMtime

        Wait-ForMtimeTick
        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $second

        Get-FileMtime | Should -Not -Be $mtimeBefore
        Get-FileSha   | Should -Be     (Get-DesiredSha $second)
    }

    It 'preserves shell metacharacters in Content byte-for-byte' {
        # ' " $ \ all have meaning in bash. The cmdlet embeds Content
        # in a single-quoted heredoc precisely so none of them expand.
        # SHA comparison side-steps any concern about Invoke-SshQuery
        # trimming or re-encoding the bytes during read-back.
        $content = @"
export QUOTED='single ''with quotes'' inside'
export DQUOTED="double `"with quotes`" inside"
export DOLLAR=`$NOT_EXPANDED
export BACK=\path\with\backslashes
"@

        Set-VmProfileDScript -SshClient $Script:SshClient `
                             -Name      $Script:ScriptName `
                             -Content   $content

        Get-FileSha | Should -Be (Get-DesiredSha $content)
    }
}
