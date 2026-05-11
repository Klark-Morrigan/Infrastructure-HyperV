BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Assert-SshNetLoaded.ps1"
}

Describe 'Assert-SshNetLoaded' {

    # ------------------------------------------------------------------
    Context 'when Renci.SshNet is not loaded' {
    # ------------------------------------------------------------------

        # The unit test environment does not import Posh-SSH, so the guard
        # exercises the error path naturally. The positive path (no throw
        # when SSH.NET is loaded) is covered implicitly by the integration
        # tests in repos that import Posh-SSH before calling SSH helpers.

        It 'throws an actionable message naming the prerequisite' {
            { Assert-SshNetLoaded } |
                Should -Throw -ExpectedMessage '*SSH.NET assembly not loaded*Posh-SSH*'
        }
    }
}
