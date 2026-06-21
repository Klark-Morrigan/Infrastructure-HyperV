# ---------------------------------------------------------------------------
# New-VmSshClientWithJump
#   Opens an SSH client to a VM, transparently routing through a jump
#   host when one is required.
#
#   Two paths:
#     - Direct (router VMs, or any VM the host has L2 reach to):
#       calls New-VmSshClient directly. No tunnel.
#     - Jumped (workload VMs after feature 53 - host has no route to
#       the per-environment private subnet): opens New-VmSshTunnel
#       against the workload's `_RouterVm` neighbour, then connects
#       a fresh SshClient to localhost:<LocalPort> using the
#       workload's credentials. The SSH session piggybacks the
#       tunnel's forwarded port; bytes flow workload <-> router <->
#       host transparently.
#
#   Returns a session object holding both the SshClient and (when
#   jumped) the underlying tunnel. Callers MUST call .Dispose() in
#   a finally block - it tears the client down first, then the
#   tunnel, so the forward closes cleanly.
#
#   Decision rule: a `_RouterVm` NoteProperty signals "jump required".
#   provision.ps1 step 7 stamps it onto every workload VM def from
#   Group-VmsByEnvironment, so callers do not need to know about
#   environments or routing themselves.
# ---------------------------------------------------------------------------

function New-VmSshClientWithJump {
    # Both Dispose() ScriptMethods below swallow cleanup errors on purpose:
    # the SSH.NET client/tunnel throw on double-dispose or on an already-
    # dropped session, and the caller's finally must not be derailed by that
    # noise. Suppress the empty-catch rule for the function.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock', '',
        Justification = 'Dispose cleanup must not throw out of a finally block')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        # Forwarded to the underlying New-VmSshClient. Workload SSH
        # paths typically pass a generous timeout (10 min) because the
        # workload's first SSH connect blocks behind cloud-config
        # finishing - same posture Invoke-VmPostProvisioning uses for
        # the direct case.
        [Parameter()]
        [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(30),

        # SSH-level keepalive interval applied to whichever client this
        # returns (direct or jumped). Forwarded to New-VmSshClient on the
        # direct path and set on the tunnelled client on the jump path so
        # both legs share the same liveness posture. Defaults to 15s; pass
        # [TimeSpan]::Zero to disable. See New-VmSshClient for rationale.
        [TimeSpan] $KeepAliveInterval = [TimeSpan]::FromSeconds(15)
    )

    Assert-SshNetLoaded

    # No jump configured (router VM, or pre-feature-53 topology). Direct
    # connect via the standard helper - same semantics as if this
    # wrapper did not exist.
    $hasRouter = $Vm.PSObject.Properties['_RouterVm'] -and $Vm._RouterVm
    if (-not $hasRouter) {
        $client = New-VmSshClient `
                      -IpAddress         $Vm.ipAddress `
                      -Username          $Vm.username `
                      -Password          $Vm.password `
                      -Timeout           $Timeout `
                      -KeepAliveInterval $KeepAliveInterval

        $session = [PSCustomObject]@{ Client = $client; Tunnel = $null }
        Add-Member -InputObject $session `
                   -MemberType ScriptMethod -Name Dispose -Value {
            try {
                if ($this.Client.IsConnected) { $this.Client.Disconnect() }
            } catch {}
            try { $this.Client.Dispose() } catch {}
        }
        return $session
    }

    # Workload VM: open the jump tunnel through its router neighbour.
    $tunnel = New-VmSshTunnel `
                  -TargetIp     $Vm.ipAddress `
                  -JumpHostIp   $Vm._RouterVm.ipAddress `
                  -JumpUsername $Vm._RouterVm.username `
                  -JumpPassword $Vm._RouterVm.password `
                  -JumpConnectTimeout $Timeout

    # Connect to the tunnel's loopback endpoint with the workload's
    # credentials, routing through the same New-VmSshClient helper as the
    # direct path: the workload listens on 22 inside its NIC, but the
    # local-forward endpoint is on an ephemeral host port, which -Port
    # selects. This keeps the connect/keepalive policy in one place.
    try {
        $client = New-VmSshClient `
                      -IpAddress         $tunnel.LocalHost `
                      -Port              ([int]$tunnel.LocalPort) `
                      -Username          $Vm.username `
                      -Password          $Vm.password `
                      -Timeout           $Timeout `
                      -KeepAliveInterval $KeepAliveInterval
    }
    catch {
        # Tunnel survives until we know the client connect succeeded;
        # tear it down on any failure so we do not leak the jump
        # session.
        $tunnel.Dispose()
        throw
    }

    $session = [PSCustomObject]@{ Client = $client; Tunnel = $tunnel }
    Add-Member -InputObject $session `
               -MemberType ScriptMethod -Name Dispose -Value {
        try {
            if ($this.Client.IsConnected) { $this.Client.Disconnect() }
        } catch {}
        try { $this.Client.Dispose() } catch {}
        # Dispose the tunnel AFTER the inner client so the
        # forwarded-port still services the workload session's
        # graceful shutdown traffic before the channel goes away.
        try { $this.Tunnel.Dispose() } catch {}
    }
    return $session
}
