# Integration tests for Copy-VmFiles' skip-unchanged path against a real
# SSH target. See Initialize-DockerTargetEnvironment.ps1 for environment
# details.
#
# Each It block writes one host source file and ships it to the VM via
# Copy-VmFiles. The reconcile-or-write behaviour is observed indirectly
# through the target's mtime: an unchanged re-run must leave it untouched
# (the reconcile block short-circuited before any sudo write), and any
# drift dimension - content, owner, mode - must advance it (the write
# block ran and re-applied the requested state). Unit tests already pin
# the emitted script shape; this file proves the script actually does
# the right thing end-to-end.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    # Helpers live in BeforeAll, not inside Describe. Pester 5 runs the
    # Describe body in a discovery pass that does not execute nested
    # `function` statements, so an `It` referencing them at run time would
    # see "CommandNotFoundException".
    function Get-VmFileMtime {
        # %y is the full nanosecond-precision modification timestamp. We
        # compare it as a string between runs; any byte difference means
        # the kernel observed a write. Plain stat (no sudo) is enough -
        # the parent dir is 0755 so any user can stat children.
        return Invoke-SshQuery "stat -c '%y' '$Script:VmTargetPath'"
    }

    function Invoke-Copy {
        param([switch] $NoSkipUnchanged)

        $entry = @{
            Source = $Script:HostSourcePath
            Target = $Script:VmTargetPath
            Owner  = $Script:DesiredOwner
            Mode   = $Script:DesiredMode
        }
        $params = @{
            SshClient = $Script:SshClient
            Server    = $Script:FileServer
            Entries   = @($entry)
        }
        if ($NoSkipUnchanged) { $params['NoSkipUnchanged'] = $true }
        Copy-VmFiles @params
    }

    # Some filesystems clamp mtime granularity coarser than the kernel's
    # nanosecond clock (overlayfs on older kernels has done this). A short
    # sleep between runs guarantees a write-induced mtime change is
    # distinguishable from "the second run happened so fast that mtime
    # didn't tick." 1.1s comfortably exceeds 1-second granularity.
    function Wait-ForMtimeTick { Start-Sleep -Milliseconds 1100 }

    function Set-HostSource {
        param([Parameter(Mandatory)][string] $Content)
        # WriteAllText with explicit UTF-8 (no BOM) writes the bytes
        # verbatim - no trailing newline, no encoding surprise. We avoid
        # `Set-Content -NoNewline` with pipeline input here because that
        # combination has produced 0-byte files on PS 7 / Linux runners,
        # which silently broke the SHA-256 reconcile path. Same reasoning
        # the BeforeAll uses for the sudoers file (see
        # Initialize-DockerTargetEnvironment.ps1 step 3).
        [System.IO.File]::WriteAllText(
            $Script:HostSourcePath, $Content,
            [System.Text.UTF8Encoding]::new($false))
    }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Copy-VmFiles -SkipUnchanged (integration)' {

    BeforeEach {
        # Per-test directories isolate scenarios. New-Guid guards against
        # any cross-test pollution if Pester reruns within the same Describe.
        $Script:CaseId      = (New-Guid).Guid
        $Script:HostCaseDir = Join-Path $Script:HostSourceRoot $Script:CaseId
        New-Item -ItemType Directory -Path $Script:HostCaseDir -Force | Out-Null

        $Script:VmTargetDir  = "/tmp/copy-vmfiles-skipunchanged-$Script:CaseId"
        $Script:VmTargetPath = "$Script:VmTargetDir/payload.txt"
        # Target dir is created by Copy-VmFiles' mkdir -p step under sudo;
        # we don't pre-create it here so the first-run mkdir actually runs.

        $Script:HostSourcePath = Join-Path $Script:HostCaseDir 'payload.txt'

        # Owner = runner user so the deploy user (which we drive sudo as)
        # is distinguishable from the file owner in the owner-drift case.
        $Script:DesiredOwner = "$Script:RunnerUser`:$Script:RunnerUser"
        $Script:DesiredMode  = '0644'
    }

    AfterEach {
        Invoke-SshQuery "sudo rm -rf '$Script:VmTargetDir'" | Out-Null
        if (Test-Path -LiteralPath $Script:HostCaseDir) {
            Remove-Item -LiteralPath $Script:HostCaseDir -Recurse -Force
        }
    }

    # Scenarios ------------------------------------------------------------

    It 'lands the file with requested content, owner and mode on first run' {
        Set-HostSource -Content 'first-run-content'

        Invoke-Copy

        # Plain cat/stat (no sudo): Copy-VmFiles writes 0644 inside a
        # 0755-by-default parent created by `sudo mkdir -p`, so any user
        # on the VM can traverse + read. Avoids needing /usr/bin/cat in
        # the test sudoers - a much broader grant than the test needs.
        $content = Invoke-SshQuery "cat '$Script:VmTargetPath'"
        $content | Should -Be 'first-run-content'

        $meta = Invoke-SshQuery "stat -c '%U:%G %a' '$Script:VmTargetPath'"
        $meta | Should -Be "$Script:DesiredOwner 644"
    }

    It 'skips the VM-side write on an identical re-run (mtime unchanged)' {
        Set-HostSource -Content 'unchanged'
        Invoke-Copy
        $mtimeBefore = Get-VmFileMtime

        Wait-ForMtimeTick
        Invoke-Copy

        $mtimeAfter = Get-VmFileMtime
        $mtimeAfter | Should -Be $mtimeBefore
    }

    It 're-writes when the host source content changes' {
        Set-HostSource -Content 'short'
        Invoke-Copy
        $mtimeBefore = Get-VmFileMtime

        Wait-ForMtimeTick
        # Distinct byte count so Add-VmFileServerFile's name+size
        # idempotency check re-stages the new bytes rather than serving
        # the original staged copy.
        Set-HostSource -Content 'much-longer-replacement-content'
        Invoke-Copy

        $mtimeAfter = Get-VmFileMtime
        $mtimeAfter | Should -Not -Be $mtimeBefore

        $content = Invoke-SshQuery "cat '$Script:VmTargetPath'"
        $content | Should -Be 'much-longer-replacement-content'
    }

    It 're-applies the requested owner when the VM file has been chowned away' {
        Set-HostSource -Content 'owner-drift'
        Invoke-Copy
        $mtimeBefore = Get-VmFileMtime

        # Out-of-band drift: deploy user (NOPASSWD chown) reassigns owner
        # to root:root, simulating a manual fix-up on the VM.
        Invoke-SshQuery "sudo chown root:root '$Script:VmTargetPath'" | Out-Null

        Wait-ForMtimeTick
        Invoke-Copy

        $meta = Invoke-SshQuery "stat -c '%U:%G' '$Script:VmTargetPath'"
        $meta | Should -Be $Script:DesiredOwner

        $mtimeAfter = Get-VmFileMtime
        $mtimeAfter | Should -Not -Be $mtimeBefore
    }

    It 're-applies the requested mode when the VM file has been chmoded away' {
        Set-HostSource -Content 'mode-drift'
        Invoke-Copy
        $mtimeBefore = Get-VmFileMtime

        # Drift the mode to a value the reconcile block will not accept.
        # 0600 differs from the entry's '0644' as an octal number, which
        # is how the remote script compares them.
        Invoke-SshQuery "sudo chmod 0600 '$Script:VmTargetPath'" | Out-Null

        Wait-ForMtimeTick
        Invoke-Copy

        $mode = Invoke-SshQuery "stat -c '%a' '$Script:VmTargetPath'"
        $mode | Should -Be '644'

        $mtimeAfter = Get-VmFileMtime
        $mtimeAfter | Should -Not -Be $mtimeBefore
    }

    It '-NoSkipUnchanged forces a re-write even when nothing changed' {
        Set-HostSource -Content 'forced'
        Invoke-Copy
        $mtimeBefore = Get-VmFileMtime

        Wait-ForMtimeTick
        Invoke-Copy -NoSkipUnchanged

        $mtimeAfter = Get-VmFileMtime
        $mtimeAfter | Should -Not -Be $mtimeBefore
    }
}
