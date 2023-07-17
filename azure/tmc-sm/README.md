# Aigapped install of TMC-SM on private AKS cluster

## Contents
- [Prerequisites](#prerequisites)
- [Account Setup](#account-setup)
- IaaS Paving
  - [Tools Infra](#tools-infra-setup)
    - [Offline Harbor Install](#offline-harbor-install)
    - [Mount File Share](#mount-file-share)
  - [TMC-SM Infra](#tmc-sm-infra)
- [Airgapped TMC-SM Install](#airgapped-tmc-sm-install)

## Prerequisites

- Need the Azure `az` client installed
- Need `jq` client installed
- Set your cloud, if you have not already done so:
  `az cloud set --name AzureCloud`
- Login: `az login`
- If you have access to more than one Azure Subscriptions, then run `az account list` to view your Subscriptions and set the default to the Subscription where you want the Jumpbox installed.
> `az account set --subsciption SUBSCRIPTION_ID` where SUBSCRIPTION_ID is the value of the `id` field.

[back-to-top](#contents)

## Account Setup

For automation purposes (scripting or terraform) we are gonna create a Service Principal in Azure for our subscription

```
SUBSCRIPTION_ID=$(az account show | jq -r '.id')
az ad sp create-for-rbac --name="tmc-sm" --role="Owner" --scopes="/subscriptions/$SUBSCRIPTION_ID"
```
the output of the above will have the `appId` and `password` for the service principal 

then login as that service principal
```
TENANT_ID=$(az account show | jq -r '.homeTenantId')

az login --service-principal -u $APP_ID -p $PASSWORD --tenant $TENANT_ID
```

[back-to-top](#contents)


## Tools Infra Paving

In this section, we will create a tools resource group in Azure which will contain our Jumpbox and Harbor Container Registry along with necessary services to support an airgapped installation of TMC-sm.


Create resource group for common tools
> Note: location will differ depending on what cloud you are targeting and your use geographic location. To get a list of locations for your targeted cloud, run `az account list-locations | jq -r '.[].name'`

```
az group create --resource-group tools -l $location
```

Create a storage account in the tools resource group. This storage account will be used for offline artifact storage and as a velero backup location for TMC-sm later
```
az storage account create -n mpmtmc -g tools -l $location --sku Standard_LRS
```

Create a file share within the above storage account to be used as a mount on your jumpbox vm later
```
az storage share create --account-name mpmtmc --name airgapped-files
```

Grab a connection string for the file share to upload / download files
```
export CONNECTION_STRING=$(az storage account show-connection-string --name mpmtmc --resource-group tools | jq -r '.connectionString')
```

Download the TMC bundle and upload it to the file share
```
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name mpmtmc --source bundle-1.0.0.tar
```

Create vnet for tools network where jumpbox, harbor, etc, will go
```
az network vnet create -g tools -n tools --address-prefix 10.0.0.0/16 --subnet-name tools --subnet-prefix 10.0.0.0/24
```

Create network security group (nsg) for tools and modify for inbound SSH and deny outbound internet
```
az network nsg create -n internal -g tools

az network nsg rule create -g tools --nsg-name internal -n DenyInternet --priority 100 --destination-address-prefixes Internet --destination-port-ranges '*' --access Deny --protocol '*' --direction Outbound

az network nsg rule create -g tools --nsg-name internal -n AllowSSH --priority 100 --destination-port-ranges '22' --access Allow --protocol 'TCP' --direction Inbound
```

Create ubuntu 22.04 vm with 100 gb disk and assign above nsg to the vm on the tools vnet and subnet
```
az vm create --resource-group tools --name jumpbox --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202307010 --ssh-key-values ~/.ssh/tmc.pub --nsg internal --vnet-name tools --subnet tools --public-ip-sku Standard --size Standard_D2s_v3 --os-disk-size-gb 100 --admin-username ubuntu
```

After ssh'ing to the server validate egress to internet is blocked:
```
ubuntu@jumpbox:~$ nc -zv projects.registry.vmware.com 443 -w2
nc: connect to projects.registry.vmware.com port 443 (tcp) timed out: Operation now in progress
nc: connect to projects.registry.vmware.com port 443 (tcp) failed: Network is unreachable
nc: connect to projects.registry.vmware.com port 443 (tcp) failed: Network is unreachable
```

Disabling internet egress also disabled ability to connect to Azure services like storage accounts and file shares. In order to connect to these services we need to add private endpoints for our storage account in order to traverse the microsoft backbone without going over public internet. More info [here](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-networking-endpoints?tabs=azure-cli).


Disable private endpoint network policies for the tools subnet
```
subnet_id=$(az network vnet subnet show -g tools --vnet-name tools -n tools | jq -r '.id')

az network vnet subnet update --ids $subnet_id --disable-private-endpoint-network-policies
```

Create the private endpoint
```
storage_account_id=$(az storage account show -g tools -n mpmtmc | jq -r '.id')

az network private-endpoint create -g tools -n mpmtmc-privateendpoint --subnet $subnet_id --private-connection-resource-id $storage_account_id --group-id "file" --connection-name
mpmtmc-connection
```

Create a private DNS zone for the private endpoint
```
az network private-dns zone create -g tools --name privatelink.file.core.windows.net
```

Create a dns vnet link in our private dns zone and link it to the tools vnet
```
network_id=$(az network vnet show -g tools -n tools | jq -r '.id')

az network private-dns link vnet create -g tools --zone-name privatelink.file.core.windows.net --name tools-dnslink --virtual-network $network_id --registration-enabled false
```

Create a DNS A record for the storage account / file share
```
private_endpoint_nic_id=$(az network private-endpoint show -g tools -n mpmtmc-privateendpoint | jq -r '.networkInterfaces[0].id')

private_endpoint_ip=$(az network nic show --ids $private_endpoint_nic_id | jq -r '.ipConfigurations[0].privateIpAddress')

az network private-dns record-set a create -g tools --zone-name privatelink.file.core.windows.net --name mpmtmc

az network private-dns record-set a add-record -g tools --zone-name privatelink.file.core.windows.net --record-set-name mpmtmc --ipv4-address $private_endpoint_ip
```

Test connectivity to the file share from the jumpbox now that the private endpoint, private dns zone, dns vnet link and dns A record were created for the storage account / file share
```
ubuntu@jumpbox:~$ nslookup mpmtmc.file.core.windows.net
Server:		127.0.0.53
Address:	127.0.0.53#53

Non-authoritative answer:
mpmtmc.file.core.windows.net	canonical name = mpmtmc.privatelink.file.core.windows.net.
Name:	mpmtmc.privatelink.file.core.windows.net
Address: 10.0.0.5

ubuntu@jumpbox:~$ nc -zv mpmtmc.file.core.windows.net 443
Connection to mpmtmc.file.core.windows.net (10.0.0.5) 443 port [tcp/https] succeeded!
```

[back-to-top](#contents)

## Offline Harbor Install
Now to create the offline Harbor VM:
```
az vm create --resource-group tools --name harbor --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202307010 --ssh-key-values ~/.ssh/tmc.pub --nsg internal --vnet-name tools --subnet tools --public-ip-address "" --size Standard_D4s_v3 --os-disk-size-gb 160 --admin-username ubuntu
```

Upload docker deb packages and harbor offline packages for an airgapped harbor install for use with an ubuntu 22.04 vm created above
```
mkdir airgapped-files
cd airgapped-files

# harbor offline installer
wget https://github.com/goharbor/harbor/releases/download/v2.8.1/harbor-offline-installer-v2.8.1.tgz

# containerd
wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/containerd.io_1.6.9-1_amd64.deb

# docker-ce
wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce_24.0.2-1~ubuntu.22.04~jammy_amd64.deb

# docker-ce-cli
wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-ce-cli_24.0.2-1~ubuntu.22.04~jammy_amd64.deb

# docker-compose-plugin
wget https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64/docker-compose-plugin_2.18.1-1~ubuntu.22.04~jammy_amd64.deb

export CONNECTION_STRING=$(az storage account show-connection-string --name mpmtmc --resource-group tools | jq -r '.connectionString')
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name mpmtmc --source harbor-offline-installer-v2.8.1.tgz
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name mpmtmc --source containerd.io_1.6.9-1_amd64.deb
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name mpmtmc --source docker-ce_24.0.2-1~ubuntu.22.04~jammy_amd64.deb
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name mpmtmc --source docker-ce-cli_24.0.2-1~ubuntu.22.04~jammy_amd64.deb
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name mpmtmc --source docker-compose-plugin_2.18.1-1~ubuntu.22.04~jammy_amd64.deb
```

[back-to-top](#contents)

## Mount File Share
Mount the file share to both the jumpbox and harbor vms.

In the Azure Portal, navigate to your storage account. Then select File Shares. Drill in to the `airgapped-files` file share that was created earlier. Click Connect then switch to Linux in the pop-up window and expand Show Script. Copy and run the script on both VMs. Your file share should now be mounted under `/mnt/airgapped-files` on the VMs.

If you dont have access to the azure portal you may be able to work through the above setup following this article:
https://learn.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-linux?tabs=Ubuntu%2Csmb311

[back-to-top](#contents)
