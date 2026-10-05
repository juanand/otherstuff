# AvZone-Latency-SameZone

Measures **network latency, round-trip time, throughput, packet loss and jitter between two VMs
placed in the SAME Azure Availability Zone**, optionally pinned to the same **Proximity Placement
Group (PPG)**. It is the same-zone counterpart to
[`AvZone-Latency-Test`](../AvZone-Latency-Test/README.md), which measures *across* zones.

Running the deploy both ways - same zone *without* a PPG and same zone *with* a PPG - lets you
quantify how much extra latency reduction a PPG buys you inside a single zone.

> Script: [`AvZone-Latency-SameZone.ps1`](AvZone-Latency-SameZone.ps1)

Everything is in a **single script** driven by the `-Mode` parameter:

| `-Mode` | Needs Azure login / Az modules | Needs Posh-SSH | What it does |
|---------|:--:|:--:|--------------|
| `DeployAndTest` *(default)* | Yes | Yes | Deploy the two same-zone VMs, run the tests, then (optionally) delete everything |
| `DeployOnly` | Yes | No | Deploy the two VMs and leave them running; print the IPs and a ready-to-run `TestOnly` command |
| `TestOnly` | **No** | Yes | Run the tests against two VMs that already exist; you pass the addresses in |

The report always covers the **vm 1 ↔ vm 2** pair in **both directions**.

## Why TestOnly exists

`TestOnly` removes any dependency on the **Azure control plane** for the machine that drives the
measurements. It never imports the Az modules and never calls `Connect-AzAccount` /
`Select-AzSubscription`, so the controller needs **no Azure identity** — only SSH reachability to the
VMs.

This enables a clean split between the machine that has Azure rights and the machine that runs the
tests:

1. **Deploy from Azure Cloud Shell** (which already has the Az modules and a login):

   ```powershell
   ./AvZone-Latency-SameZone.ps1 -Mode DeployOnly -SubscriptionName "My Subscription" -region uksouth -Zone 1 -UseProximityPlacementGroup $true
   ```

   The script prints each VM's public and private IP plus a ready-to-run `TestOnly` command.

2. **Run the tests from a controller without Azure access** — for example one of the deployed VMs,
   or any host that can SSH to them. Copy this script there and run the printed command:

   ```powershell
   ./AvZone-Latency-SameZone.ps1 -Mode TestOnly -VM1 <pub1> -VM2 <pub2> `
       -VM1TestIp <priv1> -VM2TestIp <priv2> `
       -VMLocalAdminUser azping -VMLocalAdminPassword 'P@ssw0rd!'
   ```

   When the controller reaches the VMs on one address but the VMs reach each other on another (e.g.
   public for SSH, private for the measurements), pass the SSH address as `-VMn` and the measurement
   address as `-VMnTestIp`. In `TestOnly` the script reads each VM's IMDS zone in-guest over SSH and
   warns if the two VMs are not actually in the same zone.

## What it does

1. **(Deploy modes)** Creates a resource group, VNet/subnet, NSG (SSH only), optionally a **Proximity
   Placement Group**, and two VMs **in the same zone** with Accelerated Networking. Boot diagnostics
   use the Microsoft-managed storage account.
2. Opens SSH sessions (Posh-SSH) and installs **qperf**, **sockperf** and **iperf3** from the Ubuntu
   `universe` repo, then starts their servers.
3. Runs latency/throughput tests between the two VMs in both directions (vm1→vm2 and vm2→vm1).
4. Prints the qperf tables plus five advanced tables (sockperf + iperf3).
5. **(DeployAndTest)** Deletes the resource group unless `-DestroyAfterTest $false`.

## Requirements

- PowerShell **7.1+**
- **Deploy modes** (`DeployAndTest`, `DeployOnly`): the **Az** modules (Az.Accounts, Az.Compute,
  Az.Network), an authenticated Azure session (`Connect-AzAccount`), and quota for **2 ×** the chosen
  VM size in the chosen zone.
- **Test modes** (`DeployAndTest`, `TestOnly`): **Posh-SSH 3.0+** and outbound SSH (22) to each VM.
  The package-install step assumes an **Ubuntu/Debian** VM with `apt` and the `universe` repo; adjust
  the install commands for other distros.

## Usage

Same zone, no PPG — deploy, test, tear down:

```powershell
./AvZone-Latency-SameZone.ps1 -SubscriptionName "My Subscription" -region uksouth -Zone 1
```

Same zone **with** a Proximity Placement Group:

```powershell
./AvZone-Latency-SameZone.ps1 -SubscriptionName "My Subscription" -region uksouth -Zone 1 -UseProximityPlacementGroup $true
```

### Key parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Mode` | `DeployAndTest` | `DeployAndTest`, `DeployOnly`, or `TestOnly` |
| `-SubscriptionName` | (required for deploy modes) | Azure subscription to use |
| `-region` | `westeurope` | Azure region to deploy into (deploy modes); report label in `TestOnly` (auto-filled from IMDS) |
| `-Zone` | `1` | Availability Zone (`1`/`2`/`3`) both VMs are deployed into (deploy modes) |
| `-UseProximityPlacementGroup` | `$false` | Deploy both VMs into a single PPG (deploy modes) |
| `-VMSize` | `Standard_D8s_v3` | VM size (deploy modes); report label in `TestOnly` (auto-filled from IMDS) |
| `-DestroyAfterTest` | `$true` | Delete the resource group after `DeployAndTest` |
| `-UseExistingVMs` | `$false` | Reuse VMs from a previous run (deploy modes) |
| `-UseExistingVnet` | `$false` | Deploy into an existing VNet (direct SSH required) |
| `-UsePublicIPAddresses` | `$true` | Connect over public IPs |
| `-VM1` / `-VM2` | (required for `TestOnly`) | Address used to **SSH into** each VM |
| `-VM1TestIp` / `-VM2TestIp` | = the `-VMn` value | Address the other VM uses to **reach** each VM for the measurements |
| `-SSHKeyFilePath` | (none) | Private key file for key-based SSH auth (test modes) |
| `-testtool` | `qperf` | `qperf` or `niping` for the first latency/bandwidth tables |
| `-nipingpath` | (prompted) | Download URL for the `niping` executable (only for `-testtool niping`) |

## Same zone vs. same zone + PPG

- **Same zone only** — both VMs are guaranteed to be in the same Availability Zone (one of possibly
  several physical datacenters that make up that zone), but the platform is free to place them in
  different datacenters/halls within the zone.
- **Same zone + Proximity Placement Group** — the PPG additionally asks the platform to co-locate the
  VMs as physically close as possible (same datacenter network), which usually lowers the idle latency
  further. Not every VM size / zone combination can always be satisfied inside a PPG, so deployment can
  fail with a placement error if capacity is tight.

Run the deploy once with `-UseProximityPlacementGroup $false` and once with `$true` (same `-Zone`) and
compare the two reports to see the PPG benefit.

## What it measures

| Tool | Metric | Notes |
|------|--------|-------|
| **qperf** | one-way latency (`tcp_lat`), single-stream bandwidth (`tcp_bw`, MB/s) | first two tables |
| **sockperf** | idle **one-way** latency and idle **full RTT** (avg / P90 / P99 / Max) | UDP ping-pong, small messages |
| **sockperf** | **RTT under load** (avg + P99) | RTT sampled *while* an iperf3 TCP transfer saturates the link (bufferbloat) |
| **iperf3 TCP** | **single-flow** throughput (avg / P90 / P99 / Max, MB/s) + **retransmits** | `-O 1` drops TCP slow-start from the average; percentiles from 0.1 s samples |
| **iperf3 TCP** | **aggregate** throughput (MB/s) | one stream per vCPU (`-P nproc`); approaches the VM's NIC cap |
| **iperf3 UDP** | packet loss % and jitter (ms) at a **baseline** rate (100 Mbps) | organic loss on a non-saturated path |
| **iperf3 UDP** | throughput, packet loss % and jitter at **saturation** (~the TCP rate) | load-induced loss |

All throughput is reported in **MB/sec (bytes)** to line up with qperf's `tcp_bw` table.

## Methodology caveats

The measurement methodology, caveats, and "realistic vs. artificial" guidance match the cross-zone
tool — see the [AvZone-Latency-Test README](../AvZone-Latency-Test/README.md) for the full discussion.
The only structural difference here is that there is a **single VM pair measured in both directions**
instead of six ordered zone pairs.
