# AvZone-Latency-Test-NoAzure

A **standalone, "tests only"** fork of [`AvZone-Latency-Test`](../AvZone-Latency-Test/README.md).
It measures **network latency, round-trip time, throughput, packet loss and jitter between three
pre-existing Linux VMs** (typically one per Azure Availability Zone), but it **does not deploy any
infrastructure** and has **no dependency on the Azure control plane**.

The controller running this script needs **no Azure identity**: it never imports the Az PowerShell
modules and never calls `Connect-AzAccount` / `Select-AzSubscription`. You create the three VMs
yourself, out of band, and pass their addresses in.

> Script: [`AvZone-Latency-Test-NoAzure.ps1`](AvZone-Latency-Test-NoAzure.ps1)

## How it differs from the original

| | `AvZone-Latency-Test` | `AvZone-Latency-Test-NoAzure` (this) |
|---|---|---|
| Deploys VMs / VNet / NSG | Yes | **No** – you create the VMs |
| Requires `Az.Compute` | Yes | **No** |
| Requires Azure login | Yes | **No** |
| Requires `Posh-SSH` | Yes | Yes |
| Tears down resources afterwards | Yes (optional) | No (nothing to tear down) |
| qperf / sockperf / iperf3 tests | Yes | Yes (identical) |

## What it does

1. Opens SSH sessions (Posh-SSH) to the three VMs you supply.
2. Installs **qperf**, **sockperf** and **iperf3** from the Ubuntu `universe` repo and starts
   their servers.
3. Runs latency/throughput tests between all six ordered zone pairs.
4. Prints qperf tables plus five advanced tables (sockperf + iperf3).
5. Closes the SSH sessions.

## Requirements

- PowerShell **7.1+**
- Module: **Posh-SSH 3.0+** (no Az modules)
- Three reachable Linux VMs with the same SSH credentials. The package-install step assumes an
  **Ubuntu/Debian** VM with `apt` and the `universe` repo (matching the original). Adjust the
  install commands for other distros.
- Outbound SSH (22) from the controller to each VM's connection address.

## Usage

```powershell
./AvZone-Latency-Test-NoAzure.ps1 -Zone1 20.1.1.10 -Zone2 20.1.1.11 -Zone3 20.1.1.12 `
    -VMLocalAdminUser azping -VMLocalAdminPassword 'P@ssw0rd!'
```

If the VMs are reached over a public IP but must test each other over a private IP, pass the
private addresses separately:

```powershell
./AvZone-Latency-Test-NoAzure.ps1 -Zone1 20.1.1.10 -Zone2 20.1.1.11 -Zone3 20.1.1.12 `
    -Zone1TestIp 10.0.0.4 -Zone2TestIp 10.0.0.5 -Zone3TestIp 10.0.0.6 `
    -VMLocalAdminUser azping -VMLocalAdminPassword 'P@ssw0rd!'
```

Key-based authentication instead of a password:

```powershell
./AvZone-Latency-Test-NoAzure.ps1 -Zone1 vm1 -Zone2 vm2 -Zone3 vm3 `
    -VMLocalAdminUser azping -SSHKeyFilePath ~/.ssh/id_rsa
```

## Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Zone1` / `-Zone2` / `-Zone3` | (required) | IP address or host name used to **SSH into** each VM |
| `-Zone1TestIp` / `-Zone2TestIp` / `-Zone3TestIp` | = the `-ZoneN` value | Address the other VMs use to **reach** each zone for the measurements (e.g. the private IP) |
| `-VMLocalAdminUser` | `azping` | SSH user name (same on all three VMs) |
| `-VMLocalAdminPassword` | `P@ssw0rd!` | SSH password (ignored when `-SSHKeyFilePath` is used) |
| `-SSHKeyFilePath` | (none) | Private key file for key-based SSH auth |
| `-testtool` | `qperf` | `qperf` or `niping` for the first latency/bandwidth tables |
| `-nipingpath` | (prompted) | Download URL for the `niping` executable (only for `-testtool niping`) |
| `-Region` | `(not specified)` | Free-text label for the report header only |
| `-VMSize` | `(not specified)` | Free-text label for the report header only |

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

The measurement methodology, caveats, and "realistic vs. artificial" guidance are identical to the
original — see the [parent README](../AvZone-Latency-Test/README.md) for the full discussion.
