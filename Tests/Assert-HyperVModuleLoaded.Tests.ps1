BeforeAll {
    # Dot-source the shared helper first so Mock can bind to it; the Hyper-V
    # guard is a pure delegation and would otherwise have nothing in scope.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\PsModules\Assert-PsModuleLoaded.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Power\Assert-HyperVModuleLoaded.ps1"
}

Describe 'Assert-HyperVModuleLoaded' {

    # ------------------------------------------------------------------
    Context 'when Assert-PsModuleLoaded returns silently' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-PsModuleLoaded {}
            # Direct module-system calls are forbidden in this guard - the
            # whole point of the delegation is that the cascade lives in the
            # shared helper. Stub them so a regression that bypasses the
            # helper is caught by the Should -Not -Invoke assertion below.
            Mock Get-Module    {}
            Mock Import-Module {}
        }

        It 'returns silently' {
            { Assert-HyperVModuleLoaded } | Should -Not -Throw
        }

        It 'invokes Assert-PsModuleLoaded exactly once with Name=Hyper-V and a hint covering both SKUs' {
            Assert-HyperVModuleLoaded

            Should -Invoke Assert-PsModuleLoaded -Times 1 -Exactly `
                -ParameterFilter {
                    $Name -eq 'Hyper-V' -and
                    $InstallHint -like '*Install-WindowsFeature Hyper-V-PowerShell*' -and
                    $InstallHint -like '*Enable-WindowsOptionalFeature*Microsoft-Hyper-V-Management-PowerShell*'
                }
        }

        It 'does not call Get-Module or Import-Module directly' {
            Assert-HyperVModuleLoaded

            Should -Invoke Get-Module    -Times 0 -Exactly
            Should -Invoke Import-Module -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'when Assert-PsModuleLoaded throws (module not installed)' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-PsModuleLoaded {
                throw "Required PowerShell module 'Hyper-V' is not installed. install hint"
            }
        }

        It 'propagates the helper exception without wrapping' {
            { Assert-HyperVModuleLoaded } |
                Should -Throw -ExpectedMessage "*'Hyper-V' is not installed*install hint*"
        }
    }

    # ------------------------------------------------------------------
    Context 'when Assert-PsModuleLoaded throws (import failure)' {
    # ------------------------------------------------------------------

        BeforeEach {
            # Mirrors the "present but failed to load" wrapper that
            # Assert-PsModuleLoaded throws, including the preserved
            # InnerException, so the Hyper-V guard's propagation contract is
            # asserted end-to-end.
            Mock Assert-PsModuleLoaded {
                $inner = [System.InvalidOperationException]::new('underlying import explosion')
                throw [System.Management.Automation.RuntimeException]::new(
                    "PowerShell module 'Hyper-V' is present but failed to load. install hint",
                    $inner
                )
            }
        }

        It 'propagates the helper exception without wrapping' {
            { Assert-HyperVModuleLoaded } |
                Should -Throw -ExpectedMessage "*'Hyper-V'*present but failed to load*"
        }

        It 'preserves the original InnerException' {
            $thrown = $null
            try { Assert-HyperVModuleLoaded } catch { $thrown = $_ }

            $thrown                                  | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException         | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException.Message | Should -BeLike '*underlying import explosion*'
        }
    }
}
