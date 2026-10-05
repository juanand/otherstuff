# AvZone-Latency-Test

A PowerShell tool that measures **network latency, round-trip time, throughput, packet loss and
jitter between Azure Availability Zones** in a region. It deploys one Ubuntu 26.04 LTS VM per zone
(zones 1, 2, 3), installs the measurement tools, runs a battery of tests between every zone pair,
and prints the results as tables.

> Script: [`AvZone-Latency-Test.ps1`](AvZone-Latency-Test.ps1)

Everything is in a **single script** driven by the `-Mode` parameter:

| `-Mode` | Needs Azure login / Az modules | Needs Posh-SSH | What it does |
|---------|:--:|:--:|--------------|
| `DeployAndTest` *(default)* | Yes | Yes | Deploy the three zonal VMs, run the tests, then (optionally) delete everything |
| `DeployOnly` | Yes | No | Deploy the three VMs and leave them running; print the IPs and a ready-to-run `TestOnly` command |
| `TestOnly` | **No** | Yes | Run the tests against three VMs that already exist; you pass the addresses in |

## Why TestOnly exists

`TestOnly` removes any dependency on the **Azure control plane** for the machine that drives the
measurements. It never imports the Az modules and never calls `Connect-AzAccount` /
`Select-AzSubscription`, so the controller needs **no Azure identity** — only SSH reachability to the
VMs.

This enables a clean split between the machine that has Azure rights and the machine that runs the
tests:

1. **Deploy from Azure Cloud Shell** (which already has the Az modules and a login):

   ```powershell
   ./AvZone-Latency-Test.ps1 -Mode DeployOnly -SubscriptionName "My Subscription" -region uksouth
   ```

   The script prints each VM's public and private IP plus a ready-to-run `TestOnly` command.

2. **Run the tests from a controller without Azure access** — for example one of the deployed VMs,
   or any host that can SSH to them. Copy this script there and run the printed command:

   ```powershell
   ./AvZone-Latency-Test.ps1 -Mode TestOnly -Zone1 <pub1> -Zone2 <pub2> -Zone3 <pub3> `
       -Zone1TestIp <priv1> -Zone2TestIp <priv2> -Zone3TestIp <priv3> `
       -VMLocalAdminUser azping -VMLocalAdminPassword 'P@ssw0rd!'
   ```

   When the controller reaches the VMs on one address but the VMs reach each other on another (e.g.
   public for SSH, private for the measurements), pass the SSH address as `-ZoneN` and the
   measurement address as `-ZoneNTestIp`.

## What it does

1. **(Deploy modes)** Creates a resource group, VNet/subnet, NSG (SSH only), and three zonal VMs
   with Accelerated Networking (or reuses existing ones / an existing VNet). Boot diagnostics use the
   Microsoft-managed storage account.
2. Opens SSH sessions (Posh-SSH) and installs **qperf**, **sockperf** and **iperf3** from the Ubuntu
   `universe` repo, then starts their servers.
3. Runs latency/throughput tests between all six ordered zone pairs.
4. Prints the qperf tables plus five advanced tables (sockperf + iperf3).
5. **(DeployAndTest)** Deletes the resource group unless `-DestroyAfterTest $false`.

## Requirements

- PowerShell **7.1+**
- **Deploy modes** (`DeployAndTest`, `DeployOnly`): the **Az** modules (Az.Accounts, Az.Compute,
  Az.Network), an authenticated Azure session (`Connect-AzAccount`), and quota for **3 ×** the chosen
  VM size.
- **Test modes** (`DeployAndTest`, `TestOnly`): **Posh-SSH 3.0+** and outbound SSH (22) to each VM.
  The package-install step assumes an **Ubuntu/Debian** VM with `apt` and the `universe` repo; adjust
  the install commands for other distros.

## Usage

Deploy, test, and tear down (default):

```powershell
./AvZone-Latency-Test.ps1 -SubscriptionName "My Subscription" -region uksouth
```

Deploy only, then test separately (see "Why TestOnly exists" above).

### Key parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Mode` | `DeployAndTest` | `DeployAndTest`, `DeployOnly`, or `TestOnly` |
| `-SubscriptionName` | (required for deploy modes) | Azure subscription to use |
| `-region` | `westeurope` | Azure region to deploy into (deploy modes); report label in `TestOnly` (auto-filled from IMDS) |
| `-VMSize` | `Standard_D8s_v3` | VM size (deploy modes); report label in `TestOnly` (auto-filled from IMDS) |
| `-DestroyAfterTest` | `$true` | Delete the resource group after `DeployAndTest` |
| `-UseExistingVMs` | `$false` | Reuse VMs from a previous run (deploy modes) |
| `-UseExistingVnet` | `$false` | Deploy into an existing VNet (direct SSH required) |
| `-UsePublicIPAddresses` | `$true` | Connect over public IPs |
| `-Zone1` / `-Zone2` / `-Zone3` | (required for `TestOnly`) | Address used to **SSH into** each VM |
| `-Zone1TestIp` / `-Zone2TestIp` / `-Zone3TestIp` | = the `-ZoneN` value | Address the other VMs use to **reach** each zone for the measurements |
| `-SSHKeyFilePath` | (none) | Private key file for key-based SSH auth (test modes) |
| `-testtool` | `qperf` | `qperf` or `niping` for the first latency/bandwidth tables |
| `-nipingpath` | (prompted) | Download URL for the `niping` executable (only for `-testtool niping`) |

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

1. **Sequential, single-sample.** Each zone pair is measured once, and the qperf / sockperf / iperf3
   phases run seconds-to-minutes apart — they are not a synchronized snapshot. Tails (`Max`, `P99`)
   from a single ~10 s run are noisy and not perfectly reproducible.
2. **Idle vs. under-load latency are both measured.** The sockperf idle tables show best-case latency
   on an empty pipe; the *RTT under load* table shows latency while the link is saturated
   (bufferbloat). Compare the two to judge how latency degrades under traffic.
3. **One-way = half of RTT is an assumption.** Both qperf and the sockperf one-way pass derive one-way
   latency as RTT/2, which assumes a symmetric path. Azure routing can be asymmetric, so treat one-way
   figures as approximations.
4. **Single-flow vs. aggregate throughput are both measured.** A single TCP flow is often
   CPU/single-queue bound and under-reports the VM's NIC capacity; the aggregate pass (`-P` = vCPU
   count) is a better estimate of maximum bandwidth. Neither guarantees the SKU's documented ceiling.
5. **0.1 s throughput percentiles + warm-up drop.** Percentiles come from 0.1 s interval samples;
   `-O 1` removes the first second (slow-start) from the *average*, but sub-second bursts
   (TSO/GSO/coalescing) can still make throughput `Max`/`P99` momentarily exceed the sustainable rate.
   These are **throughput** percentiles, not latency percentiles.
6. **Servers are backgrounded, not daemonized.** qperf/sockperf/iperf3 servers run via `nohup` for the
   life of the VM boot (no systemd units, no reboot persistence). If a server died, the affected metric
   would read blank/zero rather than error.
7. **Noisy-neighbour / host variance.** Azure VMs share physical hosts; latency and throughput vary
   with host load and placement and are not fully reproducible.
8. **Runtime.** The advanced phase issues ~7 SSH-driven test runs per pair (2 sockperf idle, 1
   under-load, 2 TCP, 2 UDP) × 6 pairs — budget several minutes for that phase alone.

## Realistic vs. artificial measurements

**Trustworthy / realistic**

- **qperf latency, sockperf idle one-way avg, sockperf idle RTT avg + P90/P99** — best-case idle
  latency and its tail.
- **RTT under load (bufferbloat)** — a real, useful signal of latency degradation under saturation.
- **iperf3 TCP single-flow avg** — realistic single-connection throughput (warm-up excluded).
- **iperf3 TCP aggregate** — realistic near-max throughput for the VM using parallel streams.
- **TCP retransmits** — a genuine path-quality signal.
- **iperf3 UDP baseline loss/jitter (100 Mbps)** — organic loss/jitter on a non-saturated path.

**Artificial / interpret with caution**

- **iperf3 UDP *saturation* loss/jitter** — the most artificial metric. UDP is open-loop and we
  deliberately send at ~the TCP rate, so any loss is *load-induced by that chosen rate*, not a natural
  loss rate. Read it as "loss when blasting UDP at ~line rate", and compare it against the baseline
  column.
- **One-way latency values** — approximations (symmetric-path assumption).
- **Throughput `P99`/`Max`** — can be inflated by sub-second bursts at 0.1 s granularity.
- **Single 10 s sample** — tails vary run-to-run; average several runs for stability if needed.

## Notes

- iperf3 has no latency measurement, so **latency percentiles come from sockperf**; iperf3 percentiles
  are **throughput** percentiles.
- sockperf's fixed percentile set provides **P90 and P99 but not P95**.
- `qperf tcp_lat` reports roughly one-way latency (~half the round trip); the sockperf idle one-way
  table is directly comparable, and the full-RTT table is roughly double it.

## Related

- [`AvZone-Latency-SameZone`](../AvZone-Latency-SameZone/README.md) — same idea for **two VMs inside a
  single zone**, with or without a Proximity Placement Group.
