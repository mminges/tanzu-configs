# Aigapped install of TMC-SM on private AKS cluster

## Contents
- [Prerequisites](#prerequisites)
- [Account Setup](#account-setup)
- IaaS Paving
  - [Tools Infra](#tools-infra-paving)
    - [Upload Offline Harbor Packages to File Share](#upload-offline-harbor-packages-to-file-share)
    - [Mount File Share](#mount-file-share)
    - [Offline Harbor Install](#offline-harbor-install)
    - [Make Harbor Accessible](#make-harbor-accessible)
    - [Push TMC Images to Harbor](#push-tmc-images-to-harbor)
  - [TMC-SM Infra](#tmc-sm-infra-paving)
    - [Create Azure Firewall](#create-azure-firewall)
    - [Create Airgapped AKS Cluster](#create-airgapped-aks-cluster)
    - [Add Custom CA to AKS CLuster](#add-custom-ca-to-aks-cluster)
- [Airgapped TMC-SM Install](#airgapped-tmc-sm-install)

## Prerequisites

- Need the Azure `az` client installed
- Need `jq` client installed
- Set your cloud, if you have not already done so:
  `az cloud set --name AzureCloud`
- Login: `az login`
- If you have access to more than one Azure Subscriptions, then run `az account list` to view your Subscriptions and set the default to the Subscription where you want the Jumpbox installed.
> `az account set --subscription SUBSCRIPTION_ID` where SUBSCRIPTION_ID is the value of the `id` field.

[back-to-top](#contents)

## Account Setup

For automation purposes (scripting or terraform) we are gonna create a Service Principal in Azure for our subscription

> NOTE: Service Principal names must be unique within the tenant

```bash
SUBSCRIPTION_ID=$(az account show | jq -r '.id')
SP_METADATA=$(az ad sp create-for-rbac --name="tmc-sm" --role="Owner" --scopes="/subscriptions/$SUBSCRIPTION_ID" | jq -r '.| "\(.appId) \(.password)"')

APP_ID=$(echo $SP_METADATA | cut -d ' ' -f1)
PASSWORD=$(echo $SP_METADATA | cut -d ' ' -f2)

```

Login as that service principal
```bash
TENANT_ID=$(az account show | jq -r '.homeTenantId')

az login --service-principal -u $APP_ID -p $PASSWORD --tenant $TENANT_ID
```

[back-to-top](#contents)


## Tools Infra Paving

In this section, we will create a tools resource group in Azure which will contain our Jumpbox and Harbor Container Registry along with necessary services to support an airgapped installation of TMC-sm.

Create a variables file and update the values inside to suit your need:
```bash
cat <<EOF > .envrc
export LOCATION=eastus
export STORAGE_ACCOUNT=mpmtmc
export PRIVATE_DNS_ZONE=mpmtmclab.io
EOF
```

Source the file to export the variables for your session:
```bash
source .envrc
```

> Note: location will differ depending on what cloud you are targeting and your use geographic location. To get a list of locations for your targeted cloud, run `az account list-locations | jq -r '.[].name'`


Create resource group for common tools
```bash
az group create --resource-group tools -l $LOCATION
```

Create a storage account in the tools resource group. This storage account will be used for offline artifact storage and as a velero backup location for TMC-sm later
```bash
az storage account create -n $STORAGE_ACCOUNT -g tools -l $LOCATION --sku Standard_LRS
```

Create a file share within the above storage account to be used as a mount on your jumpbox vm later
```bash
az storage share create --account-name $STORAGE_ACCOUNT --name airgapped-files
```

Create a container within the same storage account to be used for velero backups for TMC:
```bash
az storage container create -g tools -n backups --account-name $STORAGE_ACCOUNT
```

Grab a connection string for the file share to upload / download files
```bash
export CONNECTION_STRING=$(az storage account show-connection-string --name $STORAGE_ACCOUNT --resource-group tools | jq -r '.connectionString')
```

Download the TMC bundle and upload it to the file share
```bash
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name $STORAGE_ACCOUNT --source bundle-1.0.0.tar
```

Create vnet for tools network where jumpbox, harbor, etc, will go
```bash
az network vnet create -g tools -n tools --address-prefix 10.0.0.0/16 --subnet-name tools --subnet-prefix 10.0.0.0/24
```

Create network security group (nsg) for tools and modify for inbound SSH and deny outbound internet
```bash
az network nsg create -n internal -g tools

az network nsg rule create -g tools --nsg-name internal -n DenyInternet --priority 100 --destination-address-prefixes Internet --destination-port-ranges '*' --access Deny --protocol '*' --direction Outbound

az network nsg rule create -g tools --nsg-name internal -n AllowSSH --priority 100 --destination-port-ranges '22' --access Allow --protocol 'TCP' --direction Inbound
```

Create an SSH key pair for TMC:
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/tmc -q -N ""
```


Create ubuntu 22.04 vm with 100 gb disk and assign above nsg to the vm on the tools vnet and subnet
```bash
az vm create --resource-group tools --name jumpbox --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202307010 --ssh-key-values ~/.ssh/tmc.pub --nsg internal --vnet-name tools --subnet tools --public-ip-sku Standard --size Standard_D2s_v3 --os-disk-size-gb 100 --admin-username ubuntu
```

Create the offline Harbor VM with no public ip and assign above nsg to the vm on the tools vnet and subnet:
```bash
az vm create --resource-group tools --name harbor --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:22.04.202307010 --ssh-key-values ~/.ssh/tmc.pub --nsg internal --vnet-name tools --subnet tools --public-ip-address "" --size Standard_D4s_v3 --os-disk-size-gb 160 --admin-username ubuntu
```

SSH to the jumpbox:
```bash
jumpbox_nic_id=$(az vm show -g tools -n jumpbox | jq -r '.networkProfile.networkInterfaces[0].id')
jumpbox_public_ip_id=$(az network nic show --ids $jumpbox_nic_id | jq -r '.ipConfigurations[0].publicIPAddress.id')
jumpbox_public_ip=$(az network public-ip show --ids $jumpbox_public_ip_id | jq -r '.ipAddress')

ssh -i ~/.ssh/tmc ubuntu@$jumpbox_public_ip
```

After ssh'ing to the server validate egress to internet is blocked:
```bash
ubuntu@jumpbox:~$ nc -zv projects.registry.vmware.com 443 -w2
nc: connect to projects.registry.vmware.com port 443 (tcp) timed out: Operation now in progress
nc: connect to projects.registry.vmware.com port 443 (tcp) failed: Network is unreachable
nc: connect to projects.registry.vmware.com port 443 (tcp) failed: Network is unreachable
```

Disabling internet egress also disabled ability to connect to Azure services like storage accounts and file shares. In order to connect to these services we need to add private endpoints for our storage account in order to traverse the microsoft backbone without going over public internet. More info [here](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-networking-endpoints?tabs=azure-cli).


Exit out of the jumpbox and disable private endpoint network policies for the tools subnet
```bash
subnet_id=$(az network vnet subnet show -g tools --vnet-name tools -n tools | jq -r '.id')

az network vnet subnet update --ids $subnet_id --disable-private-endpoint-network-policies
```

Create the private endpoints for fileshare and blob storage
```bash
storage_account_id=$(az storage account show -g tools -n $STORAGE_ACCOUNT | jq -r '.id')

az network private-endpoint create -g tools -n $STORAGE_ACCOUNT-file-private-endpoint --subnet $subnet_id --private-connection-resource-id $storage_account_id --group-id "file" --connection-name $STORAGE_ACCOUNT-file-connection

az network private-endpoint create -g tools -n $STORAGE_ACCOUNT-blob-private-endpoint --subnet $subnet_id --private-connection-resource-id $storage_account_id --group-id "blob" --connection-name $STORAGE_ACCOUNT-blob-connection
```

Create private DNS zones for the fileshare and blob storage endpoints
```bash
az network private-dns zone create -g tools --name privatelink.file.core.windows.net
az network private-dns zone create -g tools --name privatelink.blob.core.windows.net
```

Create a dns vnet link in our private dns zone for the fileshare and blob storage and link it to the tools vnet
```bash
network_id=$(az network vnet show -g tools -n tools | jq -r '.id')

az network private-dns link vnet create -g tools --zone-name privatelink.file.core.windows.net --name tools-dnslink --virtual-network $network_id --registration-enabled false
az network private-dns link vnet create -g tools --zone-name privatelink.blob.core.windows.net --name tools-dnslink --virtual-network $network_id --registration-enabled false
```

Create a DNS A record for the fileshare and blob storage endpoints
```bash
file_private_endpoint_nic_id=$(az network private-endpoint show -g tools -n $STORAGE_ACCOUNT-file-private-endpoint | jq -r '.networkInterfaces[0].id')
file_private_endpoint_ip=$(az network nic show --ids $file_private_endpoint_nic_id | jq -r '.ipConfigurations[0].privateIPAddress')

blob_private_endpoint_nic_id=$(az network private-endpoint show -g tools -n $STORAGE_ACCOUNT-blob-private-endpoint | jq -r '.networkInterfaces[0].id')
blob_private_endpoint_ip=$(az network nic show --ids $blob_private_endpoint_nic_id | jq -r '.ipConfigurations[0].privateIPAddress')

az network private-dns record-set a create -g tools --zone-name privatelink.file.core.windows.net --name $STORAGE_ACCOUNT
az network private-dns record-set a add-record -g tools --zone-name privatelink.file.core.windows.net --record-set-name $STORAGE_ACCOUNT --ipv4-address $file_private_endpoint_ip

az network private-dns record-set a create -g tools --zone-name privatelink.blob.core.windows.net --name $STORAGE_ACCOUNT
az network private-dns record-set a add-record -g tools --zone-name privatelink.blob.core.windows.net --record-set-name $STORAGE_ACCOUNT --ipv4-address $blob_private_endpoint_ip
```

Test connectivity to the file share from the jumpbox now that the private endpoint, private dns zone, dns vnet link and dns A record were created for the storage account / file share
```bash
scp -i ~/.ssh/tmc .envrc ubuntu@$jumpbox_public_ip:.
ssh -i ~/.ssh/tmc ubuntu@$jumpbox_public_ip
source .envrc

nslookup $STORAGE_ACCOUNT.file.core.windows.net
nslookup $STORAGE_ACCOUNT.blob.core.windows.net

nc -zv $STORAGE_ACCOUNT.file.core.windows.net 443
nc -zv $STORAGE_ACCOUNT.blob.core.windows.net 443
```

The output should look similar to below example:
```bash
ubuntu@jumpbox:~$ nslookup $STORAGE_ACCOUNT.file.core.windows.net
Server:		127.0.0.53
Address:	127.0.0.53#53

Non-authoritative answer:
mpmtmc.file.core.windows.net	canonical name = mpmtmc.privatelink.file.core.windows.net.
Name:	mpmtmc.privatelink.file.core.windows.net
Address: 10.0.0.5

ubuntu@jumpbox:~$ nc -zv $STORAGE_ACCOUNT.file.core.windows.net 443
Connection to mpmtmc.file.core.windows.net (10.0.0.5) 443 port [tcp/https] succeeded!
```

[back-to-top](#contents)

## Upload Offline Harbor Packages to File Share 

Upload docker deb packages and harbor offline packages for an airgapped harbor install for use with an ubuntu 22.04 vm created above
```bash
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

export CONNECTION_STRING=$(az storage account show-connection-string --name $STORAGE_ACCOUNT --resource-group tools | jq -r '.connectionString')
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name $STORAGE_ACCOUNT --source harbor-offline-installer-v2.8.1.tgz
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name $STORAGE_ACCOUNT --source containerd.io_1.6.9-1_amd64.deb
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name $STORAGE_ACCOUNT --source docker-ce_24.0.2-1~ubuntu.22.04~jammy_amd64.deb
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name $STORAGE_ACCOUNT --source docker-ce-cli_24.0.2-1~ubuntu.22.04~jammy_amd64.deb
az storage file upload --connection-string $CONNECTION_STRING --share-name airgapped-files --account-name $STORAGE_ACCOUNT --source docker-compose-plugin_2.18.1-1~ubuntu.22.04~jammy_amd64.deb
```

[back-to-top](#contents)

## Mount File Share
Mount the file share to both the jumpbox and harbor vms.

In the Azure Portal, navigate to your storage account. Then select File Shares. Drill in to the `airgapped-files` file share that was created earlier. Click Connect then switch to Linux in the pop-up window and expand Show Script. Copy and run the script on both VMs. Your file share should now be mounted under `/mnt/airgapped-files` on the VMs.

If you dont have access to the azure portal you may be able to work through the above setup following this article:
https://learn.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-linux?tabs=Ubuntu%2Csmb311

[back-to-top](#contents)

## Offline Harbor Install

Generate the CA to be used by TMC and the Harbor server certificate which will be signed by that same CA
```bash
./gen_certs.sh
```

SCP the certs directory thats generated from the above script onto Harbor VM so we can install docker and the offline harbor installer

> The following commands should be run as the root user: `sudo su -`

Make the data directory
```bash
mkdir /data
```

Install docker-ce cli package:
```bash
dpkg -i docker-ce-cli_24.0.2-1~ubuntu.22.04~jammy_amd64.deb
```

Install containerd.io package:
```bash
dpkg -i containerd.io_1.6.9-1_amd64.deb
```

Install docker-ce:
```bash
dpkg -i docker-ce_24.0.2-1~ubuntu.22.04~jammy_amd64.deb
```

Install docker compose
```bash
dpkg -i docker-compose-plugin_2.18.1-1~ubuntu.22.04~jammy_amd64.deb
```

Check docker service status:
```bash
systemctl status docker
```

Copy harbor.crt as harbor-chain.crt:
```bash
cp /home/ubuntu/certs/harbor.crt /data/harbor-chain.crt
```

Add the contents of the ca cert to the harbor chain:
```bash
cat /home/ubuntu/certs/ca.crt >> /data/harbor-chain.crt
```

Copy harbor.key to the data directory:
```bash
cp /home/ubuntu/certs/harbor.key /data/
```

Copy ca cert into ca-certificates:
```bash
cp /home/ubuntu/certs/ca.crt /usr/local/share/ca-certificates/
```

Update ca-certificates
```bash
update-ca-certificates
```

Untar harbor offline installer files to /data directory:
```bash
tar -xzf /mnt/airgapped-files/harbor-offline-installer-v2.8.1.tgz -C /data
```

Copy harbor.yml.tmpl to harbor.yml
```bash
cp /data/harbor/harbor.yml.tmpl /data/harbor/harbor.yml
```

Update the hostname, password, certificate, and private_key values in the yaml file
```bash
vi /data/harbor/harbor.yml
```

Deploy harbor:
```bash
cd /data/harbor
./install.sh --with-trivy --with-notary
```

## Make Harbor Accessible
With harbor now stood up, we need to create a private DNS zone that has an A record for Harbor and eventually wildcard records for TMC-sm

```bash
# Create private dns zone for $PRIVATE_DNS_ZONE
az network private-dns zone create -g tools --name $PRIVATE_DNS_ZONE

# Create dns vnet link for the above zone to the tools vnet
network_id=$(az network vnet show -g tools -n tools | jq -r '.id')
az network private-dns link vnet create -g tools --zone-name $PRIVATE_DNS_ZONE --name tools-dnslink --virtual-network $network_id --registration-enabled false

# Grab the Harbor private IP address
harbor_nic_id=$(az vm show -g tools -n harbor | jq -r '.networkProfile.networkInterfaces[0].id')
harbor_private_ip=$(az network nic show --ids $harbor_nic_id | jq -r '.ipConfigurations[0].privateIPAddress')

#Create the DNS A record for harbor using the private ip address
az network private-dns record-set a create -g tools --zone-name $PRIVATE_DNS_ZONE --name harbor
az network private-dns record-set a add-record -g tools --zone-name $PRIVATE_DNS_ZONE --record-set-name harbor --ipv4-address $harbor_private_ip
```

[back-to-top](#contents)

## Push TMC Images to Harbor
Now that harbor is accessible from the jumpbox, we need to push the tmc images to harbor

Login to the Harbor UI and create a public project called `tmc`

We need to add the CA cert for harbor to the list of trusted CAs on the jumpbox
```
sudo cp ~/certs/certman_ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

On the jumpbox we will use the file share to extract the tmc-sm bundle and push the images to harbor:
```
mkdir ~/tmc
tar -xf /mnt/airgapped-files/bundle-1.0.0.tar -C ~/tmc/

export HARBOR_PROJECT=harbor.$PRIVATE_DNS_ZONE/tmc
export HARBOR_USERNAME=admin
export HARBOR_PASSWORD=REDACTED

~/tmc/tmc-sm push-images harbor
```

[back-to-top](#contents)

## TMC-SM Infra Paving

Create tmc-sm resource group and vnet
```
az group create --resource-group tmcsm -l eastus
az network vnet create -g tmcsm -n tmcsm --address-prefix 10.1.0.0/16 --subnet-name tmcsm --subnet-prefix 10.1.0.0/24
```

Create vnet peering from tools vnet to tmcsm vnet
```
tmcsm_vnet_id=$(az network vnet show -g tmcsm -n tmcsm | jq -r '.id')
tools_vnet_id=$(az network vnet show -g tools -n tools | jq -r '.id')

az network vnet peering create -g tools -n tools-to-tmc --vnet-name tools --remote-vnet $tmcsm_vnet_id --allow-vnet-access
az network vnet peering create -g tmcsm -n tmc-to-tools --vnet-name tmcsm --remote-vnet $tools_vnet_id --allow-vnet-access
```

Create a dns vnet link in our private dns zone for the blob endpoint and link it to the tmcsm vnet. This is needed in order for velero to backup to a container in the storage account
```bash
tmcsm_network_id=$(az network vnet show -g tmcsm -n tmcsm | jq -r '.id')

az network private-dns link vnet create -g tools --zone-name privatelink.blob.core.windows.net --name tmcsm-dnslink --virtual-network $tmcsm_network_id --registration-enabled false
```

[back-to-top](#contents)

## Create Azure Firewall

Followed most of this [medium post](https://denniszielke.medium.com/fully-private-aks-clusters-without-any-public-ips-finally-7f5688411184) in order to create an Azure Firewall which allowed for us to create a truly airgapped cluster.

Azure Firewall requires a subnet with name AzureFirewallSubnet to be created
```bash
az network vnet subnet create -g tools --vnet-name tools -n AzureFirewallSubnet --address-prefixes 10.0.1.0/24
```

Create Azure Firewall
```bash
az extension add --name azure-firewall
az network firewall create --name aksfw -g tools
az network public-ip create -g tools -n aksfw --sku Standard
az network firewall ip-config create --firewall-name aksfw --name aksfw --public-ip-address aksfw -g tools --vnet-name tools
```

Create Azure Route Table and route for egress to route to the firewall's private ip
```bash
fw_private_ip=$(az network firewall show -g tools -n aksfw | jq -r '.ipConfigurations[0].privateIPAddress')
az network route-table create -g tools -n aksfw
az network route-table route create -g tools -n aksfw --route-table-name aksfw --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $fw_private_ip
```

Update the AKS cluster's subnet with the route table we just created which route egress to the firewall
```bash
aksfw_route_table_id=$(az network route-table show -g tools -n aksfw | jq -r '.id')
tmc_subnet_id=$(az network vnet subnet show -g tmcsm --vnet-name tmcsm -n tmcsm | jq -r '.id')
az network vnet subnet update --route-table $aksfw_route_table_id --ids $tmc_subnet_id
```

Create a network firewall rule allowing for ntp
```bash
az network firewall network-rule create --firewall-name aksfw --collection-name "time" --destination-addresses "*"  --destination-ports 123 --name "allow network" --protocols "UDP" -g tools --source-addresses "*" --action "Allow" --description "aks node time sync rule" --priority 101
```

Create a network firewall rule for allowing for dns
```bash
az network firewall network-rule create --firewall-name aksfw --collection-name "dns" --destination-addresses "*"  --destination-ports 53 --name "allow network" --protocols "UDP" -g tools --source-addresses "*" --action "Allow" --description "aks node dns rule" --priority 102
```

Create a network firewall rule allowing for access to MicrosoftContainerRegistry, AzureContainerRegistry, AzureActiveDirectory and AzureMonitor
```bash
az network firewall network-rule create --firewall-name aksfw --collection-name "servicetags" --destination-addresses "AzureContainerRegistry" "MicrosoftContainerRegistry" "AzureActiveDirectory" "AzureMonitor" --destination-ports "*" --name "allow service tags" --protocols "Any" -g tools --source-addresses "*" --action "Allow" --description "allow service tags" --priority 110
```

Create an application firewall rule allowing for AKS fqdn tags
```bash
az network firewall application-rule create --firewall-name aksfw -g tools --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'http=80' 'https=443' --fqdn-tags "AzureKubernetesService" --action allow --priority 101
```

Create an application firewall rule allowing for VM security updates
```bash
az network firewall application-rule create  --firewall-name aksfw --collection-name "osupdates" --name "allow network" --protocols http=80 https=443 --source-addresses "*" -g tools --action "Allow" --target-fqdns "download.opensuse.org" "security.ubuntu.com" "packages.microsoft.com" "azure.archive.ubuntu.com" "changelogs.ubuntu.com" "snapcraft.io" "api.snapcraft.io" "motd.ubuntu.com"  --priority 102
```

[back-to-top](#contents)

## Create Airgapped AKS cluster

Create AKS private cluster with user defined routes
```bash
az aks create -n tmc-sm -g tmcsm --disable-public-fqdn --enable-private-cluster --max-pods 40 --enable-cluster-autoscaler --min-count 1 --max-count 7 --network-plugin azure --network-policy calico --node-vm-size standard_d4s_v3 --node-osdisk-size 40 --os-sku Ubuntu --private-dns-zone system --service-cidr 10.0.0.0/16 --dns-service-ip 10.0.0.10 --vnet-subnet-id $subnet_id --zones 1 --zones 2 --zones 3 --outbound-type userDefinedRouting --load-balancer-sku standard --client-secret $CLIENT_SECRET --service-principal $CLIENT_ID
```

Create dns vnet link for the private dns zone created as part of the aks cluster creation as well as for the priavte dns zone for our tmc private dns zone:
```bash
aks_resource_group=$(az group list | jq -r '.[] | select(.tags."aks-managed-cluster-name" == "tmc-sm") .name')
aks_private_dns_zone_name=$(az network private-dns zone list -g $aks_resource_group | jq -r '.[0].name')
network_id=$(az network vnet show -g tools -n tools | jq -r '.id')
tmc_network_id=$(az network vnet show -g tmcsm -n tmcsm | jq -r '.id')

az network private-dns link vnet create -g $aks_resource_group --zone-name $aks_private_dns_zone_name --name tools-dnslink --virtual-network $network_id --registration-enabled false
az network private-dns link vnet create -g tools --zone-name $PRIVATE_DNS_ZONE --name tmc-dnslink --virtual-network $tmc_network_id --registration-enabled false
```

Export the kubeconfig for the cluster:
```bash
az aks get-credentials -g tmcsm -n tmc-sm -f tmc-kubeconfig.yaml
```

SCP the kubeconfig file to the jumpbox and install kubectl from the fileshare mount to access your cluster

[back-to-top](#contents)

## Add Custom CA to AKS CLuster

In order to add our custom CA to the AKS cluster's nodes we will need to install an azure extension and register a feature flag
```bash
az extension add --name aks-preview
az extension update --name aks-preview
az feature register --namespace "Microsoft.ContainerService" --name "CustomCATrustPreview"
```

The last command can take several minutes to complete. Check the status of the registration by running the following:
```bash
az feature show --namespace "Microsoft.ContainerService" --name "CustomCATrustPreview"
```

> Note: Don't proceed until the status shows `Registered`

Refresh the registration of the Microsoft.ContainerService resource provider:
```bash
az provider register --namespace Microsoft.ContainerService
```

Now add the custom CA to the AKS nodes:
```bash
az aks update -g tmcsm -n tmc-sm --custom-ca-trust-certificates certs/ca.crt 
```

[back-to-top](#contents)

## Airgapped TMC-SM Install

Leveraged the following github [repo](https://github.com/gorkemozlu/tanzu-gitops/tree/master/tmc-sm) for common configs to deploy TMC self-managed
- deploy kapp-controller
- deploy cert-manager
- deploy openldap
- deploy tmc
- convert pinniped auth from oidc to openldap
- create DNS records for `tmc.YOUR_DOMAIN` and `*.tmc.YOUR_DOMAIN` that point to the private load balancer ip for envoy

In order to create a private loadbalancer for envoy you will need this annotation in your TMC values.yaml
```bash
contourEnvoy:
  serviceType: LoadBalancer
  serviceAnnotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

[back-to-top](#contents)
