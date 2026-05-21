BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\PsModules\Assert-PsModuleLoaded.ps1"

    # A PSModuleInfo-shaped stand-in. The helper only checks for truthiness
    # of the Get-Module result, so a bare PSCustomObject with the relevant
    # Name property is enough fidelity without taking a dependency on the
    # real PSModuleInfo constructor.
    function New-FakeModuleInfo {
        param([string] $Name)
        [PSCustomObject]@{ Name = $Name }
    }
}

Describe 'Assert-PsModuleLoaded' {

    BeforeEach {
        # Default mocks return null so unmatched ParameterFilter combinations
        # land on "module not visible" rather than escaping to the real
        # Get-Module on the test host (which could see real modules and
        # poison the unit under test).
        Mock Get-Module    { $null }
        Mock Import-Module {}
    }

    # ------------------------------------------------------------------
    Context 'when the module is already loaded' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-Module { New-FakeModuleInfo -Name 'TestModule' } `
                -ParameterFilter { $Name -eq 'TestModule' -and -not $ListAvailable }
        }

        It 'returns silently' {
            { Assert-PsModuleLoaded -Name 'TestModule' -InstallHint 'install it' } |
                Should -Not -Throw
        }

        It 'does not probe -ListAvailable' {
            Assert-PsModuleLoaded -Name 'TestModule' -InstallHint 'install it'

            Should -Invoke Get-Module -Times 0 -Exactly `
                -ParameterFilter { $ListAvailable }
        }

        It 'does not invoke Import-Module' {
            Assert-PsModuleLoaded -Name 'TestModule' -InstallHint 'install it'

            Should -Invoke Import-Module -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'when the module is installed but not loaded' {
    # ------------------------------------------------------------------

        BeforeEach {
            # Loaded probe returns null; available probe returns a module
            # info. The helper should import once and return.
            Mock Get-Module { $null } `
                -ParameterFilter { $Name -eq 'TestModule' -and -not $ListAvailable }
            Mock Get-Module { New-FakeModuleInfo -Name 'TestModule' } `
                -ParameterFilter { $Name -eq 'TestModule' -and $ListAvailable }
        }

        It 'returns silently' {
            { Assert-PsModuleLoaded -Name 'TestModule' -InstallHint 'install it' } |
                Should -Not -Throw
        }

        It 'invokes Import-Module exactly once with the requested Name' {
            Assert-PsModuleLoaded -Name 'TestModule' -InstallHint 'install it'

            Should -Invoke Import-Module -Times 1 -Exactly `
                -ParameterFilter { $Name -eq 'TestModule' }
        }
    }

    # ------------------------------------------------------------------
    Context 'when the module is not installed' {
    # ------------------------------------------------------------------

        # Default mocks already return $null for both probes; nothing extra
        # to set up.

        It 'throws and the message contains the Name and the InstallHint' {
            { Assert-PsModuleLoaded -Name 'TestModule' `
                                    -InstallHint 'Install-Module TestModule' } |
                Should -Throw `
                    -ExpectedMessage "*'TestModule'*not installed*Install-Module TestModule*"
        }

        It 'does not invoke Import-Module' {
            { Assert-PsModuleLoaded -Name 'TestModule' `
                                    -InstallHint 'Install-Module TestModule' } |
                Should -Throw

            Should -Invoke Import-Module -Times 0 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'when Import-Module fails' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-Module { $null } `
                -ParameterFilter { $Name -eq 'TestModule' -and -not $ListAvailable }
            Mock Get-Module { New-FakeModuleInfo -Name 'TestModule' } `
                -ParameterFilter { $Name -eq 'TestModule' -and $ListAvailable }
            Mock Import-Module { throw 'underlying import explosion' } `
                -ParameterFilter { $Name -eq 'TestModule' }
        }

        It 'throws the dedicated "present but failed to load" wrapper' {
            { Assert-PsModuleLoaded -Name 'TestModule' `
                                    -InstallHint 'Install-Module TestModule' } |
                Should -Throw `
                    -ExpectedMessage "*'TestModule'*present but failed to load*Install-Module TestModule*"
        }

        It 'preserves the original exception as InnerException' {
            $thrown = $null
            try {
                Assert-PsModuleLoaded -Name 'TestModule' `
                                      -InstallHint 'Install-Module TestModule'
            }
            catch {
                $thrown = $_
            }

            $thrown                                       | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException              | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException.Message      | Should -BeLike '*underlying import explosion*'
        }
    }

    # ------------------------------------------------------------------
    Context 'parameter binding' {
    # ------------------------------------------------------------------

        # Mandatory + ValidateNotNullOrEmpty on -Name and -InstallHint.
        # One It per shape so a regression on either parameter's contract
        # is pinpointed by the failing test name.

        It 'fails to bind when -Name is missing' {
            { Assert-PsModuleLoaded -InstallHint 'install it' } | Should -Throw
        }

        It 'fails to bind when -Name is empty' {
            { Assert-PsModuleLoaded -Name '' -InstallHint 'install it' } | Should -Throw
        }

        It 'fails to bind when -InstallHint is missing' {
            { Assert-PsModuleLoaded -Name 'TestModule' } | Should -Throw
        }

        It 'fails to bind when -InstallHint is empty' {
            { Assert-PsModuleLoaded -Name 'TestModule' -InstallHint '' } | Should -Throw
        }
    }
}
