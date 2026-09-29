<#

.SYNOPSIS
    Runs network performance tests between three pre-existing Linux VMs (no Azure deployment).

.DESCRIPTION
    This is a standalone, "tests only" variant of AvZone-Latency-Test.ps1. It does NOT deploy
    any Azure infrastructure and has NO dependency on the Azure control plane: it does not import
    the Az PowerShell modules and never calls Connect-AzAccount / Select-AzSubscription. The
    controller running this script does not need an Azure identity.

    You supply the connection endpoints (IP addresses or resolvable host names) of three VMs that
    have already been created out of band (in three different Availability Zones, or anywhere).
    The script opens SSH sessions to them (Posh-SSH), installs the measurement tools, and runs the
    same qperf / sockperf / iperf3 tests as the original script:

        qperf    : one-way latency (tcp_lat) and bandwidth (tcp_bw)
        sockperf : idle one-way latency, idle full round-trip RTT, and RTT under load (bufferbloat)
        iperf3   : TCP single-flow throughput (avg/P90/P99/max + retransmits), TCP aggregate
                   throughput over one stream per vCPU, and UDP packet loss / jitter at a baseline
                   rate and at saturation

    If the VMs are reached over a public IP but must test each other over a private IP, pass the
    private addresses via -Zone1TestIp / -Zone2TestIp / -Zone3TestIp.

.PARAMETER Zone1
    IP address or host name used to SSH into the VM in zone 1.

.PARAMETER Zone2
    IP address or host name used to SSH into the VM in zone 2.

.PARAMETER Zone3
    IP address or host name used to SSH into the VM in zone 3.

.PARAMETER Zone1TestIp
    Optional address the other VMs use to reach zone 1 for the actual measurements (e.g. the
    private IP). Defaults to -Zone1 when omitted.

.PARAMETER Zone2TestIp
    Optional address the other VMs use to reach zone 2. Defaults to -Zone2 when omitted.

.PARAMETER Zone3TestIp
    Optional address the other VMs use to reach zone 3. Defaults to -Zone3 when omitted.

.PARAMETER VMLocalAdminUser
    SSH user name (same on all three VMs).

.PARAMETER VMLocalAdminPassword
    SSH password (same on all three VMs). Ignored when -SSHKeyFilePath is supplied.

.PARAMETER SSHKeyFilePath
    Optional path to a private key file for key-based SSH authentication.

.PARAMETER testtool
    "qperf" (default) or "niping".

.PARAMETER nipingpath
    Download URL for the niping executable (only used when -testtool niping).

.PARAMETER Region
    Free-text label shown in the report header (informational only).

.PARAMETER VMSize
    Free-text label shown in the report header (informational only).

.EXAMPLE
    ./AvZone-Latency-Test-NoAzure.ps1 -Zone1 20.1.1.10 -Zone2 20.1.1.11 -Zone3 20.1.1.12 `
        -Zone1TestIp 10.0.0.4 -Zone2TestIp 10.0.0.5 -Zone3TestIp 10.0.0.6 `
        -VMLocalAdminUser azping -VMLocalAdminPassword 'P@ssw0rd!'

.LINK
    https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities

.NOTES
    v1.0        - Standalone test-only fork of AvZone-Latency-Test.ps1:
                  removed all Azure deployment, Az module requirements, and Azure login.
                  Connects to three pre-created VMs, installs tools, and runs the tests.

#>
<#
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.
#>

#Requires -Version 7.1
#Requires -Modules @{ ModuleName="Posh-SSH"; ModuleVersion="3.0.0" }

param(
    # IP address or host name used to SSH into the zone 1 VM
    [Parameter(Mandatory=$true)][string]$Zone1,
    # IP address or host name used to SSH into the zone 2 VM
    [Parameter(Mandatory=$true)][string]$Zone2,
    # IP address or host name used to SSH into the zone 3 VM
    [Parameter(Mandatory=$true)][string]$Zone3,
    # Optional address the other VMs use to reach zone 1 for the tests (defaults to $Zone1)
    [string]$Zone1TestIp,
    # Optional address the other VMs use to reach zone 2 for the tests (defaults to $Zone2)
    [string]$Zone2TestIp,
    # Optional address the other VMs use to reach zone 3 for the tests (defaults to $Zone3)
    [string]$Zone3TestIp,
    # SSH username (same on all three VMs)
    [string]$VMLocalAdminUser = "azping",
    # SSH password (same on all three VMs); ignored when -SSHKeyFilePath is used
    [string]$VMLocalAdminPassword = "P@ssw0rd!",
    # Optional private key file for key-based SSH authentication
    [string]$SSHKeyFilePath,
    # decide to use qperf or niping
    [ValidateSet("qperf","niping")][string]$testtool = "qperf",
    # path to niping
    [string]$nipingpath,
    # informational label for the report header only
    [string]$Region = "(not specified)",
    # informational label for the report header only
    [string]$VMSize = "(not specified)"
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


    if ($testtool -eq "niping") {
        if (!$nipingpath) {
            $nipingpath = Read-Host -Prompt "Please enter download path for niping executable: "
        }
    }

    $VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force

    $zones = 3

    # create the secure credential object
    $Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword)

    # connection endpoints (used for SSH) and test targets (used by the VMs to reach each other)
    $connectips = @($Zone1, $Zone2, $Zone3)
    $test1 = if ($Zone1TestIp) { $Zone1TestIp } else { $Zone1 }
    $test2 = if ($Zone2TestIp) { $Zone2TestIp } else { $Zone2 }
    $test3 = if ($Zone3TestIp) { $Zone3TestIp } else { $Zone3 }
    $testips = @($test1, $test2, $test3)

    # initialize the arrays for outputs
    $latency = @(("","",""),("","",""),("","",""))
    $bandwidth = @(("","",""),("","",""),("","",""))

    for ($x=1; $x -le $zones; $x++) {
        for ($y=1; $y -le 3; $y++) {
            $latency[$x-1][$y-1] = "0"
            $bandwidth[$x-1][$y-1] = "0"
        }
    }


    # removing all open ssh sessions
    Get-SSHTrustedHost | Remove-SSHTrustedHost
    $sshsessions = Get-SSHSession
    foreach ($sshsession in $sshsessions) {
        Remove-SSHSession -SessionId $sshsession.SessionId
    }

    # creating SSH sessions to the pre-existing VMs
    Write-Host -ForegroundColor Green "Creating SSH sessions"
    For ($zone=1; $zone -le $zones; $zone++) {
        $ipaddress = $connectips[$zone-1]
        try {
            # checking TCP connectivity
            $_testresult = New-Object System.Net.Sockets.TcpClient($ipaddress, 22)
            if ($_testresult.Connected) {
                # connected
                Write-Host -ForegroundColor Green "TCP connection available to zone $zone VM with address $ipaddress"
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
                Write-Host -ForegroundColor Red "unable to connect to SSH port for zone $zone VM $ipaddress. Please check if you can connect to the VM from your host using e.g. putty"
            }
        }
        catch {
            Write-Host -ForegroundColor Red "Failed to connect to zone $zone VM $ipaddress : $($_.Exception.Message)"
            exit
        }
    }

    $sshsessions = Get-SSHSession


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
                Write-Host -ForegroundColor Red "zone $zone : one or more tools failed to install -> $($check.Output -join ' ')"
                Write-Host -ForegroundColor Yellow ("zone $zone apt output (tail): " + (($installlog -split "`n" | Select-Object -Last 8) -join "`n"))
            }
            else {
                Write-Host -ForegroundColor Green "zone $zone : qperf, sockperf and iperf3 installed"
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
            $ipaddresstoping1 = $testips[$vmtopingno1-1]
            $vmtopingno2 = ((($zone+1)%3)+1)
            $ipaddresstoping2 = $testips[$vmtopingno2-1]

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
        For ($zone=1; $zone -le $zones; $zone++) {

            $vmtopingno1 = (( $zone   %3)+1)
            $ipaddresstoping1 = $testips[$vmtopingno1-1]
            $vmtopingno2 = ((($zone+1)%3)+1)
            $ipaddresstoping2 = $testips[$vmtopingno2-1]

            $advresults += Get-AdvancedNetworkStats -SessionId $sshsessions[$zone-1].SessionId -TargetIp $ipaddresstoping1 -FromLabel "zone $zone" -ToLabel "zone $vmtopingno1" -Cores $cores
            $advresults += Get-AdvancedNetworkStats -SessionId $sshsessions[$zone-1].SessionId -TargetIp $ipaddresstoping2 -FromLabel "zone $zone" -ToLabel "zone $vmtopingno2" -Cores $cores

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
            $ipaddresstoping1 = $testips[$vmtopingno1-1]
            $vmtopingno2 = ((($zone+1)%3)+1)
            $ipaddresstoping2 = $testips[$vmtopingno2-1]

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
    Write-Host "Region: " $Region
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
        Write-Host "sockperf idle one-way latency in us (one-way = ~half round-trip; comparable to the qperf latency table above):"
        $advresults | Format-Table From, To, 'OWAvg(us)', 'OWP90(us)', 'OWP99(us)', 'OWMax(us)' -AutoSize | Out-Host

        Write-Host "sockperf idle full round-trip time (RTT) in us (--full-rtt pass):"
        $advresults | Format-Table From, To, 'RTTAvg(us)', 'RTTP90(us)', 'RTTP99(us)', 'RTTMax(us)' -AutoSize | Out-Host

        Write-Host "RTT under load in us - bufferbloat (idle RTT avg vs RTT measured during an iperf3 TCP transfer):"
        $advresults | Format-Table From, To, 'RTTAvg(us)', 'LoadRTTavg(us)', 'LoadRTTp99(us)' -AutoSize | Out-Host

        Write-Host "iperf3 TCP throughput in MB/sec - single flow (avg/P90/P99/max, warm-up dropped), retransmits, and aggregate over $cores parallel streams:"
        $advresults | Format-Table From, To, 'TCP1avg(MB/s)', 'TCP1p90(MB/s)', 'TCP1p99(MB/s)', 'TCP1max(MB/s)', 'Retr', 'TCPagg(MB/s)' -AutoSize | Out-Host

        Write-Host "iperf3 UDP packet loss %/jitter (ms) - baseline (100 Mbps, organic) vs saturation (~TCP rate, load-induced):"
        $advresults | Format-Table From, To, 'UDPbLoss(%)', 'UDPbJit(ms)', 'UDPsAvg(MB/s)', 'UDPsLoss(%)', 'UDPsJit(ms)' -AutoSize | Out-Host
    }


    # Removing SSH sessions
    Write-Host -ForegroundColor Green "Removing SSH Sessions"
    $sshsessions = Get-SSHSession
    foreach ($sshsession in $sshsessions) {
        Remove-SSHSession -SessionId $sshsession.SessionId
    }
