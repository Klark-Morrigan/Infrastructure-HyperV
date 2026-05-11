BeforeAll {
    . "$PSScriptRoot\..\Infrastructure.HyperV\Private\Stop-VmFileServer.ps1"

    # Builds a fake server handle whose Listener, PowerShell, and Runspace
    # objects record whether Stop() / Dispose() were called on them.
    # GetNewClosure() captures each call's own flag variables.
    function New-FakeServer {
        param(
            [string] $StagingDir       = 'C:\fake\staging',
            [string] $FirewallRuleName = 'VmFileServer-8745'
        )

        $listener = [PSCustomObject]@{}
        Add-Member -InputObject $listener -MemberType ScriptMethod -Name 'Stop' `
            -Value { $script:listenerStopped = $true }

        $ps = [PSCustomObject]@{}
        Add-Member -InputObject $ps -MemberType ScriptMethod -Name 'Dispose' `
            -Value { $script:psDisposed = $true }

        $runspace = [PSCustomObject]@{}
        Add-Member -InputObject $runspace -MemberType ScriptMethod -Name 'Dispose' `
            -Value { $script:runspaceDisposed = $true }

        [PSCustomObject]@{
            HostIp           = '10.10.0.1'
            Port             = 8745
            BaseUrl          = 'http://10.10.0.1:8745'
            StagingDir       = $StagingDir
            Listener         = $listener
            PowerShell       = $ps
            Runspace         = $runspace
            FirewallRuleName = $FirewallRuleName
        }
    }
}

Describe 'Stop-VmFileServer' {

    BeforeEach {
        $script:listenerStopped  = $false
        $script:psDisposed       = $false
        $script:runspaceDisposed = $false

        Mock Remove-NetFirewallRule {}
        Mock Remove-Item {}

        $script:server = New-FakeServer
    }

    Context 'listener shutdown' {

        It 'calls Listener.Stop()' {
            Stop-VmFileServer -Server $script:server
            $script:listenerStopped | Should -BeTrue
        }
    }

    Context 'resource disposal' {

        It 'calls PowerShell.Dispose()' {
            Stop-VmFileServer -Server $script:server
            $script:psDisposed | Should -BeTrue
        }

        It 'calls Runspace.Dispose()' {
            Stop-VmFileServer -Server $script:server
            $script:runspaceDisposed | Should -BeTrue
        }
    }

    Context 'firewall cleanup' {

        It 'removes the firewall rule by name' {
            Stop-VmFileServer -Server $script:server
            Should -Invoke Remove-NetFirewallRule -Times 1 -Exactly `
                -ParameterFilter { $Name -eq 'VmFileServer-8745' }
        }
    }

    Context 'staging directory cleanup' {

        It 'deletes the staging directory' {
            Stop-VmFileServer -Server $script:server
            Should -Invoke Remove-Item -Times 1 -Exactly `
                -ParameterFilter { $Path -eq 'C:\fake\staging' }
        }
    }
}
