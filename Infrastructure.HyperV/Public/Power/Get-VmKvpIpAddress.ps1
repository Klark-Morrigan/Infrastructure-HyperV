# ---------------------------------------------------------------------------
# Get-VmKvpIpAddress
#   Polls Hyper-V's KVP integration services (Get-VMNetworkAdapter +
#   .IPAddresses) until the supplied VM reports an IPv4 address on the
#   requested switch, then returns that address. Throws on deadline.
#
#   Why this lives in the module:
#     The provisioner's create-vm.ps1 needs to wait for a DHCP-mode
#     router VM's upstream IP before SSH-probing it; the E2E harness
#     needs to do the same on the test side because the discovered IP
#     never propagates back across the child-process boundary
#     provision.ps1 ran behind. Both call sites converged on the same
#     polling loop with the same "is the VM still Running?" guard, the
#     same IPv4-vs-IPv6 filter, and the same deadline/timeout error
#     surface - so it belongs in one place.
#
#   What the caller still owns:
#     - The UX. -OnPoll fires once per no-IP-yet iteration so the
#       provisioner can paint Write-Host dots and the E2E harness can
#       stay silent without forking two near-identical helpers.
#     - The "is this VM static or DHCP?" branch. This helper assumes
#       the caller already decided IP discovery is needed; it does not
#       inspect $Vm.ipAddress itself.
#     - Stamping the result back onto a VM def via Add-Member when the
#       caller wants reference-shared downstream access. Returning a
#       plain string keeps the helper free of object-identity
#       semantics.
#
#   -SwitchName is the multi-NIC discriminator. Router VMs have two
#   adapters (one on the external switch, one on a per-environment
#   private switch); without -SwitchName the helper would race-pick
#   whichever NIC KVP reported first. When -SwitchName is omitted the
#   first adapter wins (the typical workload case where the VM has a
#   single NIC).
# ---------------------------------------------------------------------------
function Get-VmKvpIpAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $VmName,

        # If provided, only return IPv4 addresses from adapters whose
        # SwitchName matches. Required for multi-NIC VMs; omit for
        # single-NIC workloads.
        [Parameter()]
        [string] $SwitchName,

        # Total wall-clock budget for the poll. 5 min covers a slow
        # upstream DHCP lease while staying well under the provisioner's
        # outer "wait for SSH" budget.
        [Parameter()]
        [int] $TimeoutMinutes = 5,

        # Cadence between KVP reads. 2 s avoids hammering
        # Get-VMNetworkAdapter without delaying the success path more
        # than one tick past the lease arriving.
        [Parameter()]
        [int] $PollIntervalSeconds = 2,

        # Fired once per "no IP yet" iteration so the caller can drive
        # progress UX (a Write-Host dot, a log event, ...) without the
        # helper having to know about the consumer's output style.
        [Parameter()]
        [scriptblock] $OnPoll
    )

    Assert-HyperVModuleLoaded

    $deadline     = (Get-Date).AddMinutes($TimeoutMinutes)
    $discoveredIp = $null

    while ((Get-Date) -lt $deadline -and -not $discoveredIp) {
        # KVP only publishes data for a Running VM, so a stopped VM
        # would loop silently until the deadline expires. Surface that
        # case immediately with a specific message rather than a 5-min
        # "did not report" timeout that obscures the cause.
        $vmState = (Get-VM -Name $VmName).State
        if ($vmState -ne 'Running') {
            throw (
                "Hyper-V VM '$VmName' is not Running (state: $vmState). " +
                "KVP integration services only publish IP addresses " +
                "while a VM is running."
            )
        }

        $adapters = @(Get-VMNetworkAdapter -VMName $VmName)
        if ($SwitchName) {
            $adapters = @($adapters | Where-Object {
                $_.SwitchName -eq $SwitchName
            })
        }
        if ($adapters.Count -gt 0) {
            # IPv6 addresses (fe80::, etc.) get reported alongside IPv4
            # the moment the link comes up - filter them out so we wait
            # for the actual lease rather than returning a link-local.
            $discoveredIp = @($adapters[0].IPAddresses) |
                Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
                Select-Object -First 1
        }
        if (-not $discoveredIp) {
            if ($null -ne $OnPoll) { & $OnPoll }
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    if (-not $discoveredIp) {
        $where = if ($SwitchName) {
            " on switch '$SwitchName'"
        } else { '' }
        throw (
            "VM '$VmName'$where did not report an IPv4 address via " +
            "Hyper-V KVP within $TimeoutMinutes minute(s). Check that " +
            "the VM is running, its NIC is attached to the expected " +
            "switch, and the upstream DHCP server is reachable."
        )
    }

    $discoveredIp
}
