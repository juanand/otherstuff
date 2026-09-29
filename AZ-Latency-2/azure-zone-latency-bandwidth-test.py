#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import time
import re
import logging
import subprocess
import json
import sys
import paramiko

from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.resource import ResourceManagementClient, SubscriptionClient
from azure.mgmt.network.models import NetworkSecurityGroup, SecurityRule

logging.basicConfig(level=logging.INFO, format='%(levelname)s - %(message)s')
logging.getLogger('azure').setLevel(logging.WARNING)
logging.getLogger('azure.identity').setLevel(logging.WARNING)
logging.getLogger('azure.core.pipeline.policies.http_logging_policy').setLevel(logging.WARNING)
logging.getLogger('paramiko').setLevel(logging.WARNING)

def create_resource_group(resource_client, resource_group_name, location):
    """
    Create a resource group in the specified location.

    Args:
        resource_client (ResourceManagementClient): The resource management client.
        resource_group_name (str): The name of the resource group.
        location (str): The location where the resource group will be created.
    """
    resource_group_params = {'location': location}
    resource_client.resource_groups.create_or_update(resource_group_name, resource_group_params)
    logging.info("Resource group %s has been created.", resource_group_name)

def create_virtual_network(network_client, resource_group_name, vnet_name, subnet_name, network_cidr, location):
    """
    Create a virtual network and a subnet within it.

    Args:
        network_client (NetworkManagementClient): The network management client.
        resource_group_name (str): The name of the resource group.
        vnet_name (str): The name of the virtual network.
        subnet_name (str): The name of the subnet.
        network_cidr (str): The CIDR block for the network.
        location (str): The location where the virtual network will be created.
    """
    vnet_params = {
        'location': location,
        'address_space': {
            'address_prefixes': [network_cidr]
        }
    }
    network_client.virtual_networks.begin_create_or_update(resource_group_name, vnet_name, vnet_params).result()
    logging.info("VNet %s has been created.", vnet_name)

    subnet_info = network_client.subnets.begin_create_or_update(
        resource_group_name,
        vnet_name,
        subnet_name,
        {
            'address_prefix': network_cidr
        }
    ).result()
    logging.info("Subnet %s has been created.", subnet_name)

def create_network_security_group(network_client, resource_group_name, nsg_name, location):
    """
    Create a network security group with predefined security rules.

    Args:
        network_client (NetworkManagementClient): The network management client.
        resource_group_name (str): The name of the resource group.
        nsg_name (str): The name of the network security group.
        location (str): The location where the network security group will be created.
    """
    ssh_rule = SecurityRule(
        protocol='Tcp',
        source_address_prefix='VirtualNetwork',
        destination_address_prefix='*',
        access='Allow',
        direction='Inbound',
        source_port_range='*',
        destination_port_range='22',
        priority=100,
        name='ssh-rule'
    )

    iperf3_rule = SecurityRule(
        protocol='Tcp',
        source_address_prefix='VirtualNetwork',
        destination_address_prefix='*',
        access='Allow',
        direction='Inbound',
        source_port_range='*',
        destination_port_range='5201',
        priority=101,
        name='iperf3_rule'
    )

    sockperf_rule = SecurityRule(
        protocol='Tcp',
        source_address_prefix='VirtualNetwork',
        destination_address_prefix='*',
        access='Allow',
        direction='Inbound',
        source_port_range='*',
        destination_port_range='11111',
        priority=102,
        name='sockperf_rule'
    )

    two_ping_rule = SecurityRule(
        protocol='Tcp',
        source_address_prefix='VirtualNetwork',
        destination_address_prefix='*',
        access='Allow',
        direction='Inbound',
        source_port_range='*',
        destination_port_range='15998',
        priority=103,
        name='two_ping_rule'
    )

    asn_rule = SecurityRule(
        protocol='Tcp',
        source_address_prefix='VirtualNetwork',
        destination_address_prefix='*',
        access='Allow',
        direction='Inbound',
        source_port_range='*',
        destination_port_range='49200',
        priority=104,
        name='asn_rule'
    )

    icmp_rule = SecurityRule(
        protocol='Icmp',
        source_address_prefix='VirtualNetwork',
        destination_address_prefix='*',
        access='Allow',
        direction='Inbound',
        source_port_range='*',
        destination_port_range='*',
        priority=199,
        name='icmp-rule'
    )

    outbound_rule = SecurityRule(
        protocol='*',
        source_address_prefix='*',
        destination_address_prefix='*',
        access='Allow',
        direction='Outbound',
        source_port_range='*',
        destination_port_range='*',
        priority=130,
        name='outbound-any-any'
    )

    nsg_params = NetworkSecurityGroup(location=location, security_rules=[ssh_rule, iperf3_rule, icmp_rule, asn_rule, sockperf_rule,two_ping_rule, outbound_rule])
    network_client.network_security_groups.begin_create_or_update(resource_group_name, nsg_name, nsg_params).result()
    logging.info("Network security group %s has been created.", nsg_name)

def create_vm_without_progress(compute_client, network_client, resource_client, resource_group_name, vm_name, location, vm_type, username, password, nsg_name, vnet_name, subnet_name, zone, enable_accelerated_networking):
    """
    Create a virtual machine without showing progress.

    Args:
        compute_client (ComputeManagementClient): The compute management client.
        network_client (NetworkManagementClient): The network management client.
        resource_client (ResourceManagementClient): The resource management client.
        resource_group_name (str): The name of the resource group.
        vm_name (str): The name of the virtual machine.
        location (str): The location where the virtual machine will be created.
        vm_type (str): The type of the virtual machine.
        username (str): The admin username for the virtual machine.
        password (str): The admin password for the virtual machine.
        nsg_name (str): The name of the network security group.
        vnet_name (str): The name of the virtual network.
        subnet_name (str): The name of the subnet.
        zone (str): The availability zone for the virtual machine.
        enable_accelerated_networking (bool): Whether to enable accelerated networking.
    """
    subnet_info = network_client.subnets.get(resource_group_name, vnet_name, subnet_name)

    nic_name = f"{vm_name}-nic"
    ip_config_name = f"{vm_name}-ipconfig"

    # VMs are private-IP only; no public IP is created or attached.
    nic_params = {
        'location': location,
        'ip_configurations': [{
            'name': ip_config_name,
            'subnet': {'id': subnet_info.id}
        }],
        'network_security_group': {'id': network_client.network_security_groups.get(resource_group_name, nsg_name).id},
        'enable_accelerated_networking': enable_accelerated_networking
    }
    nic = network_client.network_interfaces.begin_create_or_update(resource_group_name, nic_name, nic_params).result()

    vm_params = {
        'location': location,
        'hardware_profile': {'vm_size': vm_type},
        'storage_profile': {
            'image_reference': {
                'publisher': 'Canonical',
                'offer': 'ubuntu-24_04-lts',
                'sku': 'server',
                'version': 'latest'
            }
        },
        'os_profile': {
            'computer_name': vm_name,
            'admin_username': username,
            'admin_password': password
        },
        'network_profile': {
            'network_interfaces': [{'id': nic.id}]
        },
        # Managed boot diagnostics (no storage_uri) uses a Microsoft-managed storage
        # account, enabling Serial Console without provisioning a customer storage account.
        'diagnostics_profile': {
            'boot_diagnostics': {
                'enabled': True
            }
        },
        'zones': [zone]
    }
    compute_client.virtual_machines.begin_create_or_update(resource_group_name, vm_name, vm_params).result()
    logging.info("VM %s has been created.", vm_name)
    return nic.ip_configurations[0].private_ip_address

def get_private_ip_address(network_client, resource_group_name, vm_name):
    """
    Get the private IP address of a virtual machine.

    Args:
        network_client (NetworkManagementClient): The network management client.
        resource_group_name (str): The name of the resource group.
        vm_name (str): The name of the virtual machine.

    Returns:
        str: The private IP address of the virtual machine, or None if the NIC does not exist.
    """
    try:
        nic = network_client.network_interfaces.get(resource_group_name, f"{vm_name}-nic")
    except ResourceNotFoundError:
        logging.error(
            "NIC '%s-nic' not found in resource group '%s'. The VMs have not been created yet. "
            "Run the script without --run/--show-info first to create the infrastructure.",
            vm_name, resource_group_name,
        )
        return None
    return nic.ip_configurations[0].private_ip_address

def create_ssh_client(ip_address, username, password, skip_setup=False):
    """
    Create an SSH client to connect to a virtual machine.

    Args:
        ip_address (str): The IP address of the virtual machine.
        username (str): The admin username for the virtual machine.
        password (str): The admin password for the virtual machine.
        skip_setup (bool): Whether to skip the setup process.

    Returns:
        paramiko.SSHClient: The SSH client.
    """
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(ip_address, username=username, password=password)
        logging.debug("SSH connection established with %s", ip_address)

        if not skip_setup:
            # Check if the repository is already cloned and iperf3 is running
            stdin, stdout, stderr = client.exec_command("ls azure-network-measurement && pgrep iperf3")
            repo_check = stdout.read().decode().strip()
            iperf3_check = stderr.read().decode().strip()

            if "azure-network-measurement" in repo_check and not iperf3_check:
                logging.info("Repository already cloned and iperf3 is running. Skipping setup.")
            else:
                # Clone the repository and run the script
                commands = [
                    "git clone https://github.com/pichuang/azure-network-measurement.git",
                    "cd azure-network-measurement && sudo bash all-in-one-install.sh &"
                ]

                for command in commands:
                    stdin, stdout, stderr = client.exec_command(command)
                    logging.debug(stdout.read().decode())
                    # logging.info(stderr.read().decode())

        return client
    except Exception as e:
        logging.error("Failed to create SSH connection to %s: %s", ip_address, e)
        return None

def run_bandwidth_test(client, vm_name, target_vm_name, target_ip):
    """
    Run a bandwidth test using iperf3.

    Args:
        client (paramiko.SSHClient): The SSH client.
        vm_name (str): The name of the source virtual machine.
        target_vm_name (str): The name of the target virtual machine.
        target_ip (str): The IP address of the target virtual machine.

    Returns:
        str: The bandwidth result in Mbps.
    """
    logging.info(f"Running Bandwidth test from {vm_name} to {target_vm_name} via Private IP")
    stdin, stdout, stderr = client.exec_command(f"iperf3 --client {target_ip} --time 10 --interval 1 --omit 1 --parallel 32 --json")
    output = stdout.read().decode()
    try:
        result = json.loads(output)
        bits_per_second = result['end']['sum_sent']['bits_per_second']
        mbps = bits_per_second / 1_000_000
        return f"{mbps:.2f} Mbps"
    except (json.JSONDecodeError, KeyError) as e:
        logging.error(f"Failed to parse iperf3 output: {e}")
        return "N/A"

def run_latency_test(client, vm_name, target_vm_name, target_ip):
    """
    Run a latency test using sockperf.

    Args:
        client (paramiko.SSHClient): The SSH client.
        vm_name (str): The name of the source virtual machine.
        target_vm_name (str): The name of the target virtual machine.
        target_ip (str): The IP address of the target virtual machine.

    Returns:
        str: The latency result in ms.
    """
    logging.info(f"Running Latency   test from {vm_name} to {target_vm_name} via Private IP")
    stdin, stdout, stderr = client.exec_command(f"sockperf ping-pong --tcp --time 30 --msg-size 1500 --mps=max --full-rtt -i {target_ip}")
    output = stdout.read().decode()
    logging.debug(f"sockperf output: {output}")
    lat_line = [line for line in output.split('\n') if "percentile 99.000" in line]
    if lat_line:
        latency_us = float(lat_line[0].split()[-1])
        latency_ms = latency_us / 1000
        return f"{latency_ms:.3f} ms"
    else:
        logging.error("Failed to find 'percentile 99.000' in sockperf output")
        return "N/A"

def run_latency_bandwidth_tests(network_client, resource_group_name, vm_names, admin_username, admin_password, skip_bandwidth_test, skip_latency_test, skip_setup=False):
    """
    Run latency and bandwidth tests between virtual machines.

    Args:
        network_client (NetworkManagementClient): The network management client.
        resource_group_name (str): The name of the resource group.
        vm_names (list): The list of virtual machine names.
        admin_username (str): The admin username for the virtual machines.
        admin_password (str): The admin password for the virtual machines.
        skip_bandwidth_test (bool): Whether to skip the bandwidth tests.
        skip_latency_test (bool): Whether to skip the latency tests.
        skip_setup (bool): Whether to skip the setup process.
    """
    clients = {}
    for vm_name in vm_names:
        ip_address = get_private_ip_address(network_client, resource_group_name, vm_name)
        logging.info(f"Private IP address for {vm_name}: {ip_address}")
        if ip_address:
            clients[vm_name] = create_ssh_client(ip_address, admin_username, admin_password, skip_setup)
        else:
            logging.error(f"Failed to get private IP address for VM: {vm_name}")
            continue

    latency_private = [["" for _ in range(len(vm_names))] for _ in range(len(vm_names))]
    bandwidth_private = [["" for _ in range(len(vm_names))] for _ in range(len(vm_names))]

    for i, vm_name in enumerate(vm_names):
        for j, target_vm_name in enumerate(vm_names):
            if i != j:
                client = clients[vm_name]

                if not skip_bandwidth_test:
                    # Bandwidth Test using iperf3 (Private IP)
                    target_ip = get_private_ip_address(network_client, resource_group_name, target_vm_name)
                    bandwidth_private[i][j] = run_bandwidth_test(client, vm_name, target_vm_name, target_ip)

                if not skip_latency_test:
                    # Latency Test using sockperf (Private IP)
                    target_ip = get_private_ip_address(network_client, resource_group_name, target_vm_name)
                    latency_private[i][j] = run_latency_test(client, vm_name, target_vm_name, target_ip)

    logging.info("Latency (Private IP):")
    logging.info("         ----------------------------------------------")
    logging.info("         |    zone 1    |    zone 2    |    zone 3    |")
    logging.info("-------------------------------------------------------")
    for i in range(len(vm_names)):
        row = f"| zone {i+1} |"
        for j in range(len(vm_names)):
            if i == j:
                row += "              |"
            else:
                row += f" {latency_private[i][j]:>12} |"
        logging.info(row)
    logging.info("-------------------------------------------------------")

    logging.info("")
    logging.info("Bandwidth (Private IP):")
    logging.info("         ----------------------------------------------")
    logging.info("         |    zone 1    |    zone 2    |    zone 3    |")
    logging.info("-------------------------------------------------------")
    for i in range(len(vm_names)):
        row = f"| zone {i+1} |"
        for j in range(len(vm_names)):
            if i == j:
                row += "              |"
            else:
                row += f" {bandwidth_private[i][j]:>12} |"
        logging.info(row)
    logging.info("-------------------------------------------------------")

def delete_resource_group(resource_client, resource_group_name):
    """
    Delete a resource group.

    Args:
        resource_client (ResourceManagementClient): The resource management client.
        resource_group_name (str): The name of the resource group.
    """
    delete_operation = resource_client.resource_groups.begin_delete(resource_group_name)
    logging.info(f"Resource group {resource_group_name} deletion initiated, No need to wait for the deletion to complete")

def wait_for_vms_to_be_ready(vm_ips, timeout=240):
    """
    Wait for virtual machines to be reachable on their private IPs.

    Args:
        vm_ips (list): The list of virtual machine private IP addresses.
        timeout (int): The timeout period in seconds.
    """
    logging.info("Checking if VMs are reachable...")
    start_time = time.time()

    while time.time() - start_time < timeout:
        all_reachable = True
        for ip in vm_ips:
            try:
                result = subprocess.run(["ping", "-c", "1", "-W", "10", ip], capture_output=True, text=True)
                logging.debug(result.stdout)
                if result.returncode != 0:
                    all_reachable = False
                    break
            except Exception as e:
                logging.error(f"Error pinging {ip}: {e}")
                all_reachable = False
                break

        if all_reachable:
            logging.info("All VMs are reachable.")
            return
        time.sleep(10)
    logging.warning("Timeout reached. Some VMs may not be reachable.")

def vm_exists(compute_client, resource_group_name, vm_name):
    """
    Check if a virtual machine exists.

    Args:
        compute_client (ComputeManagementClient): The compute management client.
        resource_group_name (str): The name of the resource group.
        vm_name (str): The name of the virtual machine.

    Returns:
        bool: True if the virtual machine exists, False otherwise.
    """
    try:
        compute_client.virtual_machines.get(resource_group_name, vm_name)
        return True
    except Exception as e:
        if "ResourceNotFound" in str(e):
            return False
        else:
            raise

def show_vm_info(network_client, resource_group_name, vm_names, username, password):
    """
    Show information about virtual machines.

    Args:
        network_client (NetworkManagementClient): The network management client.
        resource_group_name (str): The name of the resource group.
        vm_names (list): The list of virtual machine names.
        username (str): The admin username for the virtual machines.
        password (str): The admin password for the virtual machines.
    """
    for vm_name in vm_names:
        ip_address = get_private_ip_address(network_client, resource_group_name, vm_name)
        logging.info(f"VM Name: {vm_name}, Private IP: {ip_address}, Username: {username}, Password: {password}")
        logging.info(f"To login {vm_name} from a controller inside the VNet: expect -c 'spawn ssh {username}@{ip_address}; expect \"password:\"; send \"{password}\\r\"; interact'")

def get_tenant_id_by_name(credential, tenant_name):
    """
    Get the tenant ID by tenant name.

    Args:
        credential (DefaultAzureCredential): The Azure credential.
        tenant_name (str): The name of the tenant.

    Returns:
        str: The tenant ID.
    """
    subscription_client = SubscriptionClient(credential)
    for tenant in subscription_client.tenants.list():
        if tenant.display_name == tenant_name:
            return tenant.tenant_id
    raise ValueError(f"Tenant name '{tenant_name}' not found")

def get_subscription_id(subscription_name_or_id):
    """
    Get the subscription ID by subscription name or ID.

    Args:
        subscription_name_or_id (str): The name or ID of the subscription.

    Returns:
        str: The subscription ID.
    """
    try:
        result = subprocess.run(
            ["az", "account", "list", "--query", "[].{name:name, id:id}", "-o", "json"],
            capture_output=True,
            text=True,
            check=True
        )
        subscriptions = json.loads(result.stdout)
        for subscription in subscriptions:
            if subscription['name'] == subscription_name_or_id or subscription['id'] == subscription_name_or_id:
                return subscription['id']
        raise ValueError(f"Subscription '{subscription_name_or_id}' not found.")
    except subprocess.CalledProcessError as e:
        print(f"Error executing az command: {e}", file=sys.stderr)
        sys.exit(1)

def get_tenant_id_and_subscription_id(credential):
    """
    Get the tenant ID and subscription ID.

    Args:
        credential (DefaultAzureCredential): The Azure credential.

    Returns:
        tuple: The tenant ID and subscription ID.
    """
    subscription_client = SubscriptionClient(credential)
    subscription = next(subscription_client.subscriptions.list())
    tenant_id = subscription.tenant_id
    subscription_id = subscription.subscription_id
    return tenant_id, subscription_id

def main():
    """
    Main function to parse arguments and execute the script.
    """
    parser = argparse.ArgumentParser(description="Azure Zone Latency/Bandwidth Test", epilog="Example: ./avzone-latency-test.py --subscription xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --resource-group-name rg-zone-test")
    parser.add_argument('--tenant', required=False, help='Azure Tenant ID or Name')
    parser.add_argument('--subscription', required=True, help='Azure Subscription ID')
    parser.add_argument('--resource-group-name', required=True, help='Resource Group Name')
    parser.add_argument('--vm-type', required=False, default='Standard_D8lds_v5', help='VM Type e.x Standard_D2s_v5 / Standard_D8lds_v5')
    parser.add_argument('--location', required=False, default='southeastasia', help='Azure Region')
    parser.add_argument('--enable-accelerated-networking', required=False, type=bool, default=True, help='Enable Accelerated Networking (default: True)')
    parser.add_argument('--admin-username', required=False, default='repairman', help='Admin username for the VM (default: repairman)')
    parser.add_argument('--admin-password', required=False, default='f5Q7tjAa2XheJE8NqDRnMP', help='Admin password for the VM (default: f5Q7tjAa2XheJE8NqDRnMP)')
    parser.add_argument('--network-cidr', required=False, default='192.168.100.0/24', help='Network CIDR (default: 192.168.100.0/24)')
    parser.add_argument('--force-delete', required=False, action='store_true', help='Force delete the resource group')
    parser.add_argument('--run', required=False, action='store_true', help='Run latency and bandwidth tests directly')
    parser.add_argument('--show-info', required=False, action='store_true', help='Show VM info (IP, username, password)')
    parser.add_argument('--skip-bandwidth-test', required=False, default=False, action='store_true', help='Skip bandwidth tests')
    parser.add_argument('--skip-latency-test', required=False, default=False, action='store_true', help='Skip latency tests')
    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(1)
    args = parser.parse_args()

    credential = DefaultAzureCredential()

    if args.tenant:
        if re.match(r'^[0-9a-fA-F-]{36}$', args.tenant):
            tenant_id = args.tenant
        else:
            tenant_id = get_tenant_id_by_name(credential, args.tenant)
    else:
        tenant_id, subscription_id = get_tenant_id_and_subscription_id(credential)

    subscription_id = args.subscription if args.subscription else subscription_id
    if not subscription_id.isdigit():
        subscription_id = get_subscription_id(subscription_id)
    resource_client = ResourceManagementClient(credential, subscription_id)
    compute_client = ComputeManagementClient(credential, subscription_id)
    network_client = NetworkManagementClient(credential, subscription_id)

    if args.force_delete:
        delete_resource_group(resource_client, args.resource_group_name)
        sys.exit(0)

    if args.run:
        vm_names = [f"azping-vm{zone}" for zone in range(1, 4)]
        run_latency_bandwidth_tests(network_client, args.resource_group_name, vm_names, args.admin_username, args.admin_password, args.skip_bandwidth_test, args.skip_latency_test, skip_setup=True)
        sys.exit(0)

    if args.show_info:
        vm_names = [f"azping-vm{zone}" for zone in range(1, 4)]
        show_vm_info(network_client, args.resource_group_name, vm_names, args.admin_username, args.admin_password)
        sys.exit(0)

    resource_group_exists = resource_client.resource_groups.check_existence(args.resource_group_name)
    if not resource_group_exists:
        create_resource_group(resource_client, args.resource_group_name, args.location)

    if not args.resource_group_name or not args.location:
        raise ValueError("Resource group name and location cannot be empty")
    create_virtual_network(network_client, args.resource_group_name, 'azping-mgmt-vnet', 'default', args.network_cidr, args.location)
    create_network_security_group(network_client, args.resource_group_name, 'azping-nsg', args.location)

    vm_ips = []
    for zone in range(1, 4):
        vm_name = f"azping-vm{zone}"
        if vm_exists(compute_client, args.resource_group_name, vm_name):
            logging.info(f"VM {vm_name} already exists. Skipping creation.")
            private_ip = get_private_ip_address(network_client, args.resource_group_name, vm_name)
        else:
            private_ip = create_vm_without_progress(compute_client, network_client, resource_client, args.resource_group_name, vm_name, args.location, args.vm_type, args.admin_username, args.admin_password, 'azping-nsg', 'azping-mgmt-vnet', 'default', str(zone), args.enable_accelerated_networking)
        vm_ips.append(private_ip)

    logging.info("All VMs created. Checking network reachability...")
    wait_for_vms_to_be_ready(vm_ips)

    vm_names = [f"azping-vm{zone}" for zone in range(1, 4)]
    run_latency_bandwidth_tests(network_client, args.resource_group_name, vm_names, args.admin_username, args.admin_password, args.skip_bandwidth_test, args.skip_latency_test)
    logging.info(f"Tenant ID: {tenant_id}")
    logging.info(f"Subscription ID: {subscription_id}")
    logging.info(f"Location: {args.location}")


if __name__ == "__main__":
    main()