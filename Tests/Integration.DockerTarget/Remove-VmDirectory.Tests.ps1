# Integration tests for Remove-VmDirectory against a real SSH target.
# See Initialize-DockerTargetEnvironment.ps1 for environment details.
#
# Unit tests already pin the emitted script shape and the host-side
# allowlist / denylist logic. This file proves the rm -rf actually
# happens against an allowlisted target, the wrong-type guard refuses
# to delete a regular file under a real shell, and (crucially) that
# the rejected denylist / out-of-allowlist cases leave the VM
# byte-identical - the negative cannot be proven with pure unit tests.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerTargetEnvironment.ps1"

    $Script:AllowedDir   = '/opt/integration-test-dir'
    $Script:AllowedFile  = '/opt/integration-test-file'
    $Script:LookalikeDir = '/optimist'
    $Script:DenyDir      = '/etc/cron.d'
    $Script:ParentEscape = '/opt/foo/../etc/passwd'

    function Test-PathExists {
        param([string] $Path)
        $rc = Invoke-SshQuery "(test -e '$Path' || test -L '$Path') && echo yes || echo no"
        return ($rc -eq 'yes')
    }

    function Get-DirListing {
        param([string] $Path)
        # ls -la output is the snapshot we diff against to prove a
        # rejected call left the VM untouched. -A hides only . and ..
        # to keep the snapshot stable across kernel cron-package
        # variations that may leave the directory empty otherwise.
        return Invoke-SshQuery "ls -lA '$Path'"
    }

    function Get-FileSha {
        param([string] $Path)
        return Invoke-SshQuery "sha256sum '$Path' | awk '{print `$1}'"
    }
}

AfterAll {
    . "$PSScriptRoot\Remove-DockerTargetEnvironment.ps1"
}

Describe 'Remove-VmDirectory (integration)' {

    BeforeEach {
        # Allowlisted fixtures live entirely under /opt so the cleanup
        # is a single rm. /optimist is a lookalike-prefix fixture; we
        # also clean it here to keep the suite re-runnable.
        Invoke-ContainerCommand "rm -rf '$Script:AllowedDir' '$Script:AllowedFile' '$Script:LookalikeDir'" |
            Out-Null
    }

    AfterEach {
        Invoke-ContainerCommand "rm -rf '$Script:AllowedDir' '$Script:AllowedFile' '$Script:LookalikeDir'" |
            Out-Null
    }

    It 'removes an existing allowlisted directory tree' {
        Invoke-ContainerCommand "mkdir -p '$Script:AllowedDir/sub' && echo hi > '$Script:AllowedDir/sub/file.txt'" |
            Out-Null
        Test-PathExists -Path $Script:AllowedDir | Should -BeTrue

        Remove-VmDirectory -SshClient $Script:SshClient -Path $Script:AllowedDir

        Test-PathExists -Path $Script:AllowedDir | Should -BeFalse
    }

    It 'is a no-op when the directory is already absent' {
        Test-PathExists -Path $Script:AllowedDir | Should -BeFalse

        # Idempotent uninstall contract - matches the rest of the
        # install-primitive family (Remove-VmSymlink, Remove-VmProfileDScript).
        { Remove-VmDirectory -SshClient $Script:SshClient -Path $Script:AllowedDir } |
            Should -Not -Throw

        Test-PathExists -Path $Script:AllowedDir | Should -BeFalse
    }

    It 'throws and leaves the file byte-identical when <Path> is a regular file' {
        Invoke-ContainerCommand "printf 'do not delete me' > '$Script:AllowedFile'" | Out-Null
        $shaBefore = Get-FileSha -Path $Script:AllowedFile

        { Remove-VmDirectory -SshClient $Script:SshClient -Path $Script:AllowedFile } |
            Should -Throw -ExpectedMessage '*conflict*non-directory*'

        $isFile = Invoke-SshQuery "test -f '$Script:AllowedFile' && ! test -L '$Script:AllowedFile' && echo yes || echo no"
        $isFile | Should -Be 'yes'
        (Get-FileSha -Path $Script:AllowedFile) | Should -Be $shaBefore
    }

    It 'rejects a denylisted path before SSH and leaves it byte-identical' {
        # Snapshot the protected dir on the container; the throw must
        # come from host-side validation so a byte-for-byte diff after
        # the call proves no SSH command ran against the deny path.
        $listingBefore = Get-DirListing -Path $Script:DenyDir

        { Remove-VmDirectory -SshClient $Script:SshClient -Path $Script:DenyDir } |
            Should -Throw -ExpectedMessage '*outside the allowlist*'

        (Get-DirListing -Path $Script:DenyDir) | Should -Be $listingBefore
    }

    It 'rejects a lookalike-prefix path (/optimist) and leaves the dir present' {
        # /optimist starts with /opt but not /opt/ - this is the case
        # the trailing-slash on the allowlist prefix exists to reject.
        # Pre-creating it on the VM lets us prove the dir is still
        # there after the host-side throw.
        Invoke-ContainerCommand "mkdir -p '$Script:LookalikeDir' && touch '$Script:LookalikeDir/marker'" |
            Out-Null
        $listingBefore = Get-DirListing -Path $Script:LookalikeDir

        { Remove-VmDirectory -SshClient $Script:SshClient -Path $Script:LookalikeDir } |
            Should -Throw -ExpectedMessage '*outside the allowlist*'

        Test-PathExists -Path $Script:LookalikeDir | Should -BeTrue
        (Get-DirListing -Path $Script:LookalikeDir) | Should -Be $listingBefore
    }

    It 'rejects a path with .. segments before SSH and leaves /etc/passwd byte-identical' {
        $shaBefore = Get-FileSha -Path '/etc/passwd'

        { Remove-VmDirectory -SshClient $Script:SshClient -Path $Script:ParentEscape } |
            Should -Throw -ExpectedMessage "*contains a '..' segment*"

        (Get-FileSha -Path '/etc/passwd') | Should -Be $shaBefore
    }
}
