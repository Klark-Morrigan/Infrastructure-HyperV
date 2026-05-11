BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Public\New-VmSshClient.ps1"

    # Replace the SSH.NET load guard with a configurable stub so tests can
    # both verify the guard is invoked and bypass it when exercising
    # parameter binding. Assert-SshNetLoaded itself is covered by
    # Assert-SshNetLoaded.Tests.ps1.
    $script:_guardCalls = 0
    function Assert-SshNetLoaded {
        $script:_guardCalls++
        # Simulate the guard's failure mode without depending on actual
        # SSH.NET type resolution. Tests opt out by re-stubbing in It blocks.
        throw 'guard invoked (test stub)'
    }
}

Describe 'New-VmSshClient' {

    # ------------------------------------------------------------------
    Context 'guard wiring' {
    # ------------------------------------------------------------------

        # The Renci.SshNet constructors cannot be mocked by Pester (they
        # are .NET instance constructors, not functions). Coverage here is
        # limited to verifying that the SSH.NET load guard runs before any
        # type resolution would otherwise produce an opaque error. Real
        # connection behaviour is exercised by the integration tests and
        # consumer E2E suites.

        It 'calls Assert-SshNetLoaded before constructing the client' {
            $script:_guardCalls = 0
            { New-VmSshClient -IpAddress '10.0.0.1' -Username 'u' -Password 'p' } |
                Should -Throw -ExpectedMessage '*guard invoked*'
            $script:_guardCalls | Should -Be 1
        }
    }
}
