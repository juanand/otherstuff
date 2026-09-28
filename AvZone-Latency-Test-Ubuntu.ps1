<#

.SYNOPSIS
    Creates VMs and tests latency between VMs

.DESCRIPTION
    The script creates VMs in Zone 1, 2 and 3, installing qperf on it and testing latency between VMs.
    This version uses Ubuntu 26.04 LTS and installs qperf via apt-get.
    In addition to qperf it uses sockperf (two passes: one-way latency and full round-trip
    RTT, each reporting Average/P90/P99/Max plus packet loss) and iperf3 (average throughput
    in MB/sec) between the zones.

.PARAMETER Region
    The Azure region name

.EXAMPLE
    ./AvZone-Latency-Test-Ubuntu.ps1 -SubscriptionName "My Subscription" -Region westeurope

    Example output:

        Region:  westeurope
        VM Type:  Standard_D8s_v3
        Latency:
                 ----------------------------------------------
                 |    zone 1    |    zone 2    |    zone 3    |
        -------------------------------------------------------
        | zone 1 |              |        xx us |        xx us |
        | zone 2 |        xx us |              |        xx us |
        | zone 3 |        xx us |        xx us |              |
        -------------------------------------------------------

        Bandwidth:
                 ----------------------------------------------
                 |    zone 1    |    zone 2    |    zone 3    |
        -------------------------------------------------------
        | zone 1 |              |   xxx MB/sec |   xxx MB/sec |
        | zone 2 |   xxx MB/sec |              |   xxx MB/sec |
        | zone 3 |   xxx MB/sec |   xxx MB/sec |              |
        -------------------------------------------------------

.LINK
    https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities

.NOTES
    v0.1        - Initial version
    v0.2        - adding usage of existing VNET
    v0.3        - switching from variables to parameters
                - adding documentation
                - adding logon check
    2022041101  - using IP address instead of hostname to avoid issues in existing VNETs
                - creating storage account for diagnostic information
    2023030601  - changing how existing sessions are deleted
                - switching to CentOS 8.5
                - adding TCP port check
                - fixing issue with "breaking change" warnings
                - changing how the physical hostname is retrieved from .kvp_pool_3 file
    2026092801  - switching to Ubuntu 26.04 LTS (Canonical image)
                - installing qperf via apt-get instead of yum
                - waiting for cloud-init to finish and using non-interactive apt
    2026092802  - adding sockperf (RTT percentiles + packet loss) and iperf3 (throughput)
                  to report Average/P95/P99/Max RTT, Packet Loss %, and Avg. Throughput
    2026092803  - sockperf now runs two passes (one-way latency and full round-trip RTT),
                  percentiles switched to P90/P99 (sockperf has no P95), iperf3 throughput
                  reported in MB/sec, and qperf tables relabelled (one-way latency / MB/sec)

#>
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.
#>

#Requires -Version 7.1
#Requires -Modules Az.Compute
#Requires -Modules @{ ModuleName="Posh-SSH"; ModuleVersion="3.0.0" }

param(
    #Azure Subscription Name
    [Parameter(Mandatory=$true)][string]$SubscriptionName,
    #Azure Region, use Get-AzLocation to get region names
    [string]$region = "westeurope", 
    #Resource Group Name that will be created
    [string]$ResourceGroupName = "AvZoneLatencyTest", 
    #Delete the test environment after test
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
    #VM name prefix, 1,2,3 will be added based on zone
    [string]$VMPrefix = "azping-vm0", 
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
    #decide to use qperf or niping
    [ValidateSet("qperf","niping")][string]$testtool = "qperf",
    #path to niping
    [string]$nipingpath
)


Function Get-RandomAlphanumericString {
	
	[CmdletBinding()]
	Param (
        [int] $length = 8
	)

	Begin{
	}

	Process{
        Write-Output ( -join (( 0x61..0x7A) | Get-Random -Count $length  | % {[char]$_}) )
	}	
}


Function Get-AdvancedNetworkStats {
    # Runs sockperf twice (one-way latency and full round-trip RTT, over UDP) plus iperf3
    # (TCP throughput) from the source VM's SSH session against the target IP, returning one
    # result object. sockperf's default report is one-way latency; --full-rtt reports the
    # full round trip. sockperf's fixed percentile set has P90/P99 but no P95.
    [CmdletBinding()]
    Param (
        [int]    $SessionId,
        [string] $TargetIp,
        [string] $FromLabel,
        [string] $ToLabel
    )

    # pass 1: one-way latency (sockperf default, comparable to qperf's half round-trip)
    $spOne  = Invoke-SSHCommand -Command "sockperf ping-pong -i $TargetIp -t 10" -SessionId $SessionId -TimeOut 60
    $owText = $spOne.Output -join "`n"
    $owAvg = if ($owText -match '(?:Round trip|Latency) is\s+([\d\.]+)') { [math]::Round([double]$Matches[1], 2) } else { $null }
    $owP90 = if ($owText -match 'percentile 90\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $owP99 = if ($owText -match 'percentile 99\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $owMax = if ($owText -match '<MAX> observation\s*=\s*([\d\.]+)')       { [math]::Round([double]$Matches[1], 2) } else { $null }

    # pass 2: full round-trip RTT (--full-rtt)
    $spRtt   = Invoke-SSHCommand -Command "sockperf ping-pong -i $TargetIp -t 10 --full-rtt" -SessionId $SessionId -TimeOut 60
    $rttText = $spRtt.Output -join "`n"
    $rttAvg = if ($rttText -match '(?:Round trip|Latency) is\s+([\d\.]+)') { [math]::Round([double]$Matches[1], 2) } else { $null }
    $rttP90 = if ($rttText -match 'percentile 90\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $rttP99 = if ($rttText -match 'percentile 99\.000\s*=\s*([\d\.]+)')     { [math]::Round([double]$Matches[1], 2) } else { $null }
    $rttMax = if ($rttText -match '<MAX> observation\s*=\s*([\d\.]+)')       { [math]::Round([double]$Matches[1], 2) } else { $null }

    # packet loss from the full-rtt pass
    $loss = $null
    if ($rttText -match 'SentMessages=(\d+);\s*ReceivedMessages=(\d+)') {
        $sent = [double]$Matches[1]
        $recv = [double]$Matches[2]
        if ($sent -gt 0) { $loss = [math]::Round((($sent - $recv) / $sent) * 100, 3) }
    }

    # iperf3 TCP throughput, reported in MB/sec (bytes) to match qperf's tcp_bw table
    $ip = Invoke-SSHCommand -Command "iperf3 -c $TargetIp -t 10 -J" -SessionId $SessionId -TimeOut 60
    $throughputMBs = $null
    try {
        $ipjson = ($ip.Output -join "`n") | ConvertFrom-Json
        if ($ipjson.end.sum_received.bits_per_second) {
            $throughputMBs = [math]::Round($ipjson.end.sum_received.bits_per_second / 8e6, 1)
        }
    }
    catch { }

    [PSCustomObject]@{
        From         = $FromLabel
        To           = $ToLabel
        'OWAvg(us)'  = $owAvg
        'OWP90(us)'  = $owP90
        'OWP99(us)'  = $owP99
        'OWMax(us)'  = $owMax
        'RTTAvg(us)' = $rttAvg
        'RTTP90(us)' = $rttP90
        'RTTP99(us)' = $rttP99
        'RTTMax(us)' = $rttMax
        'Loss(%)'    = $loss
        'Tput(MB/s)' = $throughputMBs
    }
}

    $breakingchangewarning = Get-AzConfig -DisplayBreakingChangeWarning
    if ($breakingchangewarning.Value -eq $true) {
        Update-AzConfig -DisplayBreakingChangeWarning $false
    }

    if ($testtool -eq "niping") {
        if (!$nipingpath) {
            $nipingpath = Read-Host -Prompt "Please enter download path for niping executable: "
        }
           
    }


	# select subscription
	$Subscription = Get-AzSubscription -SubscriptionName $SubscriptionName
    if (-Not $Subscription) {
        Write-Host -ForegroundColor Red -BackgroundColor White "Sorry, it seems you are not connected to Azure or don't have access to the subscription. Please use Connect-AzAccount to connect."
        exit
    }


    Select-AzSubscription -Subscription $SubscriptionName -Force

    $VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force

    $zones = 3

    
    #create the secure credential object
	$Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword);

    # initialize the arrays for outputs
    $latency = @(("","",""),("","",""),("","",""))
    $bandwidth = @(("","",""),("","",""),("","",""))

    for ($x=1; $x -le $zones; $x++) {
        for ($y=1; $y -le 3; $y++) {
            $latency[$x-1][$y-1] = "0"
            $bandwidth[$x-1][$y-1] = "0"
        }
    }

    

    if ($UseExistingVMs) {
        Write-Host "Using existing VMs" -ForegroundColor Green
    }
    else {

        # create resource group
        Write-Host -ForegroundColor Green "Creating resource group"
        $ResourceGroup = New-AzResourceGroup -Location $region -Name $ResourceGroupName

        # creating storage account for diagnostic information
        $StorageAccountName = Get-RandomAlphanumericString
        $StorageAccount = New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -SkuName Standard_LRS -Location $region
    
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

    
        # create VMs
        Write-Host -ForegroundColor Green "Creating VMs"
        For ($zone=1; $zone -le $zones; $zone++) {

            $ComputerName = $VMPrefix + $zone
            $NICName = $ComputerName + $NICPostfix
       	    $PIPName = $NICName + $pippostfix
	        $Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $Vnet
    	    if ($UsePublicIPAddresses) {
                $PIP = New-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName -Location $region -Sku Standard -AllocationMethod Static -IpAddressVersion IPv4 -Zone $zone
	            $IPConfig1 = New-AzNetworkInterfaceIpConfig -Name "IPConfig-1" -Subnet $Subnet -PublicIpAddress $PIP -Primary
            }
            else {
                $IPConfig1 = New-AzNetworkInterfaceIpConfig -Name "IPConfig-1" -Subnet $Subnet -Primary
            }
    	    $NIC = New-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -Location $region -IpConfiguration $IpConfig1 -EnableAcceleratedNetworking -NetworkSecurityGroup $nsg
	        $VirtualMachine = New-AzVMConfig -VMName $ComputerName -VMSize $VMSize
            $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Linux -ComputerName $ComputerName -Credential $Credential -DisablePasswordAuthentication:$false
            $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
            $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $OSPublisher -Offer $OSOffer -Skus $OSSku -Version $OSVersion
            $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -StorageAccountName $StorageAccountName -Enable -ResourceGroupName $ResourceGroupName
            $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $region -VM $VirtualMachine -zone $zone -Verbose -AsJob
                
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


    # removing all open ssh sessions
    Get-SSHTrustedHost | Remove-SSHTrustedHost
    $sshsessions = Get-SSHSession
    foreach ($sshsession in $sshsessions) {
        Remove-SSHSession -SessionId $sshsession.SessionId
    }

    # creating SSH sessions to VMs
    $ipaddresses = @{}

    Write-Host -ForegroundColor Green "Creating SSH sessions"
    For ($zone=1; $zone -le $zones; $zone++) {
        $ComputerName = $VMPrefix + $zone
        $pipname = $VMPrefix + $zone + $NICPostfix + $pippostfix 
        $NICName = $ComputerName + $NICPostfix

        if ($UsePublicIPAddresses) {
			$nic = Get-AzNetworkInterface -Name $NICName
			$networkinterfaceconfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $nic
            $ipaddresses[$ComputerName] += $networkinterfaceconfig.PrivateIpAddress

            $pipname = $VMPrefix + $zone + $NICPostfix + $pippostfix 
			$PIP = Get-AzPublicIpAddress -Name $pipname
			$ipaddress = $PIP.IpAddress
        }
        else {
			$nic = Get-AzNetworkInterface -Name $NICName
			$networkinterfaceconfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $nic
            $ipaddress = $networkinterfaceconfig.PrivateIpAddress
            $ipaddresses[$ComputerName] += $networkinterfaceconfig.PrivateIpAddress
        }
        try {
            # checking TCP connectivity
            $_testresult = New-Object System.Net.Sockets.TcpClient($ipaddress, 22)
            if ($_testresult.Connected) {
                # connected
                Write-Host -ForegroundColor Green "TCP connection available to VM $ComputerName with IP address $ipaddress"
                $sshsession = New-SSHSession -ComputerName $ipaddress -Credential $Credential -AcceptKey -Force
                if ($sshsession.connected -ne $true)
                {
                    Write-Host "Unable to connect to IP address $ipaddress"
                    exit
                }
            }
            else {
                Write-Host -ForegroundColor Red "unable to connect to SSH port for VM $ipaddress. Please check if you can connect to the VM from your host using e.g. putty"
            }
        }
        catch {
            exit
        }
    }

    $sshsessions = Get-SSHSession


    Write-Host -ForegroundColor Green "Getting Hosts for virtual machines"
    For ($zone=1; $zone -le $zones; $zone++) {

        #$output = Invoke-SSHCommand -Command "/bin/cat /var/lib/hyperv/.kvp_pool_3 | tr -d '\\000' | grep -o -P '(?<=HostName).*(?=CLOUD_INIT)'" -SessionId $sshsessions[$zone-1].SessionId
        $output = Invoke-SSHCommand -Command "strings /var/lib/hyperv/.kvp_pool_3 | sed -n '2 p'" -SessionId $sshsessions[$zone-1].SessionId
        Write-Host ("VM$zone : " + $output.Output) 

    }


    # run qperf test
    if ($testtool -eq "qperf") {
        # install qperf on all VMs
        Write-Host -ForegroundColor Green "Installing qperf, sockperf and iperf3 on all VMs"
        For ($zone=1; $zone -le $zones; $zone++) {

            # wait for cloud-init to finish so the apt/dpkg lock is free
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S cloud-init status --wait" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 300 -ErrorAction silentlycontinue
            # make sure the universe repository (which provides sockperf/iperf3) is enabled
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S add-apt-repository -y universe" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 120 -ErrorAction silentlycontinue
            # run apt-get update first, then only install the tools if the update succeeded
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S sh -c 'DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y update && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y install qperf sockperf iperf3'" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 600
            $installlog = $output.Output -join "`n"

            # verify the three tools are actually present, warn (and show apt output) if any is missing
            $check = Invoke-SSHCommand -Command "for t in qperf sockperf iperf3; do command -v `$t >/dev/null 2>&1 && echo `$t=ok || echo `$t=MISSING; done" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 30
            $checktext = $check.Output -join "`n"
            if ($checktext -match 'MISSING') {
                Write-Host -ForegroundColor Red "VM$zone : one or more tools failed to install -> $($check.Output -join ' ')"
                Write-Host -ForegroundColor Yellow ("VM$zone apt output (tail): " + (($installlog -split "`n" | Select-Object -Last 8) -join "`n"))
            }
            else {
                Write-Host -ForegroundColor Green "VM$zone : qperf, sockperf and iperf3 installed"
            }

            # start the measurement servers
            $output = Invoke-SSHCommand -Command "nohup qperf &" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue
            $output = Invoke-SSHCommand -Command "nohup sockperf server >/dev/null 2>&1 &" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue
            $output = Invoke-SSHCommand -Command "nohup iperf3 -s >/dev/null 2>&1 &" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue

        }

        # run performance tests
        Write-Host -ForegroundColor Green "Running bandwidth and latency tests"
        For ($zone=1; $zone -le $zones; $zone++) {

            $vmtopingno1 = (( $zone   %3)+1)
            $vmtoping1 = $VMPrefix + (( $zone   %3)+1)
            $ipaddresstoping1 = $ipaddresses[$vmtoping1]
            $vmtopingno2 = ((($zone+1)%3)+1)
            $vmtoping2 = $VMPrefix + ((($zone+1)%3)+1)
            $ipaddresstoping2 = $ipaddresses[$vmtoping2]

            $output = Invoke-SSHCommand -Command "qperf $ipaddresstoping1 tcp_lat" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output[1]
            $latencytemp = $latencytemp.substring($latencytemp.IndexOf("=")+3)
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno1 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "qperf $ipaddresstoping1 tcp_bw" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output[1]
            $bandwidthtemp = $bandwidthtemp.substring($bandwidthtemp.IndexOf("=")+3)
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno1 -1] = $bandwidthtemp

            $output = Invoke-SSHCommand -Command "qperf $ipaddresstoping2 tcp_lat" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output[1]
            $latencytemp = $latencytemp.substring($latencytemp.IndexOf("=")+3)
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno2 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "qperf $ipaddresstoping2 tcp_bw" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output[1]
            $bandwidthtemp = $bandwidthtemp.substring($bandwidthtemp.IndexOf("=")+3)
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno2 -1] = $bandwidthtemp

        }

        # run sockperf (one-way + full RTT, packet loss) and iperf3 (throughput) tests
        Write-Host -ForegroundColor Green "Running sockperf (one-way + full RTT) and iperf3 throughput tests"
        $advresults = @()
        For ($zone=1; $zone -le $zones; $zone++) {

            $vmtopingno1 = (( $zone   %3)+1)
            $vmtoping1 = $VMPrefix + $vmtopingno1
            $ipaddresstoping1 = $ipaddresses[$vmtoping1]
            $vmtopingno2 = ((($zone+1)%3)+1)
            $vmtoping2 = $VMPrefix + $vmtopingno2
            $ipaddresstoping2 = $ipaddresses[$vmtoping2]

            $advresults += Get-AdvancedNetworkStats -SessionId $sshsessions[$zone-1].SessionId -TargetIp $ipaddresstoping1 -FromLabel "zone $zone" -ToLabel "zone $vmtopingno1"
            $advresults += Get-AdvancedNetworkStats -SessionId $sshsessions[$zone-1].SessionId -TargetIp $ipaddresstoping2 -FromLabel "zone $zone" -ToLabel "zone $vmtopingno2"

        }
    }

    if ($testtool -eq "niping") {

        # download niping on all hosts and run niping server
        Write-Host -ForegroundColor Green "Installing niping on all VMs"
        For ($zone=1; $zone -le $zones; $zone++) {

            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | wget $nipingpath -O /tmp/niping" -SessionId $sshsessions[$zone-1].SessionId
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | chmod +x /tmp/niping" -SessionId $sshsessions[$zone-1].SessionId
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | nohup /tmp/niping -s -I 0 &" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue

        }

        # run performance tests
        Write-Host -ForegroundColor Green "Running bandwidth and latency tests"
        For ($zone=1; $zone -le $zones; $zone++) {

            $vmtopingno1 = (( $zone   %3)+1)
            $vmtoping1 = $VMPrefix + (( $zone   %3)+1)
            $ipaddresstoping1 = $ipaddresses[$vmtoping1]
            $vmtopingno2 = ((($zone+1)%3)+1)
            $vmtoping2 = $VMPrefix + ((($zone+1)%3)+1)
            $ipaddresstoping2 = $ipaddresses[$vmtoping2]

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 10 -L 100 -H $ipaddresstoping1 | grep av2" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output
            $latencytemp = $latencytemp -replace '\s+', ' '
            $latencytemp = $latencytemp -Split " "
            $latencytemp = [string]$latencytemp[1] + " " + $latencytemp[2]
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno1 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 100000 -L 100 -H $ipaddresstoping1 | grep tr2" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output
            $bandwidthtemp = $bandwidthtemp -replace '\s+', ' '
            $bandwidthtemp = $bandwidthtemp -Split ". "
            $bandwidthtemp = [int]$bandwidthtemp[1] / 1024
            $bandwidthtemp = [string]([math]::ceiling($bandwidthtemp)) + " MB/s"
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno1 -1] = $bandwidthtemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 10 -L 100 -H $ipaddresstoping2 | grep av2" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output
            $latencytemp = $latencytemp -replace '\s+', ' '
            $latencytemp = $latencytemp -Split " "
            $latencytemp = [string]$latencytemp[1] + " " + $latencytemp[2]
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno2 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 100000 -L 100 -H $ipaddresstoping2 | grep tr2" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output
            $bandwidthtemp = $bandwidthtemp -replace '\s+', ' '
            $bandwidthtemp = $bandwidthtemp -Split ". "
            $bandwidthtemp = [int]$bandwidthtemp[1] / 1024
            $bandwidthtemp = [string]([math]::ceiling($bandwidthtemp)) + " MB/s"
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno2 -1] = $bandwidthtemp

        }
    }
    
    # Print output
    Write-Host "Region: " $region
    Write-Host "VM Type: " $VMSize

    Write-Host "Latency (qperf tcp_lat - one-way latency, i.e. ~half the round-trip, in us):"

    Write-Host "         ----------------------------------------------"
    Write-Host "         |    zone 1    |    zone 2    |    zone 3    |"
    Write-Host "-------------------------------------------------------"
    Write-Host "| zone 1 |              |" $latency[0][1] "|" $latency[0][2] "|"
    Write-Host "| zone 2 |" $latency[1][0] "|              |" $latency[1][2] "|"
    Write-Host "| zone 3 |" $latency[2][0] "|" $latency[2][1] "|              |"
    Write-Host "-------------------------------------------------------"

    Write-Host ""
    Write-Host "Bandwidth (qperf tcp_bw, in MB/sec):"

    Write-Host "         ----------------------------------------------"
    Write-Host "         |    zone 1    |    zone 2    |    zone 3    |"
    Write-Host "-------------------------------------------------------"
    Write-Host "| zone 1 |              |" $bandwidth[0][1] "|" $bandwidth[0][2] "|"
    Write-Host "| zone 2 |" $bandwidth[1][0] "|              |" $bandwidth[1][2] "|"
    Write-Host "| zone 3 |" $bandwidth[2][0] "|" $bandwidth[2][1] "|              |"
    Write-Host "-------------------------------------------------------"

    if ($advresults) {
        Write-Host ""
        Write-Host "sockperf one-way latency in us (one-way = ~half round-trip; comparable to the qperf latency table above):"
        $advresults | Format-Table From, To, 'OWAvg(us)', 'OWP90(us)', 'OWP99(us)', 'OWMax(us)' -AutoSize | Out-Host

        Write-Host "sockperf full round-trip time (RTT) in us (--full-rtt pass):"
        $advresults | Format-Table From, To, 'RTTAvg(us)', 'RTTP90(us)', 'RTTP99(us)', 'RTTMax(us)' -AutoSize | Out-Host

        Write-Host "packet loss (sockperf UDP) and average throughput (iperf3, MB/sec to match qperf):"
        $advresults | Format-Table From, To, 'Loss(%)', 'Tput(MB/s)' -AutoSize | Out-Host
    }


    # Removing SSH sessions
    Write-Host -ForegroundColor Green "Removing SSH Sessions"
    #Get-SSHSession | Remove-SSHSession -ErrorAction SilentlyContinue | Out-Null
    $sshsessions = Get-SSHSession
    foreach ($sshsession in $sshsessions) {
        Remove-SSHSession -SessionId $sshsession.SessionId
    }
    
    
    #destroy resource group
    if ($DestroyAfterTest) {
        Write-Host -ForegroundColor Green "Deleting Resource Group"
        Remove-AzResourceGroup -Name $ResourceGroupName -Force
    }
    else
    {
        Write-Host -ForegroundColor Green "Resource group will NOT be deleted"
    }

    if ($breakingchangewarning.Value -eq $true) {
        Update-AzConfig -DisplayBreakingChangeWarning $true
    }
