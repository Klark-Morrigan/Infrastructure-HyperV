BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\ProfileD\Assert-VmProfileDScriptName.ps1"
}

Describe 'Assert-VmProfileDScriptName' {

    Context 'accepts well-formed names' {

        It 'returns silently for a plain ASCII name' {
            { Assert-VmProfileDScriptName -Name 'foo' } | Should -Not -Throw
        }

        It 'allows digits, dots, underscores, and dashes' {
            { Assert-VmProfileDScriptName -Name 'foo_1.bar-2' } | Should -Not -Throw
        }

        It 'allows a single character' {
            { Assert-VmProfileDScriptName -Name 'a' } | Should -Not -Throw
        }
    }

    Context 'rejects invalid names' {

        It 'throws on empty Name' {
            { Assert-VmProfileDScriptName -Name '' } | Should -Throw
        }

        It 'throws on Name containing /' {
            { Assert-VmProfileDScriptName -Name 'foo/bar' } | Should -Throw
        }

        It 'throws on Name containing a space' {
            { Assert-VmProfileDScriptName -Name 'foo bar' } | Should -Throw
        }

        It 'throws on Name containing a single quote' {
            { Assert-VmProfileDScriptName -Name "foo'bar" } | Should -Throw
        }

        It 'throws on Name containing a dollar sign' {
            { Assert-VmProfileDScriptName -Name 'foo$bar' } | Should -Throw
        }

        It 'throws on Name equal to .' {
            { Assert-VmProfileDScriptName -Name '.' } | Should -Throw
        }

        It 'throws on Name equal to ..' {
            { Assert-VmProfileDScriptName -Name '..' } | Should -Throw
        }

        It 'throws on Name ending in .sh' {
            { Assert-VmProfileDScriptName -Name 'foo.sh' } | Should -Throw
        }

        It 'still rejects when only the suffix matches (single .sh)' {
            { Assert-VmProfileDScriptName -Name '.sh' } | Should -Throw
        }
    }

    Context 'error messages identify the caller' {

        It 'prefixes the thrown message with the supplied CmdletName' {
            { Assert-VmProfileDScriptName -Name '' -CmdletName 'Some-Cmdlet' } |
                Should -Throw -ExpectedMessage '*Some-Cmdlet*'
        }

        It 'falls back to a default label when CmdletName is omitted' {
            { Assert-VmProfileDScriptName -Name '' } |
                Should -Throw -ExpectedMessage '*Assert-VmProfileDScriptName*'
        }

        It 'includes the offending Name in the regex-mismatch message' {
            { Assert-VmProfileDScriptName -Name 'foo bar' -CmdletName 'X' } |
                Should -Throw -ExpectedMessage "*foo bar*"
        }
    }
}
