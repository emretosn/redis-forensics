// =============================================================================
// main.bicep — Redis forensic-readiness lab (3 VMs) on Azure.
//
// Deploys to a resource group. Assembles per-VM cloud-init by injecting
// base64-encoded config/scripts (with secrets/bind IPs substituted) into the
// cloud-init templates.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Prefix used to name all resources.')
param namePrefix string = 'redisfx'

@description('Admin username for SSH login on all VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user (contents of ~/.ssh/id_ed25519.pub).')
param adminPublicKey string

@description('Public IP/CIDR allowed to SSH into the client & forensics VMs.')
param adminSourceAddress string

@description('VM size for all three VMs.')
param vmSize string = 'Standard_B1s'

@description('Password for the Redis reader ACL user.')
@secure()
param readerPassword string

@description('Password for the Redis writer ACL user.')
@secure()
param writerPassword string

@description('Password for the Redis admin ACL user.')
@secure()
param adminPassword string

@description('Private SSH key redis-vm uses to push evidence to forensics-vm.')
@secure()
param collectorPrivateKey string

@description('Public SSH key added to forensics-vm authorized_keys for the collector user.')
param collectorPublicKey string

// --- Networking --------------------------------------------------------------

module net 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    adminSourceAddress: adminSourceAddress
  }
}

// --- cloud-init assembly: redis-vm -------------------------------------------

// forensics.env with admin password + collector (forensics-vm) private IP.
var redisEnvB64 = base64(replace(replace(
  loadTextContent('cloud-init/forensics.env.tmpl'),
  '__ADMIN_PASS__', adminPassword),
  '__COLLECTOR_HOST__', net.outputs.forensicsPrivateIp))

// redis.conf with the bind IP set to redis-vm's private address.
var redisConfB64 = base64(replace(
  loadTextContent('redis/redis.conf.tmpl'),
  '__BIND_IP__', net.outputs.redisPrivateIp))

// users.acl with reader/writer/admin passwords substituted.
var usersAclB64 = base64(replace(replace(replace(
  loadTextContent('redis/users.acl'),
  '__READER_PASS__', readerPassword),
  '__WRITER_PASS__', writerPassword),
  '__ADMIN_PASS__', adminPassword))

var collectorKeyB64 = base64(collectorPrivateKey)
var monitorB64 = base64(loadTextContent('scripts/forensic-monitor.sh'))
var configSnapB64 = base64(loadTextContent('scripts/forensic-config-snap.sh'))
var syncB64 = base64(loadTextContent('scripts/forensic-sync.sh'))
var seedB64 = base64(loadTextContent('scripts/seed-data.sh'))

var redisCustomData = base64(replace(replace(replace(replace(replace(replace(replace(replace(
  loadTextContent('cloud-init/redis.yaml'),
  '__ENV_B64__', redisEnvB64),
  '__REDIS_CONF_B64__', redisConfB64),
  '__USERS_ACL_B64__', usersAclB64),
  '__COLLECTOR_KEY_B64__', collectorKeyB64),
  '__MONITOR_B64__', monitorB64),
  '__CONFIGSNAP_B64__', configSnapB64),
  '__SYNC_B64__', syncB64),
  '__SEED_B64__', seedB64))

// --- cloud-init assembly: client-vm ------------------------------------------

var clientEnvB64 = base64(replace(replace(replace(replace(
  loadTextContent('cloud-init/client.env.tmpl'),
  '__REDIS_HOST__', net.outputs.redisPrivateIp),
  '__READER_PASS__', readerPassword),
  '__WRITER_PASS__', writerPassword),
  '__ADMIN_PASS__', adminPassword))

var queryB64 = base64(loadTextContent('scripts/redis-query.sh'))

var clientCustomData = base64(replace(replace(
  loadTextContent('cloud-init/client.yaml'),
  '__CLIENT_ENV_B64__', clientEnvB64),
  '__QUERY_B64__', queryB64))

// --- cloud-init assembly: forensics-vm ---------------------------------------

var forensicsCustomData = base64(replace(
  loadTextContent('cloud-init/forensics.yaml'),
  '__COLLECTOR_PUBKEY__', collectorPublicKey))

// --- Virtual machines --------------------------------------------------------

module redisVm 'modules/vm.bicep' = {
  name: 'redis-vm'
  params: {
    location: location
    vmName: '${namePrefix}-redis'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    nicId: net.outputs.redisNicId
    customDataBase64: redisCustomData
  }
}

module clientVm 'modules/vm.bicep' = {
  name: 'client-vm'
  params: {
    location: location
    vmName: '${namePrefix}-client'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    nicId: net.outputs.clientNicId
    customDataBase64: clientCustomData
  }
}

module forensicsVm 'modules/vm.bicep' = {
  name: 'forensics-vm'
  params: {
    location: location
    vmName: '${namePrefix}-forensics'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPublicKey: adminPublicKey
    nicId: net.outputs.forensicsNicId
    customDataBase64: forensicsCustomData
  }
}

// --- Outputs -----------------------------------------------------------------

output redisPrivateIp string = net.outputs.redisPrivateIp
output clientPublicIp string = net.outputs.clientPublicIp
output forensicsPublicIp string = net.outputs.forensicsPublicIp
output sshClient string = 'ssh ${adminUsername}@${net.outputs.clientPublicIp}'
output sshForensics string = 'ssh ${adminUsername}@${net.outputs.forensicsPublicIp}'
