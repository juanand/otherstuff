<#
.SYNOPSIS
Configures IPv4 destination routes for Azure VMs with multiple NICs.

.DESCRIPTION
Previews subnet-to-destination mappings and changes routes only with -Apply.
Unmatched NIC maps warn and skip; invalid or ambiguous configuration fails before
mutation. Default, connected, and DHCP-learned routes are preserved.

Use named PowerShell parameters with a single hyphen. Supply -Map once with an
array of quoted mappings; Bash-style --map and repeated -Map parameters are not
supported. Destination routes do not guarantee symmetric replies for every source.

.PARAMETER Map
An array of NIC_CIDR=DEST1,DEST2 strings. The selector must contain one actual NIC
subnet. The destinations are canonical non-default IPv4 networks.

.PARAMETER Gateway
An array of NIC_CIDR=ACTUAL_GATEWAY overrides. Overrides take precedence over OS
discovery. Only when evidence is absent, Azure gateways are calculated as the actual
subnet network plus one for /2 through /29 and labelled in the plan. Conflicting or
invalid evidence and unsupported calculation prefixes require an explicit override.

.PARAMETER Metric
Route metric from 1 through 65535. Default: 42762. Used for additions and rollback.

.PARAMETER Apply
Performs the reviewed additions or cleanup. Requires an elevated Administrator
session. Without this switch, all operations are read-only previews.

.PARAMETER Persist
With -Apply, saves new routes in both native active and persistent stores.
An existing active-only route requires reviewed rollback before persistent apply.
Without -Apply this is still a preview. Not used with rollback or reset.

.PARAMETER Rollback
Removes eligible manual routes using the selected metric from saved and active
stores. Preview by default; add -Apply from a console to perform removal.

.PARAMETER Reset
Removes eligible manual routes across all metrics from saved and active stores.
Does not delete profiles or change DNS, MTU, addresses, or DHCP settings. Cannot be
combined with -Metric, -Map, -Gateway, -Persist, or -Rollback. Preview by default.

.PARAMETER InventoryPath
Reads an explicit JSON fixture with Interfaces, Routes, and SavedRoutes for an
offline preview. Cannot be combined with -Apply.

.PARAMETER LibraryOnly
Loads functions without discovery or mutation. Intended for the isolated tests.

.EXAMPLE
$maps = @('10.0.0.0/8=10.0.0.0/8,172.20.0.0/16', '172.16.0.0/16=172.16.0.0/16')
& $tool -Map $maps

Previews multiple mappings. In these examples, set $tool to the actual path of this
script. A comma inside one quoted mapping separates destinations for the same NIC.

.EXAMPLE
& $tool -Map '172.16.0.0/16=172.16.0.0/16' -Gateway '172.16.0.0/16=172.16.0.126' -Apply -Persist -Metric 50000

Adds and saves a route with an explicit gateway and custom metric. Run the same
command without -Apply to preview first.

.EXAMPLE
& $tool -Rollback -Metric 50000
& $tool -Rollback -Metric 50000 -Apply

Previews and then removes eligible routes using metric 50000, including saved ones.

.EXAMPLE
& $tool -Reset
& $tool -Reset -Apply

Previews and then removes eligible manual routes across metrics. Use a console;
removing routes can interrupt remote access even when defaults are retained.

.NOTES
Supports Windows PowerShell 5.1 and PowerShell 7 with installed OS networking
cmdlets. No dependencies are installed. Batches are not atomic; partial changes
may remain after failure. Verify source-bound traffic in both directions.
#>

#requires -Version 5.1

[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]] $Map = @(),
    [string[]] $Gateway = @(),
    [ValidateRange(1, 65535)] [int] $Metric = 42762,
    [switch] $Apply,
    [switch] $Persist,
    [switch] $Rollback,
    [switch] $Reset,
    [string] $InventoryPath,
    [switch] $LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-MultiNicWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Assert-MultiNicAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '-Apply requires an elevated PowerShell session.' }
}

function Assert-MultiNicDependencies {
    param([switch] $Mutation, [switch] $Cleanup)
    if (-not (Test-MultiNicWindows)) { throw 'Live operations require Windows. Use -InventoryPath only for offline preview.' }
    $commands = @('Get-NetAdapter', 'Get-NetIPAddress', 'Get-NetRoute', 'Get-CimInstance')
    if ($Mutation) {
        if ($Cleanup) { $commands += 'Remove-NetRoute' } else { $commands += 'New-NetRoute' }
    }
    foreach ($name in $commands) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $command) { throw "Missing OS command: $name. No dependency will be installed." }
        if ($name -in 'Get-NetRoute', 'New-NetRoute', 'Remove-NetRoute') {
            if (-not $command.Parameters.ContainsKey('PolicyStore')) { throw "$name lacks required PolicyStore support." }
        }
    }
}

function ConvertTo-IPv4Number {
    param([string] $Address)
    if ($Address -notmatch '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$') { throw "Invalid IPv4 address: $Address" }
    [long] $number = 0
    foreach ($octet in $Address.Split('.')) {
        if ([int] $octet -gt 255) { throw "Invalid IPv4 address: $Address" }
        $number = ($number -shl 8) -bor [int] $octet
    }
    return $number
}

function Get-IPv4Prefix {
    param([string] $Cidr, [switch] $Destination)
    if ($Cidr -notmatch '^([^/]+)/(0|[1-9]|[12][0-9]|3[0-2])$') { throw "Invalid IPv4 CIDR: $Cidr" }
    $number = ConvertTo-IPv4Number $Matches[1]
    $length = [int] $Matches[2]
    [long] $mask = (4294967295L -shl (32 - $length)) -band 4294967295L
    $network = $number -band $mask
    if ($Destination -and ($length -eq 0 -or $number -ne $network)) { throw "Use a canonical, non-default CIDR: $Cidr" }
    return [pscustomobject]@{ Number = $number; Length = $length; Mask = $mask; Network = $network }
}

function Test-IPv4Contains {
    param([string] $Cidr, [string] $Address)
    $prefix = Get-IPv4Prefix $Cidr
    return (((ConvertTo-IPv4Number $Address) -band $prefix.Mask) -eq $prefix.Network)
}

function Get-MultiNicRoutes {
    param([ValidateSet('ActiveStore', 'PersistentStore')] [string] $Store)
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore $Store -ErrorAction Stop)
    }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound -and $_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound*') { return }
        throw
    }
    foreach ($route in $routes) {
        [pscustomobject]@{
            Destination = [string] $route.DestinationPrefix; Index = [int] $route.InterfaceIndex
            Gateway = [string] $route.NextHop; Metric = [int] $route.RouteMetric; Protocol = [string] $route.Protocol
        }
    }
}

function Get-MultiNicInventory {
    param([string] $Path)
    if ($Path) {
        $inventory = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $null = $inventory.Interfaces, $inventory.Routes, $inventory.SavedRoutes
        return $inventory
    }
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object Status -eq 'Up')
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.AddressState -eq 'Preferred' -and -not $_.SkipAsSource -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'
    })
    $configurations = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)
    $routes = @(Get-MultiNicRoutes ActiveStore)
    $savedRoutes = @(Get-MultiNicRoutes PersistentStore)
    $interfaces = foreach ($address in $addresses) {
        $adapter = @($adapters | Where-Object InterfaceIndex -eq $address.InterfaceIndex)
        if ($adapter.Count -ne 1) { continue }
        $type = if ($adapter[0].PSObject.Properties['InterfaceType']) { $adapter[0].InterfaceType } else { $adapter[0].ifType }
        if ([int] $type -ne 6) { continue }
        $evidence = @(
            foreach ($configuration in $configurations | Where-Object InterfaceIndex -eq $address.InterfaceIndex) {
                foreach ($nextHop in $configuration.DefaultIPGateway) {
                    if ($nextHop -match '^\d+\.\d+\.\d+\.\d+$') { [pscustomobject]@{ Address = $nextHop; Evidence = 'OS-configuration' } }
                }
            }
            foreach ($route in $routes | Where-Object { $_.Destination -eq '0.0.0.0/0' -and $_.Index -eq $address.InterfaceIndex -and $_.Gateway -ne '0.0.0.0' }) {
                [pscustomobject]@{ Address = $route.Gateway; Evidence = 'installed-default' }
            }
        )
        [pscustomobject]@{
            Index = [int] $address.InterfaceIndex; Alias = [string] $adapter[0].Name
            Mac = $adapter[0].MacAddress.Replace('-', ':').ToLowerInvariant()
            Address = [string] $address.IPAddress; PrefixLength = [int] $address.PrefixLength; Gateways = $evidence
        }
    }
    return [pscustomobject]@{ Interfaces = @($interfaces); Routes = $routes; SavedRoutes = $savedRoutes }
}

function Resolve-MultiNicSelector {
    param($Inventory, [string] $Selector, [switch] $AllowMissing)
    $prefix = Get-IPv4Prefix $Selector -Destination
    $selected = @($Inventory.Interfaces | Where-Object { $_.PrefixLength -ge $prefix.Length -and (Test-IPv4Contains $Selector $_.Address) })
    if ($selected.Count -gt 1) { throw "Multiple local addresses match $Selector; narrow the selector." }
    if (-not $selected.Count) {
        if ($AllowMissing) { return $null }
        throw "No actual NIC subnet matches $Selector."
    }
    return $selected[0]
}

function Get-MultiNicPrimary {
    param($Inventory)
    $indices = @($Inventory.Routes | Where-Object Destination -eq '0.0.0.0/0' | Select-Object -ExpandProperty Index -Unique)
    if ($indices.Count -ne 1 -or -not @($Inventory.Interfaces | Where-Object Index -eq $indices[0]).Count) { throw 'Primary default-route interface is ambiguous or unavailable; review guest routing.' }
    return $indices[0]
}

function Get-MultiNicGateway {
    param($Inventory, $Interface, [string[]] $Overrides)
    $explicit = @(
        foreach ($entry in $Overrides) {
            $parts = $entry.Split('=', 2)
            if ($parts.Count -ne 2) { throw "Invalid gateway override: $entry" }
            $resolved = Resolve-MultiNicSelector $Inventory $parts[0]
            $null = ConvertTo-IPv4Number $parts[1]
            if ($resolved.Index -eq $Interface.Index) { $parts[1] }
        }
    )
    $prefix = Get-IPv4Prefix "$($Interface.Address)/$($Interface.PrefixLength)"
    if ($explicit.Count -gt 1) { throw "Duplicate gateway overrides for $($Interface.Alias)." }
    if ($explicit.Count) { $gatewayAddress = $explicit[0]; $evidence = 'override' }
    else {
        $candidates = @($Interface.Gateways | Select-Object -ExpandProperty Address -Unique)
        if ($candidates.Count -gt 1) { throw "Conflicting gateway evidence for $($Interface.Alias); supply -Gateway NIC_CIDR=ACTUAL_GATEWAY." }
        if ($candidates.Count -eq 1) {
            $gatewayAddress = $candidates[0]
            $evidence = @($Interface.Gateways | Select-Object -ExpandProperty Evidence -Unique) -join ','
        }
        else {
            if ($prefix.Length -lt 2 -or $prefix.Length -gt 29) { throw "Cannot calculate an Azure gateway for $($Interface.Address)/$($prefix.Length); supply -Gateway NIC_CIDR=ACTUAL_GATEWAY." }
            [long] $gatewayNumber = $prefix.Network + 1
            $gatewayAddress = '{0}.{1}.{2}.{3}' -f (($gatewayNumber -shr 24) -band 255), (($gatewayNumber -shr 16) -band 255), (($gatewayNumber -shr 8) -band 255), ($gatewayNumber -band 255)
            $evidence = "Azure-subnet-plus-one($($Interface.Address)/$($prefix.Length))"
        }
    }
    $number = ConvertTo-IPv4Number $gatewayAddress
    if (($number -band $prefix.Mask) -ne $prefix.Network) { throw 'Gateway is outside the actual NIC subnet.' }
    if (@($Inventory.Interfaces | Where-Object Address -eq $gatewayAddress).Count) { throw 'Gateway is a local address.' }
    if ($prefix.Length -lt 31 -and ($number -eq $prefix.Network -or $number -eq ($prefix.Network -bor (4294967295L -bxor $prefix.Mask)))) { throw 'Gateway is a subnet network/broadcast address.' }
    return [pscustomobject]@{ Address = $gatewayAddress; Evidence = $evidence }
}

function Test-MultiNicRouteMatch {
    param($Actual, $Expected)
    return ($Actual.Destination -eq $Expected.Destination -and $Actual.Index -eq $Expected.Index -and $Actual.Gateway -eq $Expected.Gateway -and $Actual.Metric -eq $Expected.Metric -and $Actual.Protocol -in 'NetMgmt', '3')
}

function New-MultiNicPlan {
    [CmdletBinding()]
    param($Inventory, [string[]] $Mappings, [string[]] $Overrides = @(), [ValidateRange(1, 65535)] [int] $Metric = 42762, [switch] $Persist)
    $plan = [System.Collections.Generic.List[object]]::new()
    $selectors = [System.Collections.Generic.List[string]]::new()
    $destinations = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Overrides) {
        $parts = $entry.Split('=', 2)
        if ($parts.Count -ne 2) { throw "Invalid gateway override: $entry" }
        $interface = Resolve-MultiNicSelector $Inventory $parts[0]
        $null = Get-MultiNicGateway $Inventory $interface $Overrides
    }
    foreach ($mapping in $Mappings) {
        $parts = $mapping.Split('=', 2)
        if ($parts.Count -ne 2 -or -not $parts[1]) { throw 'Map must be NIC_CIDR=DEST1,DEST2.' }
        $selector = $parts[0]; $null = Get-IPv4Prefix $selector -Destination
        foreach ($previous in $selectors) {
            if ((Test-IPv4Contains $selector $previous.Split('/')[0]) -or (Test-IPv4Contains $previous $selector.Split('/')[0])) { throw 'Overlapping NIC selectors.' }
        }
        $selectors.Add($selector)
        $targets = $parts[1].Split(',')
        foreach ($cidr in $targets) {
            $null = Get-IPv4Prefix $cidr -Destination
            foreach ($previous in $destinations) {
                if ((Test-IPv4Contains $cidr $previous.Split('/')[0]) -or (Test-IPv4Contains $previous $cidr.Split('/')[0])) { throw 'Overlapping destination mappings.' }
            }
            $destinations.Add($cidr)
        }
        $interface = Resolve-MultiNicSelector $Inventory $selector -AllowMissing
        if (-not $interface) { Write-Warning "No actual NIC subnet matches $selector; skipping map $mapping."; continue }
        $gatewayInfo = Get-MultiNicGateway $Inventory $interface $Overrides
        foreach ($cidr in $targets) {
            foreach ($other in $Inventory.Interfaces) {
                if ($other.Index -ne $interface.Index -and (Test-IPv4Contains $cidr $other.Address)) { throw "$cidr contains another local NIC." }
            }
            $expected = [pscustomobject]@{
                Destination = $cidr; Index = [int] $interface.Index; Alias = $interface.Alias; Mac = $interface.Mac
                Source = $interface.Address; Gateway = $gatewayInfo.Address; Evidence = $gatewayInfo.Evidence; Metric = $Metric; Protocol = 'NetMgmt'
            }
            $active = @($Inventory.Routes | Where-Object Destination -eq $cidr)
            if ($active.Count -eq 1 -and $active[0].Index -eq $expected.Index -and $active[0].Gateway -eq '0.0.0.0' -and $active[0].Protocol -in 'Local', '2') { Write-Host "DIRECT $cidr stays on $($interface.Alias)."; continue }
            foreach ($storeRoutes in @(@{ Rows = @($Inventory.Routes) }, @{ Rows = @($Inventory.SavedRoutes) })) {
                $exact = @($storeRoutes.Rows | Where-Object Destination -eq $cidr)
                if ($exact.Count -gt 1 -or ($exact.Count -eq 1 -and -not (Test-MultiNicRouteMatch $exact[0] $expected))) { throw "Route collision for $cidr." }
                foreach ($route in $storeRoutes.Rows) {
                    $prefix = Get-IPv4Prefix $route.Destination
                    if ($prefix.Length -gt (Get-IPv4Prefix $cidr).Length -and (Test-IPv4Contains $cidr $route.Destination.Split('/')[0])) {
                        if ($route.Index -ne $expected.Index -or $route.Gateway -ne '0.0.0.0' -or $route.Protocol -notin 'Local', '2') { throw "More-specific route conflicts with $cidr." }
                    }
                }
            }
            if ($Persist -and $active.Count -and -not @($Inventory.SavedRoutes | Where-Object { Test-MultiNicRouteMatch $_ $expected }).Count) { throw 'An active-only route already exists. Preview and apply rollback before enabling -Persist; no automatic route replacement is performed.' }
            $plan.Add($expected)
        }
    }
    return $plan.ToArray()
}

function Get-MultiNicRouteIdentity {
    param([object[]] $Records)
    return (@($Records | ForEach-Object { "$($_.Destination)|$($_.Index)|$($_.Gateway)|$($_.Metric)|$($_.Protocol)" } | Sort-Object) -join "`n")
}

function Invoke-MultiNicRouteChanges {
    param([object[]] $Records, [switch] $Persist)
    foreach ($record in $Records) {
        $active = @(Get-MultiNicRoutes ActiveStore | Where-Object Destination -eq $record.Destination)
        $saved = @(Get-MultiNicRoutes PersistentStore | Where-Object Destination -eq $record.Destination)
        foreach ($matchesForStore in @(@{ Rows = $active }, @{ Rows = $saved })) {
            if ($matchesForStore.Rows.Count -gt 1 -or ($matchesForStore.Rows.Count -eq 1 -and -not (Test-MultiNicRouteMatch $matchesForStore.Rows[0] $record))) { throw 'Route changed during apply; partial changes may remain.' }
        }
        $arguments = @{ DestinationPrefix = $record.Destination; InterfaceIndex = $record.Index; NextHop = $record.Gateway; RouteMetric = $record.Metric; Protocol = 'NetMgmt'; AddressFamily = 'IPv4'; ErrorAction = 'Stop' }
        if ($Persist -and -not $saved.Count) {
            if ($active.Count) { throw 'Active-only route appeared during apply; no replacement performed.' }
            $null = New-NetRoute @arguments
        }
        elseif (-not $active.Count) { $null = New-NetRoute @arguments -PolicyStore ActiveStore }
        if (@(Get-MultiNicRoutes ActiveStore | Where-Object { Test-MultiNicRouteMatch $_ $record }).Count -ne 1) { throw 'Active route verification failed; partial changes may remain.' }
        if ($Persist -and @(Get-MultiNicRoutes PersistentStore | Where-Object { Test-MultiNicRouteMatch $_ $record }).Count -ne 1) { throw 'Saved route verification failed; partial changes may remain.' }
    }
}

function New-MultiNicCleanupPlan {
    param($Inventory, [ValidateSet('Rollback', 'Reset')] [string] $Operation, [ValidateRange(1, 65535)] [int] $Metric = 42762)
    $indices = @($Inventory.Interfaces | Select-Object -ExpandProperty Index -Unique)
    foreach ($store in 'PersistentStore', 'ActiveStore') {
        $rows = if ($store -eq 'ActiveStore') { @($Inventory.Routes) } else { @($Inventory.SavedRoutes) }
        foreach ($route in $rows) {
            if ($route.Index -notin $indices -or $route.Destination -eq '0.0.0.0/0' -or $route.Protocol -notin 'NetMgmt', '3') { continue }
            $null = Get-IPv4Prefix $route.Destination -Destination
            if ($Operation -eq 'Rollback' -and $route.Metric -ne $Metric) { continue }
            [pscustomobject]@{ Destination = $route.Destination; Index = $route.Index; Gateway = $route.Gateway; Metric = $route.Metric; Protocol = $route.Protocol; Store = $store }
        }
    }
}

function Invoke-MultiNicCleanup {
    param([object[]] $Records)
    foreach ($record in $Records) {
        $actual = @(Get-MultiNicRoutes $record.Store | Where-Object { $_.Destination -eq $record.Destination -and $_.Index -eq $record.Index -and $_.Gateway -eq $record.Gateway })
        if (-not $actual.Count) { continue }
        if ($actual.Count -ne 1 -or -not (Test-MultiNicRouteMatch $actual[0] $record)) { throw 'Route changed during cleanup; partial changes may remain.' }
        Remove-NetRoute -DestinationPrefix $record.Destination -InterfaceIndex $record.Index -NextHop $record.Gateway -RouteMetric $record.Metric -Protocol NetMgmt -AddressFamily IPv4 -PolicyStore $record.Store -Confirm:$false -ErrorAction Stop
        if (@(Get-MultiNicRoutes $record.Store | Where-Object { Test-MultiNicRouteMatch $_ $record }).Count) { throw 'Route removal verification failed; partial changes may remain.' }
    }
}

function Invoke-MultiNicRouting {
    param([string[]] $Mappings = @(), [string[]] $Overrides = @(), [ValidateRange(1, 65535)] [int] $Metric = 42762, [switch] $Apply, [switch] $Persist, [ValidateSet('', 'Rollback', 'Reset')] [string] $Cleanup = '', [string] $FixturePath)
    if ($Cleanup) {
        if ($Mappings.Count -or $Overrides.Count -or $Persist) { throw 'Cleanup is separate from maps, gateway overrides, and -Persist; saved routes are included automatically.' }
    }
    elseif (-not $Mappings.Count) { throw 'Supply at least one -Map NIC_CIDR=DEST1,DEST2.' }
    if ($FixturePath -and $Apply) { throw 'Offline inventory cannot be used with -Apply.' }
    if (-not $FixturePath) { Assert-MultiNicDependencies -Mutation:$Apply -Cleanup:([bool] $Cleanup) }
    if ($Apply) { Assert-MultiNicAdministrator }
    $inventory = Get-MultiNicInventory $FixturePath
    $primary = Get-MultiNicPrimary $inventory
    Write-Host "PRIMARY interface=$primary (guest default-route evidence)"
    $inventory.Interfaces | Format-Table Index, Alias, Mac, Address, PrefixLength | Out-Host
    $records = @(if ($Cleanup) { New-MultiNicCleanupPlan $inventory $Cleanup $Metric } else { New-MultiNicPlan $inventory $Mappings $Overrides $Metric -Persist:$Persist })
    if (-not $records.Count) { Write-Host 'No matching route changes. No changes made.'; return }
    if ($Cleanup) { $records | Format-Table Store, Destination, Index, Gateway, Metric -AutoSize -Wrap | Out-Host }
    else { $records | Format-Table Destination, Alias, Source, Gateway, Metric, Evidence -AutoSize -Wrap | Out-Host }
    Write-Warning 'Destination routes do not guarantee arbitrary-source reply symmetry. Verify source-bound traffic and Azure/guest firewall prerequisites.'
    if (-not $Apply) { Write-Host 'DRY RUN: No changes. Add -Apply after reviewing the plan.'; return $records }
    if ($Cleanup -and $env:SSH_CONNECTION) { throw 'Route cleanup must be run from a console, not an SSH session.' }
    $current = Get-MultiNicInventory
    foreach ($property in 'Routes', 'SavedRoutes') {
        if ((Get-MultiNicRouteIdentity @($inventory.$property)) -ne (Get-MultiNicRouteIdentity @($current.$property))) { throw 'Routes changed during planning; rerun the preview.' }
    }
    foreach ($record in $records) {
        $matching = @($current.Interfaces | Where-Object { $_.Index -eq $record.Index })
        if (-not $matching.Count) { throw 'Target interface is no longer usable.' }
        if (-not $Cleanup -and -not @($matching | Where-Object { $_.Mac -eq $record.Mac -and $_.Address -eq $record.Source }).Count) { throw 'Adapter identity/address changed during planning.' }
    }
    $defaults = Get-MultiNicRouteIdentity @($inventory.Routes | Where-Object Destination -eq '0.0.0.0/0')
    if ($Cleanup) { Invoke-MultiNicCleanup $records } else { Invoke-MultiNicRouteChanges $records -Persist:$Persist }
    $after = Get-MultiNicInventory
    if ($defaults -ne (Get-MultiNicRouteIdentity @($after.Routes | Where-Object Destination -eq '0.0.0.0/0'))) { throw 'Default routes changed; inspect concurrent configuration.' }
    Write-Host 'Completed. Only route entries were changed. Windows selects the source address; interfaces were not restarted.'
}

if (-not $LibraryOnly) {
    if ($Rollback -and $Reset) { throw 'Choose only one of -Rollback or -Reset.' }
    if ($Reset -and $PSBoundParameters.ContainsKey('Metric')) { throw '-Reset covers all custom metrics; use -Metric with -Rollback instead.' }
    $cleanupMode = if ($Rollback) { 'Rollback' } elseif ($Reset) { 'Reset' } else { '' }
    Invoke-MultiNicRouting -Mappings $Map -Overrides $Gateway -Metric $Metric -Apply:$Apply -Persist:$Persist -Cleanup $cleanupMode -FixturePath $InventoryPath
}