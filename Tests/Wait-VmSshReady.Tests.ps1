BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Ssh\Test-VmSshPort.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Ssh\Wait-VmSshReady.ps1"
}

Describe 'Wait-VmSshReady' {

    Context 'when Test-VmSshPort succeeds on the first probe' {

        It 'returns $true without sleeping' {
            Mock -CommandName Test-VmSshPort -MockWith { $true }
            Mock -CommandName Start-Sleep    -MockWith { }

            Wait-VmSshReady -IpAddress '10.0.0.1' -TimeoutSeconds 30 `
                | Should -BeTrue

            Should -Invoke Test-VmSshPort -Times 1 -Exactly
            Should -Invoke Start-Sleep    -Times 0 -Exactly
        }
    }

    Context 'when Test-VmSshPort eventually succeeds' {

        It 'returns $true after the probe flips, sleeping between attempts' {
            $Script:attempts = 0
            Mock -CommandName Test-VmSshPort -MockWith {
                $Script:attempts += 1
                # Flip to ready on the third probe so we can verify the
                # loop calls Test-VmSshPort more than once and sleeps
                # exactly (attempts - 1) times.
                return ($Script:attempts -ge 3)
            }
            Mock -CommandName Start-Sleep -MockWith { }

            Wait-VmSshReady -IpAddress '10.0.0.1' -TimeoutSeconds 30 `
                -PollIntervalSeconds 1 | Should -BeTrue

            Should -Invoke Test-VmSshPort -Times 3 -Exactly
            Should -Invoke Start-Sleep    -Times 2 -Exactly
        }
    }

    Context 'when the deadline expires before the port comes up' {

        It 'returns $false' {
            Mock -CommandName Test-VmSshPort -MockWith { $false }
            Mock -CommandName Start-Sleep    -MockWith { }

            # 0 s deadline means the while condition is false on entry, so
            # the loop body never runs and the function falls through to
            # return $false without any probes - a deterministic, fast test.
            Wait-VmSshReady -IpAddress '10.0.0.1' -TimeoutSeconds 0 `
                | Should -BeFalse
        }
    }
}
