function Get-VmSwitchHostIp {
    <#
    .SYNOPSIS
        Returns the Windows host's IP on the same Hyper-V internal switch as the VM.

    .DESCRIPTION
        Scans Get-NetIPAddress for an IPv4 address whose first three octets
        (the /24 prefix) match those of the given VM IP, then returns the
        first match that is not the VM's own address.

        This is needed because the host may have several network adapters and
        the Hyper-V internal switch adapter is the only one reachable from the
        VM's private subnet.

    .PARAMETER VmIpAddress
        IPv4 address of any VM on the switch (e.g. '10.10.0.50').

    .EXAMPLE
        Get-VmSwitchHostIp -VmIpAddress '10.10.0.50'
        # Returns e.g. '10.10.0.1'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $VmIpAddress
    )

    # Derive the /24 prefix from the VM address so we can match the host adapter
    # that sits on the same subnet (the Hyper-V internal switch adapter).
    $parts  = $VmIpAddress -split '\.'
    $prefix = "$($parts[0]).$($parts[1]).$($parts[2])."

    $hostIp = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress.StartsWith($prefix) -and
            $_.IPAddress -ne $VmIpAddress
        } |
        Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $hostIp) {
        throw "No host adapter found on the same /24 as '$VmIpAddress' (prefix '$prefix')."
    }

    $hostIp
}
