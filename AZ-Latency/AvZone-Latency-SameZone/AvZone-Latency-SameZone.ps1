<#

.SYNOPSIS
    Deploys two VMs in the SAME Availability Zone (optionally in one Proximity Placement Group)
    and/or measures network latency and bandwidth between them.

.DESCRIPTION
    This single script covers the full lifecycle through the -Mode parameter:

        DeployAndTest (default) : deploy two VMs into one Availability Zone, run the tests, and
                                  optionally delete everything afterwards.
        DeployOnly              : deploy the two VMs only and leave them running. Prints the
                                  public/private IPs and a ready-to-run "-Mode TestOnly" command.
        TestOnly                : run the tests against two VMs that already exist. No Azure
                                  deployment, no Az modules, and no Azure control-plane access or
                                  identity are required - you pass the VM addresses in.

    Both VMs are pinned to the Availability Zone chosen with -Zone. With
    -UseProximityPlacementGroup $true the script also creates a Proximity Placement Group and
    deploys both VMs into it, so they are co-located as closely as the platform allows (same zone
    AND same PPG). Running the deploy both ways - same zone with and without a PPG - lets you
    quantify the latency benefit a PPG provides inside one zone.

    The TestOnly mode exists so the controller that drives the measurements does not need to talk
    to the Azure control plane. A typical split workflow is:

        1. From Azure Cloud Shell (which has the Az modules and a login), run -Mode DeployOnly to
           create the VMs.
        2. Copy this script onto a controller that only has SSH reachability to the VMs (for
           example one of the VMs itself) and run -Mode TestOnly with the printed addresses.

    The VMs run Ubuntu 26.04 LTS. The measurement tools are installed over SSH (Posh-SSH):

        qperf    : one-way latency (tcp_lat) and bandwidth (tcp_bw)
        sockperf : idle one-way latency, idle full round-trip RTT, and RTT under load (bufferbloat)
        iperf3   : TCP single-flow throughput (avg/P90/P99/max + retransmits), TCP aggregate
                   throughput over one stream per vCPU, and UDP packet loss / jitter at a baseline
                   rate and at saturation

.PARAMETER Mode
    DeployAndTest (default), DeployOnly, or TestOnly. See the description for what each does.

.PARAMETER SubscriptionName
    Azure Subscription Name. Required for DeployAndTest and DeployOnly; ignored for TestOnly.

.PARAMETER region
    The Azure region to deploy into (DeployAndTest / DeployOnly). In TestOnly it is only a report
    header label and is auto-filled from the first VM's IMDS data when not supplied.

.PARAMETER Zone
    The Availability Zone (1, 2 or 3) both VMs are deployed into (deploy modes).

.PARAMETER UseProximityPlacementGroup
    When $true, create a Proximity Placement Group and deploy both VMs into it (deploy modes).

.PARAMETER VM1
    TestOnly: IP address or host name used to SSH into the first VM.

.PARAMETER VM2
    TestOnly: IP address or host name used to SSH into the second VM.

.PARAMETER VM1TestIp
    TestOnly: optional address VM2 uses to reach VM1 for the measurements (e.g. the private IP).
    Defaults to -VM1 when omitted.

.PARAMETER VM2TestIp
    TestOnly: optional address VM1 uses to reach VM2. Defaults to -VM2 when omitted.

.PARAMETER SSHKeyFilePath
    Optional path to a private key file for key-based SSH authentication.

.EXAMPLE
    ./AvZone-Latency-SameZone.ps1 -SubscriptionName "My Subscription" -region westeurope -Zone 1

    Deploys two VMs in zone 1 (no PPG), measures between them, and tears them down.

.EXAMPLE
    ./AvZone-Latency-SameZone.ps1 -SubscriptionName "My Subscription" -region westeurope -Zone 1 -UseProximityPlacementGroup $true

    Deploys two VMs in zone 1 inside a single Proximity Placement Group and measures between them.

.EXAMPLE
    ./AvZone-Latency-SameZone.ps1 -Mode DeployOnly -SubscriptionName "My Subscription" -region westeurope -Zone 1

    Deploys the two VMs and leaves them running, printing a TestOnly command to use next.

.EXAMPLE
    ./AvZone-Latency-SameZone.ps1 -Mode TestOnly -VM1 20.1.1.10 -VM2 20.1.1.11 `
        -VM1TestIp 10.0.0.4 -VM2TestIp 10.0.0.5 `
        -VMLocalAdminUser azping -VMLocalAdminPassword 'P@ssw0rd!'

    Runs the tests against two already-deployed VMs with no Azure access.

.LINK
    https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities

.NOTES
    Ubuntu 26.04 LTS, tools installed via apt (qperf / sockperf / iperf3), boot diagnostics on the
    Microsoft-managed storage account. Reports the vm 1 <-> vm 2 pair in both directions.

#>
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.
#>

#Requires -Version 7.1

param(
    #Which phase(s) to run: deploy + test, deploy only, or test only
    [ValidateSet("DeployAndTest","DeployOnly","TestOnly")][string]$Mode = "DeployAndTest",
    #Azure Subscription Name (required for DeployAndTest / DeployOnly)
    [string]$SubscriptionName,
    #Azure Region, use Get-AzLocation to get region names
    [string]$region = "westeurope",
    #Availability Zone both VMs are deployed into
    [ValidateSet("1","2","3")][string]$Zone = "1",
    #Deploy both VMs into a single Proximity Placement Group
    [boolean]$UseProximityPlacementGroup = $false,
    #Resource Group Name that will be created
    [string]$ResourceGroupName = "AvZoneLatencySameZone",
    #Delete the test environment after test (DeployAndTest only)
    [boolean]$DestroyAfterTest = $true,
    #Use an existing VNET, direct SSH connection to VMs required
    [boolean]$UseExistingVnet = $false,
    #use existing VMs of a previous test
    [boolean]$UseExistingVMs = $false,
    #use public IP addresses to connect
    [boolean]$UsePublicIPAddresses = $true,
    # VM type, recommended Standard_D8s_v3
    [string]$VMSize = "Standard_D8s_v3",
    #OS provider, for Ubuntu it is Canonical
    [string]$OSPublisher = "Canonical",
    #OS Type
    [string]$OSOffer = "ubuntu-26_04-lts",
    #OS Verion
    [string]$OSSku = "server",
    #Latest OS image
    [string]$OSVersion = "latest",
    #OS username
    [string]$VMLocalAdminUser = "azping",
    #OS password
    [string]$VMLocalAdminPassword = "P@ssw0rd!",
    #VM name prefix, 1,2 will be added based on VM index
    [string]$VMPrefix = "azping-vm0",
    #Proximity Placement Group name
    [string]$PPGName = "azping-ppg",
    #VM nic name
    [string]$NICPostfix = "-nic1",
    #Public IP address postfix
    [string]$pippostfix = "-pip",
    #Azure Network Security Group (NSG) name
    [string]$NSGName = "azping-nsg",
    #Azure VNET name, if using existing VNET
    [string]$NetworkName = "azping-mgmt-vnet",
    #Azure Subnet name, if using exising
    [string]$SubnetName = "default",
    #Resource Group Name of existing VNET
    [string]$ResourceGroupNameNetwork = "azping-mgmt",
    #Azure IP Subnet prefix if using public IP to VNET creation
    [string]$SubnetAddressPrefix = "10.1.1.0/24",
    #Azure IP VNET prefix if using public IP to VNET creation
    [string]$VnetAddressPrefix = "10.1.1.0/24",
    #TestOnly: address used to SSH into the first VM
    [string]$VM1,
    #TestOnly: address used to SSH into the second VM
    [string]$VM2,
    #TestOnly: address VM2 uses to reach VM1 (defaults to $VM1)
    [string]$VM1TestIp,
    #TestOnly: address VM1 uses to reach VM2 (defaults to $VM2)
    [string]$VM2TestIp,
    #Optional private key file for key-based SSH authentication
    [string]$SSHKeyFilePath,
    #decide to use qperf or niping
    [ValidateSet("qperf","niping")][string]$testtool = "qperf",
    #path to niping
    [string]$nipingpath
)


Function Get-Percentile {
    # Nearest-rank percentile of a numeric array; returns $null for an empty input.
    [CmdletBinding()]
    Param (
        [double[]] $Values,
        [double]   $Percentile
    )
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $rank = [math]::Ceiling(($Percentile / 100) * $sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $sorted.Count) { $rank = $sorted.Count }
    return $sorted[$rank - 1]
}


Function Get-AdvancedNetworkStats {
    # From the source VM's SSH session, measures latency and throughput to the target IP:
    #   sockperf : idle one-way latency, idle full RTT, and RTT under load (bufferbloat);
    #   iperf3   : TCP single-flow throughput (avg/P90/P99/max, warm-up dropped via -O 1) plus
    #              retransmits, and aggregate throughput over N=cores parallel streams (-P);
    #              UDP loss/jitter at a baseline rate (organic) and at ~the TCP rate (saturation).
    # Latency percentiles are P90/P99 (sockperf has no P95); throughput percentiles are per-0.1s.
    [CmdletBinding()]
    Param (
        [int]    $SessionId,
        [string] $TargetIp,
        [string] $FromLabel,
        [string] $ToLabel,
        [int]    $Cores = 1
    )

    # sockperf idle latency: one-way (default) then full round-trip (--full-rtt)
    $spOne  = Invoke-SSHCommand -Command "sockperf ping-pong -i $TargetIp -t 10" -SessionId $SessionId -TimeOut 60
    $owText = $spOne.Output -join "`n"
    $owAvg = if ($owText -match '(?:Round trip|Latency) is\s+([\d\.]+)') { [math]::Round([double]$Matches[1], 2) } else { $null }
    $owP90 = if ($owText -match 'percentile 90\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $owP99 = if ($owText -match 'percentile 99\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $owMax = if ($owText -match '<MAX> observation\s*=\s*([\d\.]+)')       { [math]::Round([double]$Matches[1], 2) } else { $null }

    $spRtt   = Invoke-SSHCommand -Command "sockperf ping-pong -i $TargetIp -t 10 --full-rtt" -SessionId $SessionId -TimeOut 60
    $rttText = $spRtt.Output -join "`n"
    $rttAvg = if ($rttText -match '(?:Round trip|Latency) is\s+([\d\.]+)') { [math]::Round([double]$Matches[1], 2) } else { $null }
    $rttP90 = if ($rttText -match 'percentile 90\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $rttP99 = if ($rttText -match 'percentile 99\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $rttMax = if ($rttText -match '<MAX> observation\s*=\s*([\d\.]+)')       { [math]::Round([double]$Matches[1], 2) } else { $null }

    # RTT under load (bufferbloat): sockperf full RTT while an iperf3 TCP transfer saturates the link
    $spLoad   = Invoke-SSHCommand -Command "sh -c 'nohup iperf3 -c $TargetIp -t 14 >/dev/null 2>&1 & sleep 1; sockperf ping-pong -i $TargetIp -t 10 --full-rtt; wait'" -SessionId $SessionId -TimeOut 90
    $loadText = $spLoad.Output -join "`n"
    $loadRttAvg = if ($loadText -match '(?:Round trip|Latency) is\s+([\d\.]+)') { [math]::Round([double]$Matches[1], 2) } else { $null }
    $loadRttP99 = if ($loadText -match 'percentile 99\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }

    # iperf3 TCP single-flow: steady-state throughput (-O 1 drops slow start) + retransmits + 0.1s percentiles
    $ipTcp = Invoke-SSHCommand -Command "iperf3 -c $TargetIp -t 10 -O 1 -i 0.1 -J" -SessionId $SessionId -TimeOut 60
    $tcp1Avg = $null; $tcp1P90 = $null; $tcp1P99 = $null; $tcp1Max = $null; $tcpRetr = $null; $tcpMbps = $null
    try {
        $j = ($ipTcp.Output -join "`n") | ConvertFrom-Json
        if ($j.end.sum_received.bits_per_second) {
            $tcpMbps = $j.end.sum_received.bits_per_second / 1e6
            $tcp1Avg = [math]::Round($j.end.sum_received.bits_per_second / 8e6, 1)
        }
        if ($null -ne $j.end.sum_sent.retransmits) { $tcpRetr = [int]$j.end.sum_sent.retransmits }
        $samples = @($j.intervals | Where-Object { -not $_.sum.omitted } | ForEach-Object { $_.sum.bits_per_second / 8e6 })
        if ($samples.Count) {
            $tcp1P90 = [math]::Round((Get-Percentile -Values $samples -Percentile 90), 1)
            $tcp1P99 = [math]::Round((Get-Percentile -Values $samples -Percentile 99), 1)
            $tcp1Max = [math]::Round(($samples | Measure-Object -Maximum).Maximum, 1)
        }
    }
    catch { }

    # iperf3 TCP aggregate over N=cores parallel streams (approaches the VM's NIC cap)
    $tcpAgg = $tcp1Avg
    if ($Cores -gt 1) {
        $ipAgg = Invoke-SSHCommand -Command "iperf3 -c $TargetIp -t 10 -O 1 -P $Cores -J" -SessionId $SessionId -TimeOut 60
        try {
            $ja = ($ipAgg.Output -join "`n") | ConvertFrom-Json
            if ($ja.end.sum_received.bits_per_second) { $tcpAgg = [math]::Round($ja.end.sum_received.bits_per_second / 8e6, 1) }
        }
        catch { }
    }

    # iperf3 UDP baseline at a fixed low rate (organic loss/jitter, non-saturating)
    $ipUdpB = Invoke-SSHCommand -Command "iperf3 -c $TargetIp -u -b 100M -t 10 -J" -SessionId $SessionId -TimeOut 60
    $udpbLoss = $null; $udpbJit = $null
    try {
        $jb = ($ipUdpB.Output -join "`n") | ConvertFrom-Json
        if ($null -ne $jb.end.sum.lost_percent) { $udpbLoss = [math]::Round([double]$jb.end.sum.lost_percent, 3) }
        if ($null -ne $jb.end.sum.jitter_ms)    { $udpbJit  = [math]::Round([double]$jb.end.sum.jitter_ms, 3) }
    }
    catch { }

    # iperf3 UDP saturation at ~the single-flow TCP rate (load-induced loss/jitter)
    $udpRate = if ($tcpMbps) { [int][math]::Ceiling($tcpMbps) } else { 1000 }
    $ipUdpS = Invoke-SSHCommand -Command "iperf3 -c $TargetIp -u -b ${udpRate}M -t 10 -J" -SessionId $SessionId -TimeOut 60
    $udpsAvg = $null; $udpsLoss = $null; $udpsJit = $null
    try {
        $js = ($ipUdpS.Output -join "`n") | ConvertFrom-Json
        if ($js.end.sum.bits_per_second) { $udpsAvg = [math]::Round($js.end.sum.bits_per_second / 8e6, 1) }
        if ($null -ne $js.end.sum.lost_percent) { $udpsLoss = [math]::Round([double]$js.end.sum.lost_percent, 3) }
        if ($null -ne $js.end.sum.jitter_ms)    { $udpsJit  = [math]::Round([double]$js.end.sum.jitter_ms, 3) }
    }
    catch { }

    [PSCustomObject]@{
        From             = $FromLabel
        To               = $ToLabel
        'OWAvg(us)'      = $owAvg
        'OWP90(us)'      = $owP90
        'OWP99(us)'      = $owP99
        'OWMax(us)'      = $owMax
        'RTTAvg(us)'     = $rttAvg
        'RTTP90(us)'     = $rttP90
        'RTTP99(us)'     = $rttP99
        'RTTMax(us)'     = $rttMax
        'LoadRTTavg(us)' = $loadRttAvg
        'LoadRTTp99(us)' = $loadRttP99
        'TCP1avg(MB/s)'  = $tcp1Avg
        'TCP1p90(MB/s)'  = $tcp1P90
        'TCP1p99(MB/s)'  = $tcp1P99
        'TCP1max(MB/s)'  = $tcp1Max
        'Retr'           = $tcpRetr
        'TCPagg(MB/s)'   = $tcpAgg
        'UDPbLoss(%)'    = $udpbLoss
        'UDPbJit(ms)'    = $udpbJit
        'UDPsAvg(MB/s)'  = $udpsAvg
        'UDPsLoss(%)'    = $udpsLoss
        'UDPsJit(ms)'    = $udpsJit
    }
}


Function Write-Result {
    # Writes a results line to the console (as before) and also appends it to the results file.
    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeline = $true, Position = 0)] $Message = ""
    )
    process {
        $text = [string]$Message
        Write-Host $text
        if ($script:ResultLogPath) { Add-Content -Path $script:ResultLogPath -Value $text }
    }
}

    # path of the timestamped results file; set at the start of the test phase
    $script:ResultLogPath = $null

    # work out which capabilities this mode needs
    $needAzure = $Mode -in @("DeployAndTest","DeployOnly")
    $needSSH   = $Mode -in @("DeployAndTest","TestOnly")

    # verify the required tooling is present for the chosen mode (no hard #Requires so the
    # TestOnly controller does not need the Az modules installed)
    if ($needAzure -and -not (Get-Command New-AzVM -ErrorAction SilentlyContinue)) {
        Write-Host -ForegroundColor Red "The Az modules (Az.Accounts, Az.Compute, Az.Network) are required for -Mode $Mode. Install them with: Install-Module Az"
        exit
    }
    if ($needSSH -and -not (Get-Command New-SSHSession -ErrorAction SilentlyContinue)) {
        Write-Host -ForegroundColor Red "The Posh-SSH 3.0+ module is required for -Mode $Mode. Install it with: Install-Module Posh-SSH"
        exit
    }

    if ($needSSH -and $testtool -eq "niping") {
        if (!$nipingpath) {
            $nipingpath = Read-Host -Prompt "Please enter download path for niping executable: "
        }
    }

    # two VMs in the same zone
    $vmcount = 2
    $VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force
    #create the secure credential object
    $Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword);

    # initialize the output arrays (index 0 = vm1->vm2, index 1 = vm2->vm1)
    $latency = @("0","0")
    $bandwidth = @("0","0")

    # connect to Azure for the modes that touch the control plane
    if ($needAzure) {
        if (-not $SubscriptionName) {
            Write-Host -ForegroundColor Red "-SubscriptionName is required for -Mode $Mode."
            exit
        }

        $breakingchangewarning = Get-AzConfig -DisplayBreakingChangeWarning
        if ($breakingchangewarning.Value -eq $true) {
            Update-AzConfig -DisplayBreakingChangeWarning $false
        }

        # select subscription
        $Subscription = Get-AzSubscription -SubscriptionName $SubscriptionName
        if (-Not $Subscription) {
            Write-Host -ForegroundColor Red -BackgroundColor White "Sorry, it seems you are not connected to Azure or don't have access to the subscription. Please use Connect-AzAccount to connect."
            exit
        }
        Select-AzSubscription -Subscription $SubscriptionName -Force
    }


    # ---- DEPLOY phase (DeployAndTest / DeployOnly) ----
    if ($needAzure) {

        if ($UseExistingVMs) {
            Write-Host "Using existing VMs" -ForegroundColor Green
        }
        else {

            # create resource group
            Write-Host -ForegroundColor Green "Creating resource group"
            $ResourceGroup = New-AzResourceGroup -Location $region -Name $ResourceGroupName

            # create a Proximity Placement Group when requested
            $ppg = $null
            if ($UseProximityPlacementGroup) {
                Write-Host -ForegroundColor Green "Creating Proximity Placement Group"
                $ppg = New-AzProximityPlacementGroup -ResourceGroupName $ResourceGroupName -Name $PPGName -Location $region -ProximityPlacementGroupType Standard
            }

            # create vNET and Subnet or getting existing
            if ($UseExistingVnet) {
                Write-Host -ForegroundColor Green "Getting existing vNET and Subnet Config"
                $Vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupNameNetwork
                $SingleSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $Vnet -Name $SubnetName
            }
            else {
                Write-Host -ForegroundColor Green "Creating vNET and Subnet"
                $SingleSubnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix
                $Vnet = New-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -Location $region -AddressPrefix $VnetAddressPrefix -Subnet $SingleSubnet
            }

            # create NSG
            Write-Host -ForegroundColor Green "Creating NSG"
            $rule1 = New-AzNetworkSecurityRuleConfig -Name ssh-rule -Description "Allow SSH" -Access Allow -Direction Inbound -Protocol Tcp -Priority 100 -SourcePortRange * -SourceAddressPrefix * -DestinationAddressPrefix * -DestinationPortRange 22
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $region -Name $NSGName -SecurityRules $rule1


            # create VMs (both in the same zone, optionally in the same PPG)
            Write-Host -ForegroundColor Green "Creating VMs in zone $Zone$(if ($UseProximityPlacementGroup) { ' (Proximity Placement Group enabled)' })"
            For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {

                $ComputerName = $VMPrefix + $vmindex
                $NICName = $ComputerName + $NICPostfix
                $PIPName = $NICName + $pippostfix
                $Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $Vnet
                if ($UsePublicIPAddresses) {
                    $PIP = New-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName -Location $region -Sku Standard -AllocationMethod Static -IpAddressVersion IPv4 -Zone $Zone
                    $IPConfig1 = New-AzNetworkInterfaceIpConfig -Name "IPConfig-1" -Subnet $Subnet -PublicIpAddress $PIP -Primary
                }
                else {
                    $IPConfig1 = New-AzNetworkInterfaceIpConfig -Name "IPConfig-1" -Subnet $Subnet -Primary
                }
                $NIC = New-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -Location $region -IpConfiguration $IpConfig1 -EnableAcceleratedNetworking -NetworkSecurityGroup $nsg
                if ($UseProximityPlacementGroup) {
                    $VirtualMachine = New-AzVMConfig -VMName $ComputerName -VMSize $VMSize -ProximityPlacementGroupId $ppg.Id
                }
                else {
                    $VirtualMachine = New-AzVMConfig -VMName $ComputerName -VMSize $VMSize
                }
                $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Linux -ComputerName $ComputerName -Credential $Credential -DisablePasswordAuthentication:$false
                $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
                $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $OSPublisher -Offer $OSOffer -Skus $OSSku -Version $OSVersion
                $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Enable
                $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $region -VM $VirtualMachine -zone $Zone -Verbose -AsJob

            }

            # waiting for VM creation jobs to finish
            "All jobs created, waiting ..."
            Get-Job | Wait-Job
            "All jobs completed"
            Get-AzVM -ResourceGroupName $ResourceGroupName

            # adding some time as it sometimes helps :-)
            "Waiting for four minute for all systems to come up ..."
            Start-Sleep -Seconds 240
        }
    }


    # ---- build the connection + test address lists ----
    # $connectips[index]             : address used to SSH into each VM
    # $ipaddresses[$VMPrefix+index]  : address the VMs use to reach each other for the measurements
    $connectips = @("","")
    $ipaddresses = @{}

    if ($Mode -eq "TestOnly") {
        if (-not $VM1 -or -not $VM2) {
            Write-Host -ForegroundColor Red "-VM1 and -VM2 are required for -Mode TestOnly."
            exit
        }
        $connectips = @($VM1, $VM2)
        $ipaddresses[$VMPrefix + 1] = if ($VM1TestIp) { $VM1TestIp } else { $VM1 }
        $ipaddresses[$VMPrefix + 2] = if ($VM2TestIp) { $VM2TestIp } else { $VM2 }
    }
    else {
        For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {
            $ComputerName = $VMPrefix + $vmindex
            $NICName = $ComputerName + $NICPostfix

            $nic = Get-AzNetworkInterface -Name $NICName
            $networkinterfaceconfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $nic
            $ipaddresses[$ComputerName] = $networkinterfaceconfig.PrivateIpAddress

            if ($UsePublicIPAddresses) {
                $pipname = $ComputerName + $NICPostfix + $pippostfix
                $PIP = Get-AzPublicIpAddress -Name $pipname
                $connectips[$vmindex-1] = $PIP.IpAddress
            }
            else {
                $connectips[$vmindex-1] = $networkinterfaceconfig.PrivateIpAddress
            }
        }
    }


    # ---- DeployOnly: report the addresses and a ready-to-run TestOnly command, then stop ----
    if ($Mode -eq "DeployOnly") {
        Write-Host -ForegroundColor Green "Deployment complete. The VMs are left running."
        Write-Host ""
        Write-Host "Region:  $region"
        Write-Host "Zone:    $Zone"
        Write-Host "Proximity Placement Group:  $(if ($UseProximityPlacementGroup) { 'enabled' } else { 'disabled' })"
        Write-Host "VM Type: $VMSize"
        Write-Host ""
        For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {
            $ComputerName = $VMPrefix + $vmindex
            Write-Host ("vm {0}  {1}  public={2}  private={3}" -f $vmindex, $ComputerName, $connectips[$vmindex-1], $ipaddresses[$ComputerName])
        }
        Write-Host ""
        Write-Host "Copy this script onto a controller that can reach the VMs over SSH and run the tests with:"
        if ($UsePublicIPAddresses) {
            Write-Host ("  ./AvZone-Latency-SameZone.ps1 -Mode TestOnly -VM1 {0} -VM2 {1} ``" -f $connectips[0], $connectips[1])
            Write-Host ("      -VM1TestIp {0} -VM2TestIp {1} ``" -f $ipaddresses[$VMPrefix+1], $ipaddresses[$VMPrefix+2])
            Write-Host ("      -VMLocalAdminUser {0} -VMLocalAdminPassword '<password>'" -f $VMLocalAdminUser)
        }
        else {
            Write-Host ("  ./AvZone-Latency-SameZone.ps1 -Mode TestOnly -VM1 {0} -VM2 {1} ``" -f $connectips[0], $connectips[1])
            Write-Host ("      -VMLocalAdminUser {0} -VMLocalAdminPassword '<password>'" -f $VMLocalAdminUser)
        }
        if ($breakingchangewarning.Value -eq $true) {
            Update-AzConfig -DisplayBreakingChangeWarning $true
        }
        exit
    }


    # ---- TEST phase (DeployAndTest / TestOnly) ----

    # measurement results and host details are mirrored to a timestamped file in the script folder
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $script:ResultLogPath = Join-Path $scriptDir ("AvZone-Latency-SameZone-results-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Host -ForegroundColor Green "Writing results to $script:ResultLogPath"
    Add-Content -Path $script:ResultLogPath -Value ("AvZone-Latency-SameZone results - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-Content -Path $script:ResultLogPath -Value "Mode: $Mode"

    # removing all open ssh sessions
    Get-SSHTrustedHost | Remove-SSHTrustedHost
    $sshsessions = Get-SSHSession
    foreach ($sshsession in $sshsessions) {
        Remove-SSHSession -SessionId $sshsession.SessionId
    }

    # creating SSH sessions to the VMs
    Write-Host -ForegroundColor Green "Creating SSH sessions"
    For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {
        $ipaddress = $connectips[$vmindex-1]
        try {
            # checking TCP connectivity
            $_testresult = New-Object System.Net.Sockets.TcpClient($ipaddress, 22)
            if ($_testresult.Connected) {
                # connected
                Write-Host -ForegroundColor Green "TCP connection available to VM$vmindex with address $ipaddress"
                if ($SSHKeyFilePath) {
                    $sshsession = New-SSHSession -ComputerName $ipaddress -Credential $Credential -KeyFile $SSHKeyFilePath -AcceptKey -Force
                }
                else {
                    $sshsession = New-SSHSession -ComputerName $ipaddress -Credential $Credential -AcceptKey -Force
                }
                if ($sshsession.connected -ne $true)
                {
                    Write-Host "Unable to connect to address $ipaddress"
                    exit
                }
            }
            else {
                Write-Host -ForegroundColor Red "unable to connect to SSH port for VM$vmindex $ipaddress. Please check if you can connect to the VM from your host using e.g. putty"
            }
        }
        catch {
            Write-Host -ForegroundColor Red "Failed to connect to VM$vmindex $ipaddress : $($_.Exception.Message)"
            exit
        }
    }

    $sshsessions = Get-SSHSession


    # get the Hyper-V KVP physical host name for each VM, and (TestOnly) the Azure IMDS facts.
    # IMDS is a link-local, unauthenticated endpoint (169.254.169.254) read in-guest over SSH,
    # so TestOnly still needs no Azure control plane access or identity.
    Write-Host -ForegroundColor Green "Getting Hosts for virtual machines"
    $imdsInfo = @{}
    For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {

        $output = Invoke-SSHCommand -Command "strings /var/lib/hyperv/.kvp_pool_3 | sed -n '2 p'" -SessionId $sshsessions[$vmindex-1].SessionId
        Write-Result ("VM$vmindex host: " + $output.Output)

        if ($Mode -eq "TestOnly") {
            $imds = Invoke-SSHCommand -Command "curl -s -H 'Metadata:true' --max-time 5 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01&format=json'" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 20
            try {
                $meta = ($imds.Output -join "`n") | ConvertFrom-Json
                $imdsInfo[$vmindex] = $meta
                Write-Result ("VM$vmindex IMDS: location=$($meta.location) vmSize=$($meta.vmSize) zone=$($meta.zone)")
            }
            catch {
                Write-Host -ForegroundColor Yellow "VM$vmindex IMDS: not available (VM may not be on Azure or IMDS is blocked)"
            }
        }
    }

    # TestOnly: warn if the two VMs report different Azure zones (this scenario expects the SAME zone)
    if ($Mode -eq "TestOnly" -and $imdsInfo[1] -and $imdsInfo[2] -and $imdsInfo[1].zone -and $imdsInfo[2].zone -and ($imdsInfo[1].zone -ne $imdsInfo[2].zone)) {
        Write-Host -ForegroundColor Yellow "  note: VM1 reports Azure zone '$($imdsInfo[1].zone)' but VM2 reports '$($imdsInfo[2].zone)' - this test assumes both VMs are in the SAME zone"
    }

    # TestOnly: auto-fill the report header labels from VM1's IMDS data when not supplied
    if ($Mode -eq "TestOnly") {
        if (-not $PSBoundParameters.ContainsKey('region') -and $imdsInfo[1] -and $imdsInfo[1].location) { $region = $imdsInfo[1].location }
        if (-not $PSBoundParameters.ContainsKey('VMSize') -and $imdsInfo[1] -and $imdsInfo[1].vmSize)   { $VMSize = $imdsInfo[1].vmSize }
    }


    # run qperf test
    if ($testtool -eq "qperf") {
        # install qperf on all VMs
        Write-Host -ForegroundColor Green "Installing qperf, sockperf and iperf3 on all VMs"
        For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {

            # wait for cloud-init to finish so the apt/dpkg lock is free
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S cloud-init status --wait" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 300 -ErrorAction silentlycontinue
            # make sure the universe repository (which provides sockperf/iperf3) is enabled
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S add-apt-repository -y universe" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 120 -ErrorAction silentlycontinue
            # run apt-get update first, then only install the tools if the update succeeded
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S sh -c 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y update && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y install qperf sockperf iperf3'" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 600
            $installlog = $output.Output -join "`n"

            # verify the three tools are actually present, warn (and show apt output) if any is missing
            $check = Invoke-SSHCommand -Command "for t in qperf sockperf iperf3; do command -v `$t >/dev/null 2>&1 && echo `$t=ok || echo `$t=MISSING; done" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 30
            $checktext = $check.Output -join "`n"
            if ($checktext -match 'MISSING') {
                Write-Host -ForegroundColor Red "VM$vmindex : one or more tools failed to install -> $($check.Output -join ' ')"
                Write-Host -ForegroundColor Yellow ("VM$vmindex apt output (tail): " + (($installlog -split "`n" | Select-Object -Last 8) -join "`n"))
            }
            else {
                Write-Host -ForegroundColor Green "VM$vmindex : qperf, sockperf and iperf3 installed"
            }

            # start the measurement servers
            $output = Invoke-SSHCommand -Command "nohup qperf &" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue
            $output = Invoke-SSHCommand -Command "nohup sockperf server >/dev/null 2>&1 &" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue
            $output = Invoke-SSHCommand -Command "nohup iperf3 -s >/dev/null 2>&1 &" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue

        }

        # run performance tests between the two VMs in both directions
        Write-Host -ForegroundColor Green "Running bandwidth and latency tests"
        $ipvm1 = $ipaddresses[$VMPrefix + 1]
        $ipvm2 = $ipaddresses[$VMPrefix + 2]
        $targets = @($ipvm2, $ipvm1)   # source VM1 tests VM2, source VM2 tests VM1
        For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {

            $targetip = $targets[$vmindex-1]

            $output = Invoke-SSHCommand -Command "qperf $targetip tcp_lat" -SessionId $sshsessions[$vmindex-1].SessionId
            $latencytemp = [string]$output.Output[1]
            $latencytemp = $latencytemp.substring($latencytemp.IndexOf("=")+3)
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$vmindex-1] = $latencytemp

            $output = Invoke-SSHCommand -Command "qperf $targetip tcp_bw" -SessionId $sshsessions[$vmindex-1].SessionId
            $bandwidthtemp = [string]$output.Output[1]
            $bandwidthtemp = $bandwidthtemp.substring($bandwidthtemp.IndexOf("=")+3)
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$vmindex-1] = $bandwidthtemp

        }

        # detect vCPU count on the source VMs so iperf3 -P can use one stream per core
        $cores = 1
        try {
            $coreout = Invoke-SSHCommand -Command "nproc" -SessionId $sshsessions[0].SessionId -TimeOut 15
            $n = 0
            if ([int]::TryParse((($coreout.Output | Select-Object -First 1) -as [string]).Trim(), [ref]$n) -and $n -ge 1) { $cores = $n }
        }
        catch { }

        # run sockperf (idle + under-load) and iperf3 (TCP single/aggregate + UDP baseline/saturation) tests
        Write-Host -ForegroundColor Green "Running sockperf (idle + under-load) and iperf3 (TCP single/aggregate + UDP baseline/saturation) tests using $cores stream(s) for aggregate"
        $advresults = @()
        $advresults += Get-AdvancedNetworkStats -SessionId $sshsessions[0].SessionId -TargetIp $ipvm2 -FromLabel "vm 1" -ToLabel "vm 2" -Cores $cores
        $advresults += Get-AdvancedNetworkStats -SessionId $sshsessions[1].SessionId -TargetIp $ipvm1 -FromLabel "vm 2" -ToLabel "vm 1" -Cores $cores
    }

    if ($testtool -eq "niping") {

        # download niping on all hosts and run niping server
        Write-Host -ForegroundColor Green "Installing niping on all VMs"
        For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {

            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | wget $nipingpath -O /tmp/niping" -SessionId $sshsessions[$vmindex-1].SessionId
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | chmod +x /tmp/niping" -SessionId $sshsessions[$vmindex-1].SessionId
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | nohup /tmp/niping -s -I 0 &" -SessionId $sshsessions[$vmindex-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue

        }

        # run performance tests between the two VMs in both directions
        Write-Host -ForegroundColor Green "Running bandwidth and latency tests"
        $ipvm1 = $ipaddresses[$VMPrefix + 1]
        $ipvm2 = $ipaddresses[$VMPrefix + 2]
        $targets = @($ipvm2, $ipvm1)   # source VM1 tests VM2, source VM2 tests VM1
        For ($vmindex=1; $vmindex -le $vmcount; $vmindex++) {

            $targetip = $targets[$vmindex-1]

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 10 -L 100 -H $targetip | grep av2" -SessionId $sshsessions[$vmindex-1].SessionId
            $latencytemp = [string]$output.Output
            $latencytemp = $latencytemp -replace '\s+', ' '
            $latencytemp = $latencytemp -Split " "
            $latencytemp = [string]$latencytemp[1] + " " + $latencytemp[2]
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$vmindex-1] = $latencytemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 100000 -L 100 -H $targetip | grep tr2" -SessionId $sshsessions[$vmindex-1].SessionId
            $bandwidthtemp = [string]$output.Output
            $bandwidthtemp = $bandwidthtemp -replace '\s+', ' '
            $bandwidthtemp = $bandwidthtemp -Split ". "
            $bandwidthtemp = [int]$bandwidthtemp[1] / 1024
            $bandwidthtemp = [string]([math]::ceiling($bandwidthtemp)) + " MB/s"
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$vmindex-1] = $bandwidthtemp

        }
    }

    # Print output (console unchanged; the same result lines are appended to the results file)
    if ($script:ResultLogPath) {
        Add-Content -Path $script:ResultLogPath -Value ""
        Add-Content -Path $script:ResultLogPath -Value ("-" * 70)
    }
    Write-Result "Region:  $region"
    Write-Result "Zone:  $Zone"
    Write-Result ("Proximity Placement Group:  " + $(if ($Mode -eq "TestOnly") { "(see IMDS zone notes above)" } elseif ($UseProximityPlacementGroup) { "enabled" } else { "disabled" }))
    Write-Result "VM Type:  $VMSize"

    $qperfResults = @(
        [PSCustomObject]@{ From = "vm 1"; To = "vm 2"; Latency = $latency[0].Trim(); Bandwidth = $bandwidth[0].Trim() }
        [PSCustomObject]@{ From = "vm 2"; To = "vm 1"; Latency = $latency[1].Trim(); Bandwidth = $bandwidth[1].Trim() }
    )

    Write-Result ""
    Write-Result "Latency (qperf tcp_lat - one-way latency, i.e. ~half the round-trip, in us):"
    $qperfResults | Format-Table From, To, Latency -AutoSize | Out-String -Width 4096 | Write-Result

    Write-Result "Bandwidth (qperf tcp_bw, in MB/sec):"
    $qperfResults | Format-Table From, To, Bandwidth -AutoSize | Out-String -Width 4096 | Write-Result

    if ($advresults) {
        Write-Result ""
        Write-Result "sockperf idle one-way latency in us (one-way = ~half round-trip; comparable to the qperf latency table above):"
        $advresults | Format-Table From, To, 'OWAvg(us)', 'OWP90(us)', 'OWP99(us)', 'OWMax(us)' -AutoSize | Out-String -Width 4096 | Write-Result

        Write-Result "sockperf idle full round-trip time (RTT) in us (--full-rtt pass):"
        $advresults | Format-Table From, To, 'RTTAvg(us)', 'RTTP90(us)', 'RTTP99(us)', 'RTTMax(us)' -AutoSize | Out-String -Width 4096 | Write-Result

        Write-Result "RTT under load in us - bufferbloat (idle RTT avg vs RTT measured during an iperf3 TCP transfer):"
        $advresults | Format-Table From, To, 'RTTAvg(us)', 'LoadRTTavg(us)', 'LoadRTTp99(us)' -AutoSize | Out-String -Width 4096 | Write-Result

        Write-Result "iperf3 TCP throughput in MB/sec - single flow (avg/P90/P99/max, warm-up dropped), retransmits, and aggregate over $cores parallel streams:"
        $advresults | Format-Table From, To, 'TCP1avg(MB/s)', 'TCP1p90(MB/s)', 'TCP1p99(MB/s)', 'TCP1max(MB/s)', 'Retr', 'TCPagg(MB/s)' -AutoSize | Out-String -Width 4096 | Write-Result

        Write-Result "iperf3 UDP packet loss %/jitter (ms) - baseline (100 Mbps, organic) vs saturation (~TCP rate, load-induced):"
        $advresults | Format-Table From, To, 'UDPbLoss(%)', 'UDPbJit(ms)', 'UDPsAvg(MB/s)', 'UDPsLoss(%)', 'UDPsJit(ms)' -AutoSize | Out-String -Width 4096 | Write-Result
    }


    # Removing SSH sessions
    Write-Host -ForegroundColor Green "Removing SSH Sessions"
    $sshsessions = Get-SSHSession
    foreach ($sshsession in $sshsessions) {
        Remove-SSHSession -SessionId $sshsession.SessionId
    }


    # destroy resource group (DeployAndTest only)
    if ($needAzure) {
        if ($Mode -eq "DeployAndTest" -and $DestroyAfterTest) {
            Write-Host -ForegroundColor Green "Deleting Resource Group"
            Remove-AzResourceGroup -Name $ResourceGroupName -Force
        }
        else {
            Write-Host -ForegroundColor Green "Resource group will NOT be deleted"
        }

        if ($breakingchangewarning.Value -eq $true) {
            Update-AzConfig -DisplayBreakingChangeWarning $true
        }
    }
