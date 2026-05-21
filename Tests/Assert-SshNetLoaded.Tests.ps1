BeforeDiscovery {
    # The SSH.NET type can only be observed when Posh-SSH (or its bundled
    # DLL) is loaded on the test host. CI does not install Posh-SSH, so the
    # "type present" assertion is gated on this flag; the negative path
    # below is exercised in either environment.
    #
    # Set in BeforeDiscovery (not BeforeAll) so the variable exists when
    # the per-It `-Skip:` clauses below are evaluated: Pester 5 evaluates
    # -Skip at discovery time, before BeforeAll runs, and a BeforeAll-set
    # script-scope variable read at discovery throws under strict mode.
    # See feedback-pester5-discovery-time-skip.
    $script:SshNetTypePresent = [bool] ('Renci.SshNet.SshClient' -as [type])
}

BeforeAll {
    # Dot-source the shared helper first so Mock can bind to it; the SSH
    # guard delegates to Assert-PsModuleLoaded and is otherwise just a
    # type-presence sanity check.
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\PsModules\Assert-PsModuleLoaded.ps1"
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Ssh\Assert-SshNetLoaded.ps1"
}

Describe 'Assert-SshNetLoaded' {

    # ------------------------------------------------------------------
    Context 'when Assert-PsModuleLoaded returns silently' {
    # ------------------------------------------------------------------

        BeforeEach {
            # Helper succeeds; the SSH guard now only depends on whether
            # the SSH.NET type is reachable in the current AppDomain.
            Mock Assert-PsModuleLoaded {}
        }

        It 'returns silently when the SSH.NET type is present' -Skip:(-not $script:SshNetTypePresent) {
            { Assert-SshNetLoaded } | Should -Not -Throw
        }

        It 'throws an error naming Renci.SshNet.SshClient when the type is absent' -Skip:($script:SshNetTypePresent) {
            { Assert-SshNetLoaded } |
                Should -Throw -ExpectedMessage '*Renci.SshNet.SshClient*'
        }

        It 'delegates to Assert-PsModuleLoaded with Name=Posh-SSH and a non-empty install hint' {
            # Swallow the type-sanity throw on CI; the assertion is about
            # whether the delegation happened, not about the post-helper
            # branch.
            try { Assert-SshNetLoaded } catch { }

            Should -Invoke Assert-PsModuleLoaded -Times 1 -Exactly `
                -ParameterFilter {
                    $Name -eq 'Posh-SSH' -and
                    -not [string]::IsNullOrWhiteSpace($InstallHint) -and
                    $InstallHint -like '*Posh-SSH*'
                }
        }
    }

    # ------------------------------------------------------------------
    Context 'when Assert-PsModuleLoaded throws (module not installed)' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Assert-PsModuleLoaded {
                throw "Required PowerShell module 'Posh-SSH' is not installed. install hint"
            }
        }

        It 'propagates the helper exception without wrapping' {
            { Assert-SshNetLoaded } |
                Should -Throw -ExpectedMessage "*'Posh-SSH' is not installed*install hint*"
        }
    }

    # ------------------------------------------------------------------
    Context 'when Assert-PsModuleLoaded throws (import failure)' {
    # ------------------------------------------------------------------

        BeforeEach {
            # Mirrors the "present but failed to load" wrapper that
            # Assert-PsModuleLoaded throws, including the preserved
            # InnerException, so the SSH guard's propagation contract is
            # asserted end-to-end.
            Mock Assert-PsModuleLoaded {
                $inner = [System.InvalidOperationException]::new('underlying import explosion')
                throw [System.Management.Automation.RuntimeException]::new(
                    "PowerShell module 'Posh-SSH' is present but failed to load. install hint",
                    $inner
                )
            }
        }

        It 'propagates the helper exception without wrapping' {
            { Assert-SshNetLoaded } |
                Should -Throw -ExpectedMessage "*'Posh-SSH'*present but failed to load*"
        }

        It 'preserves the original InnerException' {
            $thrown = $null
            try { Assert-SshNetLoaded } catch { $thrown = $_ }

            $thrown                                  | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException         | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException.Message | Should -BeLike '*underlying import explosion*'
        }
    }
}
