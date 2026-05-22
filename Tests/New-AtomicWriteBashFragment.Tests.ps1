BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Bash\New-AtomicWriteBashFragment.ps1"
}

Describe 'New-AtomicWriteBashFragment' {

    Context 'happy path with defaults' {

        It 'emits the five expected lines in order' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/environment' `
                -ContentVar 'FILE_CONTENT'

            $lines = $fragment -split "`n"
            $lines.Count                | Should -Be 5
            $lines[0]                   | Should -BeExactly 'TMP="/etc/environment.tmp.$$"'
            $lines[1]                   | Should -BeExactly 'printf ''%s\n'' "$FILE_CONTENT" | sudo tee "$TMP" >/dev/null'
            $lines[2]                   | Should -BeExactly 'sudo chown root:root "$TMP"'
            $lines[3]                   | Should -BeExactly 'sudo chmod 0644 "$TMP"'
            $lines[4]                   | Should -BeExactly 'sudo mv "$TMP" "/etc/environment"'
        }

        It 'has no trailing newline so the caller controls how it joins' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/environment' `
                -ContentVar 'FILE_CONTENT'

            $fragment | Should -Not -Match "`n$"
        }

        It 'emits LF-only line endings (no CR)' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/profile.d/foo.sh' `
                -ContentVar 'DESIRED'

            $fragment | Should -Not -Match "`r"
            $fragment | Should -Match "`n"
        }

        It 'defaults TempDir to the parent of TargetPath' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/opt/foo/bar/baz.txt' `
                -ContentVar 'C'

            $fragment | Should -Match ([regex]::Escape('TMP="/opt/foo/bar/baz.txt.tmp.$$"'))
        }
    }

    Context 'overrides flow through verbatim' {

        It '-Owner replaces the default root:root' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/profile.d/foo.sh' `
                -ContentVar 'C' `
                -Owner 'ci-agent:ci-agent'

            $fragment | Should -Match 'sudo chown ci-agent:ci-agent "\$TMP"'
            $fragment | Should -Not -Match 'root:root'
        }

        It '-Mode replaces the default 0644' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/profile.d/foo.sh' `
                -ContentVar 'C' `
                -Mode '0755'

            $fragment | Should -Match 'sudo chmod 0755 "\$TMP"'
            $fragment | Should -Not -Match '0644'
        }

        It '-TempDir overrides the inferred default' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/opt/data/marker.json' `
                -ContentVar 'C' `
                -TempDir '/var/tmp'

            $fragment | Should -Match ([regex]::Escape('TMP="/var/tmp/marker.json.tmp.$$"'))
        }

        It '-ContentVar value appears in the printf (no $ prefix from the caller)' {
            $fragment = New-AtomicWriteBashFragment `
                -TargetPath '/etc/environment' `
                -ContentVar 'MY_CONTENT'

            $fragment | Should -Match ([regex]::Escape('printf ''%s\n'' "$MY_CONTENT"'))
        }
    }

    Context 'validation' {

        It 'throws when TargetPath is relative' {
            { New-AtomicWriteBashFragment -TargetPath 'etc/foo' -ContentVar 'C' } |
                Should -Throw -ExpectedMessage '*must be absolute*'
        }

        It 'throws when TargetPath contains ..' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/../passwd' -ContentVar 'C' } |
                Should -Throw -ExpectedMessage "*'..'*"
        }

        It 'throws when TargetPath contains a NUL byte' {
            { New-AtomicWriteBashFragment -TargetPath "/etc/foo`0bar" -ContentVar 'C' } |
                Should -Throw -ExpectedMessage '*NUL*'
        }

        It 'throws when TargetPath has no file name component' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/' -ContentVar 'C' } |
                Should -Throw -ExpectedMessage '*no file name*'
        }

        It 'throws when ContentVar starts with a digit' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar '1BAD' } |
                Should -Throw -ExpectedMessage '*POSIX identifier*'
        }

        It 'throws when ContentVar contains a space' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'BAD VAR' } |
                Should -Throw -ExpectedMessage '*POSIX identifier*'
        }

        It 'throws when ContentVar contains a dollar sign' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar '$INJECT' } |
                Should -Throw -ExpectedMessage '*POSIX identifier*'
        }

        It 'throws when Owner is missing the colon' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'C' -Owner 'root' } |
                Should -Throw -ExpectedMessage "*user:group*"
        }

        It 'throws when Owner contains a metacharacter' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'C' -Owner 'root;rm:root' } |
                Should -Throw -ExpectedMessage "*user:group*"
        }

        It 'throws when Mode is missing the leading zero' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'C' -Mode '644' } |
                Should -Throw -ExpectedMessage '*octal mode*'
        }

        It 'throws when Mode contains 8 or 9' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'C' -Mode '0789' } |
                Should -Throw -ExpectedMessage '*octal mode*'
        }

        It 'throws when Mode is too long' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'C' -Mode '012345' } |
                Should -Throw -ExpectedMessage '*octal mode*'
        }

        It 'throws when TempDir is relative' {
            { New-AtomicWriteBashFragment -TargetPath '/etc/foo' -ContentVar 'C' -TempDir 'tmp' } |
                Should -Throw -ExpectedMessage '*must be absolute*'
        }
    }
}
