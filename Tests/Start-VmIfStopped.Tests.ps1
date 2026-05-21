BeforeAll {
    # Dot-source the private guard first so Mock can bind to it from the
    # public function's scope; Start-VmIfStopped calls it by name.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\PsModules\Assert-PsModuleLoaded.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Power\Assert-HyperVModuleLoaded.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\Power\Start-VmIfStopped.ps1"

    # The Hyper-V module is not assumed to be installed on the test host
    # (CI runs on Linux). Define no-op stubs for the cmdlets so Pester's
    # Mock can bind to them; tests override per-context.
    function Get-VM   { param([string]$Name) }
    function Start-VM { param([string]$Name) }
}

Describe 'Start-VmIfStopped' {

    # ------------------------------------------------------------------
    Context 'call ordering and guard propagation' {
    # ------------------------------------------------------------------

        It 'invokes Assert-HyperVModuleLoaded before Get-VM' {
            $Script:calls = @()
            Mock Assert-HyperVModuleLoaded { $Script:calls += 'guard' }
            Mock Get-VM   { $Script:calls += 'get'; [PSCustomObject]@{ State = 'Running' } }
            Mock Start-VM {}

            Start-VmIfStopped -VmName 'vm1' | Out-Null

            $Script:calls | Should -Be @('guard', 'get')
        }

        It 'propagates a guard failure without calling Get-VM or Start-VM' {
            Mock Assert-HyperVModuleLoaded { throw 'guard exploded' }
            Mock Get-VM   {}
            Mock Start-VM {}

            { Start-VmIfStopped -VmName 'vm1' } |
                Should -Throw -ExpectedMessage '*guard exploded*'

            Should -Invoke Get-VM   -Times 0 -Exactly
            Should -Invoke Start-VM -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'when the VM is Off' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-HyperVModuleLoaded {}
            Mock Get-VM   { [PSCustomObject]@{ State = 'Off' } }
            Mock Start-VM {}
        }

        It 'invokes Start-VM exactly once with -Name $VmName' {
            Start-VmIfStopped -VmName 'vm-off' | Out-Null

            Should -Invoke Start-VM -Times 1 -Exactly `
                -ParameterFilter { $Name -eq 'vm-off' }
        }

        It 'returns { VmName, EntryState=Off, Action=Started }' {
            $result = Start-VmIfStopped -VmName 'vm-off'

            $result.VmName     | Should -Be 'vm-off'
            $result.EntryState | Should -Be 'Off'
            $result.Action     | Should -Be 'Started'
        }

        It 'emits exactly one verbose line naming the transition' {
            # @(...) forces array semantics: Where-Object returns a scalar
            # when one item matches, and `.Count` on the scalar throws under
            # Set-StrictMode 'Latest'. See feedback_pester5_single_match_count.
            $verbose = @(Start-VmIfStopped -VmName 'vm-off' -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })

            $verbose.Count       | Should -Be 1
            $verbose[0].Message  | Should -BeLike '*vm-off*Off*Started*'
        }
    }

    # ------------------------------------------------------------------
    Context 'when the VM is Saved' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-HyperVModuleLoaded {}
            Mock Get-VM   { [PSCustomObject]@{ State = 'Saved' } }
            Mock Start-VM {}
        }

        It 'invokes Start-VM exactly once with -Name $VmName' {
            Start-VmIfStopped -VmName 'vm-saved' | Out-Null

            Should -Invoke Start-VM -Times 1 -Exactly `
                -ParameterFilter { $Name -eq 'vm-saved' }
        }

        It 'returns { VmName, EntryState=Saved, Action=Resumed }' {
            $result = Start-VmIfStopped -VmName 'vm-saved'

            $result.VmName     | Should -Be 'vm-saved'
            $result.EntryState | Should -Be 'Saved'
            $result.Action     | Should -Be 'Resumed'
        }

        It 'emits exactly one verbose line naming the transition' {
            # @(...) forces array semantics; Where-Object returns a scalar
            # on a single match and `.Count` blows up under strict mode.
            $verbose = @(Start-VmIfStopped -VmName 'vm-saved' -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })

            $verbose.Count       | Should -Be 1
            $verbose[0].Message  | Should -BeLike '*vm-saved*Saved*Resumed*'
        }
    }

    # ------------------------------------------------------------------
    Context 'when the VM is already Running' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-HyperVModuleLoaded {}
            Mock Get-VM   { [PSCustomObject]@{ State = 'Running' } }
            Mock Start-VM {}
        }

        It 'does NOT invoke Start-VM' {
            Start-VmIfStopped -VmName 'vm-up' | Out-Null

            Should -Invoke Start-VM -Times 0 -Exactly
        }

        It 'returns { VmName, EntryState=Running, Action=AlreadyRunning }' {
            $result = Start-VmIfStopped -VmName 'vm-up'

            $result.VmName     | Should -Be 'vm-up'
            $result.EntryState | Should -Be 'Running'
            $result.Action     | Should -Be 'AlreadyRunning'
        }

        It 'emits exactly one verbose line naming the transition' {
            # @(...) forces array semantics; Where-Object returns a scalar
            # on a single match and `.Count` blows up under strict mode.
            $verbose = @(Start-VmIfStopped -VmName 'vm-up' -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })

            $verbose.Count       | Should -Be 1
            $verbose[0].Message  | Should -BeLike '*vm-up*Running*AlreadyRunning*'
        }
    }

    # ------------------------------------------------------------------
    Context 'when the VM is in a transient/unsupported state' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-HyperVModuleLoaded {}
            Mock Start-VM {}
        }

        It 'throws naming the VM and the observed state, without calling Start-VM (<state>)' -ForEach @(
            @{ state = 'Paused'   },
            @{ state = 'Stopping' },
            @{ state = 'Starting' },
            @{ state = 'Saving'   }
        ) {
            Mock Get-VM { [PSCustomObject]@{ State = $state } }

            { Start-VmIfStopped -VmName 'vm-x' } |
                Should -Throw -ExpectedMessage "*vm-x*$state*"

            Should -Invoke Start-VM -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'when the VM is in an unrecognised state' {
    # ------------------------------------------------------------------

        It 'throws naming the VM and the state, without calling Start-VM' {
            Mock Assert-HyperVModuleLoaded {}
            Mock Get-VM   { [PSCustomObject]@{ State = 'Quiescing' } }
            Mock Start-VM {}

            { Start-VmIfStopped -VmName 'vm-q' } |
                Should -Throw -ExpectedMessage '*vm-q*Quiescing*'

            Should -Invoke Start-VM -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'when the VM lookup fails' {
    # ------------------------------------------------------------------

        It 're-throws with $VmName in the message, without calling Start-VM' {
            Mock Assert-HyperVModuleLoaded {}
            Mock Get-VM   { throw 'opaque native error' }
            Mock Start-VM {}

            { Start-VmIfStopped -VmName 'missing-vm' } |
                Should -Throw -ExpectedMessage '*missing-vm*'

            Should -Invoke Start-VM -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'parameter binding' {
    # ------------------------------------------------------------------

        It 'rejects missing -VmName' {
            { Start-VmIfStopped } | Should -Throw
        }

        It 'rejects empty -VmName' {
            { Start-VmIfStopped -VmName '' } | Should -Throw
        }

        It 'rejects $null -VmName' {
            { Start-VmIfStopped -VmName $null } | Should -Throw
        }
    }
}
