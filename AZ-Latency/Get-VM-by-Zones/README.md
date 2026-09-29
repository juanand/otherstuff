# Get VMs available in zones

## Fix: per-subscription zone restrictions (v0.3)

Earlier versions of the script read only `LocationInfo.Zones` from `Get-AzComputeResourceSku`.
That property lists the zones a SKU exists in **for the region in general** — it does **not**
reflect **per-subscription restrictions**. As a result the script could show a size as available
in zones 1, 2 and 3 even though your subscription can only deploy it in zone 1 (the portal would
say *"This size is not available in zone X. Zones '1' are supported"*).

The accurate per-subscription availability lives in the SKU's separate `Restrictions` property.
A SKU can list `LocationInfo.Zones = 1,2,3` while also carrying a restriction like:

* `Type = Zone`, `RestrictionInfo.Zones = 2,3`, `ReasonCode = NotAvailableForSubscription`

which means only zone 1 is actually usable for that subscription.

The script now computes the **effective** zones = `LocationInfo.Zones` **minus** any zones listed
in `Restrictions` of `Type = Zone`, and treats a `Type = Location` restriction as "not available at
all in this region for this subscription". The output now matches what the portal allows.

> **Caveat:** `Restrictions` covers the `NotAvailableForSubscription` / quota cases (what most
> people hit). It does **not** predict transient capacity/allocation failures where a zone has the
> SKU enabled but is temporarily out of capacity at deploy time — no SKU-listing API does. To
> inspect the raw restrictions for a single size:
>
> ```powershell
> Get-AzComputeResourceSku -Location westeurope |
>     Where-Object { $_.Name -eq 'Standard_D8ads_v5' } |
>     Select-Object -ExpandProperty Restrictions |
>     Format-List Type, ReasonCode,
>         @{n='Zones';e={$_.RestrictionInfo.Zones -join ','}},
>         @{n='Locations';e={$_.RestrictionInfo.Locations -join ','}}
> ```

## Availability Zones

[Availability Zones](https://docs.microsoft.com/en-us/azure/availability-zones/az-overview) provide different datacenter with independent cooling, power and network within one Azure Region.

Every Azure Subscription gets three zones, it is important to understand that we mix the real datacenters with the assigned zones every time you create a new subscription.

To learn more about SAP and Availability Zones visit our [documentation](https://docs.microsoft.com/en-us/azure/virtual-machines/workloads/sap/sap-ha-availability-zones).

## Get VMs

Not every zone runs every type of VM and as the zones get mixed for every subscription you can use the script to show which VM types are available in which zone.

**requirements:**

* Azure Subscription
* PowerShell 5.1 or newer
* PowerShell module Az

### Sample Output

        VM Type       Zone 1 Zone 2 Zone 3
        -------       ------ ------ ------
        E16_v3        X      X      X
        E16-4s_v3     X      X      X
        E16-8s_v3     X      X      X
        E16s_v3       X      X      X
        E2_v3         X      X      X
        E20_v3        X      X      X
        E20s_v3       X      X      X
        E2s_v3        X      X      X
        E32_v3        X      X      X
        E32-16s_v3    X      X      X
        E32-8s_v3     X      X      X
        E32s_v3       X      X      X
        E4_v3         X      X      X
        E4-2s_v3      X      X      X
        E48_v3        X      X      X
        E48s_v3       X      X      X
        E4s_v3        X      X      X
        E64_v3        X      X      X
        E64-16s_v3    X      X      X
        E64-32s_v3    X      X      X
        E64i_v3       X      X      X
        E64is_v3      X      X      X
        E64s_v3       X      X      X
        E8_v3         X      X      X
        E8-2s_v3      X      X      X
        E8-4s_v3      X      X      X
        E8s_v3        X      X      X
        M128          X      X      X
        M128-32ms     X      X      X
        M128-64ms     X      X      X
        M128m         X      X      X
        M128ms        X      X      X
        M128s         X      X      X
        M16-4ms       X      X      X
        M16-8ms       X      X      X
        M16ms         X      X      X
        M208ms_v2     X             X
        M208s_v2      X             X
        M32-16ms      X      X      X
        M32-8ms       X      X      X
        M32ls         X      X      X
        M32ms         X      X      X
        M32ts         X      X      X
        M416ms_v2     X             X
        M416s_v2      X             X
        M64           X      X      X
        M64-16ms      X      X      X
        M64-32ms      X      X      X
        M64ls         X      X      X
        M64m          X      X      X
        M64ms         X      X      X
        M64s          X      X      X
        M8-2ms        X      X      X
        M8-4ms        X      X      X
        M8ms          X      X      X
```

Based on the output you can decide which zones to use.
