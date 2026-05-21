# ---------------------------------------------------------------------------
# Start-VmIfStopped
#   Idempotently brings a Hyper-V VM to the Running state. Returns a result
#   object describing the entry state and the action taken so callers can
#   log, audit, or branch on the transition without re-querying Hyper-V.
#
#   The state machine is intentionally exhaustive: each terminal state has
#   its own arm, and intermediate states (Paused / Stopping / Starting /
#   Saving) throw with a named state rather than silently waiting or
#   silently no-op'ing. A future Hyper-V state we have not considered
#   surfaces through the explicit "other" arm so a new state never goes
#   unnoticed.
#
#   Compose with Wait-VmSshReady to bring a VM up and gate post-boot SSH
#   work on sshd actually accepting connections.
# ---------------------------------------------------------------------------

function Start-VmIfStopped {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $VmName
    )

    # Fail fast with an actionable install hint before any Hyper-V cmdlet
    # is touched - otherwise the first Get-VM call surfaces as the opaque
    # "term Get-VM is not recognized" message.
    Assert-HyperVModuleLoaded

    try {
        $vm = Get-VM -Name $VmName -ErrorAction Stop
    }
    catch {
        # The native Get-VM error wording does not always include the
        # requested name in a stable format; re-wrap so the operator
        # always sees which VM the lookup failed for.
        throw "Failed to look up Hyper-V VM '$VmName': $($_.Exception.Message)"
    }

    # Compare by name string rather than taking a hard
    # [Microsoft.HyperV.PowerShell.VMState] reference inside the module
    # body - keeps the module loadable on hosts without the Hyper-V
    # assemblies (the guard above is the only place that requires them).
    $stateName = [string] $vm.State

    switch ($stateName) {
        'Running' {
            Write-Verbose "$VmName`: Running -> AlreadyRunning"
            return [PSCustomObject]@{
                VmName     = $VmName
                EntryState = 'Running'
                Action     = 'AlreadyRunning'
            }
        }
        'Off' {
            Start-VM -Name $VmName -ErrorAction Stop
            Write-Verbose "$VmName`: Off -> Started"
            return [PSCustomObject]@{
                VmName     = $VmName
                EntryState = 'Off'
                Action     = 'Started'
            }
        }
        'Saved' {
            Start-VM -Name $VmName -ErrorAction Stop
            Write-Verbose "$VmName`: Saved -> Resumed"
            return [PSCustomObject]@{
                VmName     = $VmName
                EntryState = 'Saved'
                Action     = 'Resumed'
            }
        }
        { $_ -in 'Paused', 'Stopping', 'Starting', 'Saving' } {
            throw ("VM '$VmName' is in transient/unsupported state " +
                   "'$stateName'; refusing to call Start-VM.")
        }
        default {
            # Loud failure for any state Hyper-V may add in the future
            # rather than a silent miss. Same actionable shape as the
            # transient-state arm so the operator sees the VM and the
            # observed state without us having to enumerate every value.
            throw ("VM '$VmName' is in unrecognised state '$stateName'; " +
                   "refusing to call Start-VM.")
        }
    }
}
