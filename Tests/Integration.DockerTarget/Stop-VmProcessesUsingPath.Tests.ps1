# Integration tests for Stop-VmProcessesUsingPath against a real SSH
# target. See Initialize-DockerTargetEnvironment.ps1 for environment
# details.
#
# Unit tests already pin the emitted script shape and the host-side
# parameter validation. This file proves the two-stage TERM-then-KILL
# escalation, the structured result, and the scanner-fallback chain
# behave against real processes - none of which can be exercised
# without a live VM-side run.
#
# Extra setup vs the shared init:
#   - The base SSH test image carries openssh + sudo + curl only. This
#     suite needs lsof (primary scanner) and fuser (psmisc, the second
#     fallback). Both are apt-installed in BeforeAll, scoped to this
#     file so other suites do not pay the install cost.
#   - The shared sudoers file grants NOPASSWD on a precise set of
#     binaries (mkdir/curl/chown/chmod/...). The cmdlet under test also
#     invokes lsof, fuser, kill, readlink, and awk under sudo, so this
#     suite layers a supplemental sudoers.d entry that adds exactly
#     those binaries - the precise-grant style is preserved.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    $Script:ProcDir    = '/opt/integration-test-process-dir'
    $Script:OutsideDir = '/opt/integration-test-process-outside'
    # Distinctive token embedded in every fixture command line so the
    # AfterEach pkill can reliably reap survivors without matching
    # unrelated bash/sleep processes in the container.
    $Script:FixtureTag = 'integration-test-stop-procs-fixture'

    # ---------------------------------------------------------------
    # 1. apt-install lsof + psmisc
    #    psmisc provides /usr/bin/fuser (the second-tier scanner). lsof
    #    is the first-tier scanner. The proc-walk last-resort needs
    #    nothing beyond coreutils and is exercised indirectly when both
    #    lsof and fuser are unavailable - we do not assert on that
    #    branch here (unit tests cover the emitted script's shape).
    # ---------------------------------------------------------------

    $aptOutput = Invoke-ContainerCommand `
        "DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends lsof psmisc >/dev/null 2>&1 && echo OK || echo FAIL"
    if ($aptOutput -notmatch 'OK') {
        throw ("Failed to install lsof + psmisc in the test container. " +
            "Output: $aptOutput")
    }

    # ---------------------------------------------------------------
    # 2. Supplemental sudoers entry
    #    Layered as a second file under sudoers.d so the shared init's
    #    file remains untouched. Same root:root 0440 + visudo check as
    #    the primary file.
    # ---------------------------------------------------------------

    $extraSudoersPath    = "/etc/sudoers.d/${Script:DeployUser}-stop-procs"
    $extraSudoersContent = @"
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/lsof
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/fuser
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/kill
${Script:DeployUser} ALL=(root) NOPASSWD: /bin/kill
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/readlink
${Script:DeployUser} ALL=(root) NOPASSWD: /usr/bin/awk
"@ -replace "`r`n", "`n"

    $extraSudoersTempFile = Join-Path ([System.IO.Path]::GetTempPath()) `
        "infra-t-sudoers-stop-procs-$(New-Guid)"
    [System.IO.File]::WriteAllText(
        $extraSudoersTempFile, $extraSudoersContent,
        [System.Text.UTF8Encoding]::new($false))

    try {
        docker cp $extraSudoersTempFile "${Script:ContainerName}:${extraSudoersPath}" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "docker cp of supplemental sudoers file failed (exit $LASTEXITCODE)."
        }
    }
    finally {
        Remove-Item -LiteralPath $extraSudoersTempFile -Force -ErrorAction SilentlyContinue
    }

    Invoke-ContainerCommand "chown root:root '$extraSudoersPath' && chmod 0440 '$extraSudoersPath'" | Out-Null

    $visudoCheck = docker exec $Script:ContainerName visudo -cf $extraSudoersPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("Supplemental sudoers file failed syntax check:`n" +
               ($visudoCheck -join "`n"))
    }

    # ---------------------------------------------------------------
    # 3. Helpers
    # ---------------------------------------------------------------

    function Start-FixtureProcess {
        # Spawns a detached bash process inside $WorkingDir whose
        # first act is to record its own PID into a marker file.
        # Returns that recorded PID. -TrapTerm wraps the bash in an
        # ignoring SIGTERM + while-sleep loop so SIGKILL is required
        # to reap the parent.
        #
        # The persistent bash writes its own `$$` into a per-call
        # marker file rather than relying on `$!` from the launching
        # shell. `$!` is unreliable here because the docker exec
        # spawn chain (outer bash -> `(cd && nohup bash -c '...') &`
        # subshell -> nohup exec -> inner bash) involves at least one
        # fork plus exec optimisation that can shift the surviving
        # PID by one slot under tini's allocator. The bash that
        # actually persists is the only authority on its own PID, so
        # we have it self-report.
        #
        # The fixture body is multi-statement so bash does NOT
        # exec-optimise away (we need the long-running parent for
        # the SIGTERM-trap scenarios, and a stable cwd-anchored
        # process for the SIGTERM-respecting scenarios).
        param(
            [Parameter(Mandatory)] [string] $WorkingDir,
            [switch]               $TrapTerm
        )
        $token      = "$Script:FixtureTag-$(New-Guid)"
        $markerPath = "/tmp/pid-$token"
        # Trap body uses double quotes inside the script so the
        # surrounding single-quoted `bash -c '...'` arg stays
        # quote-balanced. The trailing-wait shape of the non-trap
        # body keeps bash present as the parent rather than letting
        # it exec-optimise into the sleep child.
        $body = if ($TrapTerm) {
            'trap "" TERM; while :; do sleep 1; done'
        } else {
            'sleep 600 & wait'
        }
        # Inner bash -c argument is single-quoted on the wire so $$
        # is NOT expanded by the outer container bash (docker exec's
        # shell) - it must reach the inner bash literally so the
        # marker file records the inner bash's PID, which is the
        # process the cmdlet's scanner will find via cwd.
        $script = "echo `$`$ > $markerPath; $body"
        $cmd    = "cd '$WorkingDir' && nohup bash -c '$script' </dev/null >/dev/null 2>&1 & disown"
        Invoke-ContainerCommand $cmd | Out-Null

        # Marker write happens as bash's first statement, so a tight
        # bounded poll is plenty (typically a single iteration).
        $deadline = (Get-Date).AddSeconds(2)
        $pidStr   = ''
        while ((Get-Date) -lt $deadline) {
            $pidStr = (Invoke-ContainerCommand "cat $markerPath 2>/dev/null" |
                Out-String).Trim()
            if ($pidStr -match '^\d+$') { break }
            Start-Sleep -Milliseconds 50
        }
        if (-not ($pidStr -match '^\d+$')) {
            throw "Start-FixtureProcess: marker file '$markerPath' was not written."
        }
        Invoke-ContainerCommand "rm -f $markerPath" | Out-Null
        return [int] $pidStr
    }

    function Test-PidAlive {
        param([Parameter(Mandatory)] [int] $ProcessId)
        # /proc test runs unsudoed; the deploy user can stat any PID
        # directory regardless of owner.
        $rc = Invoke-SshQuery "test -d /proc/$ProcessId && echo yes || echo no"
        return ($rc -eq 'yes')
    }

    function Stop-FixtureProcesses {
        # Reap any survivors from a previous test - pgrep by command
        # line so we never touch unrelated processes. Failure is
        # tolerated (no fixtures left is the steady state).
        Invoke-ContainerCommand "pkill -KILL -f '$Script:FixtureTag' 2>/dev/null; true" | Out-Null
        # Brief wait for the kernel to reap so subsequent /proc checks
        # do not race the cleanup.
        Start-Sleep -Milliseconds 200
    }
}

AfterAll {
    # Best-effort cleanup of any straggler fixture processes before the
    # container is torn down. The init's Remove- cleanup will drop the
    # container anyway, but reaping first keeps the apt cache and the
    # sudoers state in a sane shape if a future change keeps the
    # container around.
    Invoke-ContainerCommand "pkill -KILL -f '$Script:FixtureTag' 2>/dev/null; true" | Out-Null

    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Stop-VmProcessesUsingPath (integration)' {

    BeforeEach {
        Stop-FixtureProcesses
        Invoke-ContainerCommand "rm -rf '$Script:ProcDir' '$Script:OutsideDir' && mkdir -p '$Script:ProcDir' '$Script:OutsideDir'" |
            Out-Null
    }

    AfterEach {
        Stop-FixtureProcesses
        Invoke-ContainerCommand "rm -rf '$Script:ProcDir' '$Script:OutsideDir'" | Out-Null
    }

    It 'returns three empty arrays when no process holds the path' {
        $result = Stop-VmProcessesUsingPath -SshClient    $Script:SshClient `
                                            -Path         $Script:ProcDir `
                                            -GraceSeconds 1

        $result                       | Should -Not -BeNullOrEmpty
        @($result.TerminatedPids).Count | Should -Be 0
        @($result.KilledPids).Count     | Should -Be 0
        @($result.StillAlive).Count     | Should -Be 0
    }

    It 'classifies a SIGTERM-respecting process as terminated' {
        $fixturePid = Start-FixtureProcess -WorkingDir $Script:ProcDir
        # Race guard: ensure /proc/<pid> is populated before the
        # scanner runs so the cwd symlink resolves.
        Test-PidAlive -ProcessId $fixturePid | Should -BeTrue

        $result = Stop-VmProcessesUsingPath -SshClient    $Script:SshClient `
                                            -Path         $Script:ProcDir `
                                            -GraceSeconds 3

        # The fixture's outer bash + the inner sleep both inherit cwd
        # = $ProcDir, so both PIDs may surface. We only assert the
        # ones we care about: the outer bash exits cleanly under
        # SIGTERM (no trap on this fixture) and lands in Terminated;
        # nothing should require SIGKILL.
        @($result.StillAlive).Count | Should -Be 0
        @($result.KilledPids).Count | Should -Be 0
        $result.TerminatedPids      | Should -Contain $fixturePid
        Test-PidAlive -ProcessId $fixturePid | Should -BeFalse
    }

    It 'escalates a SIGTERM-ignoring process to SIGKILL' {
        $fixturePid = Start-FixtureProcess -WorkingDir $Script:ProcDir -TrapTerm
        Test-PidAlive -ProcessId $fixturePid | Should -BeTrue

        $result = Stop-VmProcessesUsingPath -SshClient    $Script:SshClient `
                                            -Path         $Script:ProcDir `
                                            -GraceSeconds 2

        # The outer bash ignores SIGTERM and must be SIGKILL'd. The
        # transient `sleep 1` child it spawns has no trap and exits
        # under SIGTERM, so it may appear in Terminated; we only
        # assert on the trapping PID we explicitly captured.
        @($result.StillAlive).Count | Should -Be 0
        $result.KilledPids          | Should -Contain $fixturePid
        Test-PidAlive -ProcessId $fixturePid | Should -BeFalse
    }

    It 'leaves processes outside the path untouched' {
        $insidePid  = Start-FixtureProcess -WorkingDir $Script:ProcDir
        $outsidePid = Start-FixtureProcess -WorkingDir $Script:OutsideDir
        Test-PidAlive -ProcessId $insidePid  | Should -BeTrue
        Test-PidAlive -ProcessId $outsidePid | Should -BeTrue

        $result = Stop-VmProcessesUsingPath -SshClient    $Script:SshClient `
                                            -Path         $Script:ProcDir `
                                            -GraceSeconds 3

        @($result.StillAlive).Count | Should -Be 0
        # Outside-dir PID must not appear in any classification list:
        # negative coverage that the scanner did not over-reach.
        $result.TerminatedPids      | Should -Not -Contain $outsidePid
        $result.KilledPids          | Should -Not -Contain $outsidePid
        Test-PidAlive -ProcessId $outsidePid | Should -BeTrue
    }

    It 'with -GraceSeconds 0 a SIGTERM-ignoring process goes straight to killed' {
        $fixturePid = Start-FixtureProcess -WorkingDir $Script:ProcDir -TrapTerm
        Test-PidAlive -ProcessId $fixturePid | Should -BeTrue

        $result = Stop-VmProcessesUsingPath -SshClient    $Script:SshClient `
                                            -Path         $Script:ProcDir `
                                            -GraceSeconds 0

        @($result.StillAlive).Count | Should -Be 0
        $result.KilledPids          | Should -Contain $fixturePid
        Test-PidAlive -ProcessId $fixturePid | Should -BeFalse
    }

    It 'falls back to the /proc walk when both lsof and fuser are unavailable' {
        # Mask the first two scanner tiers at the binary level so the
        # script's `command -v` checks fail and the proc-walk tier
        # runs end-to-end against the same fixture shape as the
        # SIGTERM-respecting scenario. fuser is masked alongside lsof
        # because `fuser -m PATH` on Linux promotes a directory inside
        # a mount to the entire mount, returning every process on the
        # rootfs (PID 1 included) - useful coverage for the cmdlet's
        # last-resort tier, not for the second one (the cmdlet's
        # fuser invocation is tracked as a known coarseness issue
        # against an in-tree directory). The restore in finally is
        # idempotent so a failed assertion does not poison subsequent
        # test files that share the container.
        Invoke-ContainerCommand 'mv /usr/bin/lsof /usr/bin/lsof.disabled && mv /usr/bin/fuser /usr/bin/fuser.disabled' |
            Out-Null
        try {
            $fixturePid = Start-FixtureProcess -WorkingDir $Script:ProcDir
            Test-PidAlive -ProcessId $fixturePid | Should -BeTrue

            $result = Stop-VmProcessesUsingPath -SshClient    $Script:SshClient `
                                                -Path         $Script:ProcDir `
                                                -GraceSeconds 3

            @($result.StillAlive).Count | Should -Be 0
            $result.TerminatedPids      | Should -Contain $fixturePid
            Test-PidAlive -ProcessId $fixturePid | Should -BeFalse
        }
        finally {
            Invoke-ContainerCommand 'test -e /usr/bin/lsof.disabled && mv /usr/bin/lsof.disabled /usr/bin/lsof || true ; test -e /usr/bin/fuser.disabled && mv /usr/bin/fuser.disabled /usr/bin/fuser || true' |
                Out-Null
        }
    }
}
