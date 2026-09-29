# About

Old [SAP script](https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities/blob/main/AvZone-Latency-Test/Readme.md) rely on qperf and old CentOS image that does not work anymore.
This vive-coding version uses qperf on Ubuntu, and adds iperf3 and sockperf to get additional details.

On top of that, this approach leverages a controller VM to run the script, to make it work with high restricted environments:
- Execution VM does not have SSH access to the test VMs.
- We use controller VM and its system-assigned identity to run the script.
- VMs don't have public IPs.


# Create Controller VM

```powershell
# Params
$RESOURCE_GROUP = "rg-az-latency-test"
$LOCATION       = "uksouth"
$VNET_NAME      = "rg-latency-vnet"
$VNET_PREFIX    = "10.0.0.0/16"
$SUBNET_NAME    = "subnet"
$SUBNET_PREFIX  = "10.0.1.0/24"
$VM_NAME        = "controller"
$VM_SKU         = "Standard_D2s_v5"
$VM_IMAGE       = "Canonical:ubuntu-26_04-lts:server:latest"
$VM_ROLE        = "Contributor"
$ADMIN_USER     = "azureuser"
$ADMIN_PASSWORD = "{password}"

# Create RG
az group create `
  --name $RESOURCE_GROUP `
  --location $LOCATION

# Create VNet
az network vnet create `
  --resource-group $RESOURCE_GROUP `
  --name $VNET_NAME `
  --address-prefixes $VNET_PREFIX `
  --location $LOCATION

# Create subnet
az network vnet subnet create `
  --resource-group $RESOURCE_GROUP `
  --vnet-name $VNET_NAME `
  --name $SUBNET_NAME `
  --address-prefixes $SUBNET_PREFIX `
  --default-outbound true

# Create controller VM
az vm create `
  --resource-group $RESOURCE_GROUP `
  --name $VM_NAME `
  --image $VM_IMAGE `
  --size $VM_SKU `
  --vnet-name $VNET_NAME `
  --subnet $SUBNET_NAME `
  --admin-username $ADMIN_USER `
  --admin-password $ADMIN_PASSWORD `
  --public-ip-address "" `
  --nsg "" `
  --boot-diagnostics-storage ""
  
# Enable Serial Console
  az vm boot-diagnostics enable `
  --resource-group $RESOURCE_GROUP ` --name $VM_NAME
  
# Enable system-assigned managed identity
az vm identity assign `
  --resource-group $RESOURCE_GROUP `
  --name $VM_NAME
  
# Grant contributor over RG to controller VM
$PRINCIPAL_ID = (az vm identity show `
  --resource-group $RESOURCE_GROUP `
  --name $VM_NAME `
  --query principalId `
  --output tsv)

$SUBSCRIPTION_ID = (az account show --query id --output tsv)

az role assignment create `
  --assignee $PRINCIPAL_ID `
  --role $VM_ROLE `
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

```

# Prepare Controller VM

Install PowerShell 
```bash
# Install PowerShell
sudo apt update

# Install pre-requisite packages.
sudo apt install -y wget apt-transport-https software-properties-common

# Download the Microsoft repository GPG keys
. /etc/os-release
wget -q https://packages.microsoft.com/config/$ID/$VERSION_ID/packages-microsoft-prod.deb

# Register the Microsoft repository GPG keys
sudo dpkg -i packages-microsoft-prod.deb

# Remove GPG keys file
rm ./packages-microsoft-prod.deb

# Update the list of packages again
sudo apt update

# Install PowerShell
sudo apt-get install -y powershell
```

Alternatively, if `apt-get` complains about cannot find PowerShell (24.04 works, 26.04 fails), try:
```bash
wget https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell_7.6.6-1.deb_amd64.deb
sudo dpkg -i powershell_7.6.6-1.deb_amd64.deb
```

Install needed PowerShell Modules:
```PowerShell
Install-Module Az -Force
Install-Module -Name Posh-SSH -Force
```

Download scripts from GitHub:
```bash
# Originals in https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities
wget https://raw.githubusercontent.com/juanand/otherstuff/main/AZ-Latency/AvZone-Latency-Test/AvZone-Latency-Test.ps1
wget https://raw.githubusercontent.com/juanand/otherstuff/main/AZ-Latency/AvZone-Mapping/AvZone-Mapping.ps1
wget https://raw.githubusercontent.com/juanand/otherstuff/main/AZ-Latency/Get-VM-by-Zones/Get-VMs-by-Zone.ps1
```


# AvZone-Latency-Test.ps1

Create a screen session in Serial Console to avoid timeouts
```bash
screen -S pwsh
# To reconnect, screen -r pwsh
```

Inside screen, run `pwsh` and then:
```PowerShell
# Authenticate with system-assigned identity
Connect-AzAccount -Identity

# Run script
$SUB_NAME       = "{subscriptionName}"
$RESOURCE_GROUP = "rg-az-latency-test"
$LOCATION       = "uksouth"
$VNET_NAME      = "rg-latency-vnet"
$SUBNET_NAME    = "subnet"
$ADMIN_USER     = "azureuser"
$ADMIN_PASSWORD = "{password}"

./AvZone-Latency-Test.ps1 `
  -subscriptionName $SUB_NAME `
  -region $LOCATION `
  -ResourceGroupName $RESOURCE_GROUP `
  -DestroyAfterTest $FALSE `
  -UseExistingVMs $FALSE `
  -UseExistingVnet $TRUE `
  -NetworkName $VNET_NAME `
  -SubnetName $SUBNET_NAME `
  -ResourceGroupNameNetwork $RESOURCE_GROUP `
  -UsePublicIPAddresses $FALSE `
  -VMLocalAdminUser $ADMIN_USER `
  -VMLocalAdminPassword $ADMIN_PASSWORD `
    
```

You may adjust parameters to meet your needs.
For example, -UseExistingVMs set to TRUE for first pass and FALSE for later passes to get newer report, etc.

See repo for more details.

# AvZone-Mapping.ps1

Register feature for the subscriptions:
```PowerShell
Register-AzProviderFeature -FeatureName AvailabilityZonePeering -ProviderNamespace Microsoft.Resources
```

Then run from Cloud Shell or your own shell get subscriptions AZ mappings.
```PowerShell
./Avzone-Mapping.ps1 -subscriptionId {sub1} -subscriptionPeers {sub1},{sub2},{subN} -region {regionName}
```

# Get-VMs-by-Zone.ps1
Simply run from Cloud Shell or your own shell to get VM SKUs per AZ.
