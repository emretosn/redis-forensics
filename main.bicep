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
param vmSize string = 'Standard_B2ts_v2'

@description('Password for the Redis reader ACL user.')
@secure()
param readerPassword string

@description('Password for the Redis writer ACL user.')
@secure()
param writerPassword string

@description('Password for the Redis admin ACL user.')
@secure()
param adminPassword string

@description('Private SSH key forensics-vm uses to PULL evidence from redis-vm.')
@secure()
param pullPrivateKey string

@description('Public SSH key added to the restricted evidence user on redis-vm.')
param pullPublicKey string

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

// forensics.env with the Redis admin password (local-only; no collector creds).
var redisEnvB64 = base64(replace(
  loadTextContent('cloud-init/forensics.env.tmpl'),
  '__ADMIN_PASS__', adminPassword))

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

var monitorB64 = base64(loadTextContent('scripts/forensic-monitor.sh'))
var configSnapB64 = base64(loadTextContent('scripts/forensic-config-snap.sh'))
var exportB64 = base64(loadTextContent('scripts/forensic-export-local.sh'))
var seedB64 = base64(loadTextContent('scripts/seed-data.sh'))

var redisCustomData = base64(replace(replace(replace(replace(replace(replace(replace(replace(
  loadTextContent('cloud-init/redis.yaml'),
  '__ENV_B64__', redisEnvB64),
  '__REDIS_CONF_B64__', redisConfB64),
  '__USERS_ACL_B64__', usersAclB64),
  '__PULL_PUBKEY__', trim(pullPublicKey)),
  '__MONITOR_B64__', monitorB64),
  '__CONFIGSNAP_B64__', configSnapB64),
  '__EXPORT_B64__', exportB64),
  '__SEED_B64__', seedB64))

// --- cloud-init assembly: client-vm ------------------------------------------

var clientEnvB64 = base64(replace(
  loadTextContent('cloud-init/client.env.tmpl'),
  '__REDIS_HOST__', net.outputs.redisPrivateIp))

var queryB64 = base64(loadTextContent('scripts/redis-query.sh'))

var clientCustomData = base64(replace(replace(
  loadTextContent('cloud-init/client.yaml'),
  '__CLIENT_ENV_B64__', clientEnvB64),
  '__QUERY_B64__', queryB64))

// --- cloud-init assembly: forensics-vm ---------------------------------------

// pull.env with the redis-vm private IP as the evidence source host.
var pullEnvB64 = base64(replace(
  loadTextContent('cloud-init/pull.env.tmpl'),
  '__REDIS_HOST__', net.outputs.redisPrivateIp))

var pullKeyB64 = base64(pullPrivateKey)
var pullScriptB64 = base64(loadTextContent('scripts/forensic-pull.sh'))

var forensicsCustomData = base64(replace(replace(replace(
  loadTextContent('cloud-init/forensics.yaml'),
  '__PULL_ENV_B64__', pullEnvB64),
  '__PULL_KEY_B64__', pullKeyB64),
  '__PULL_B64__', pullScriptB64))

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
