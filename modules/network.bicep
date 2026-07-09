// =============================================================================
// network.bicep — VNet, subnet, NSGs, public IPs and NICs for the 3-VM lab.
//
// Layout: single VNet 10.0.0.0/16 with one subnet 10.0.1.0/24.
// Static private IPs: redis .4, client .5, forensics .6.
// Public IPs: client + forensics only (redis is private-only).
// =============================================================================

@description('Azure region for all resources.')
param location string

@description('Prefix for resource names.')
param namePrefix string

@description('Public source IP/CIDR allowed to SSH into client & forensics VMs.')
param adminSourceAddress string

var vnetName = '${namePrefix}-vnet'
var subnetName = 'lab'
var subnetPrefix = '10.0.1.0/24'
var redisPrivateIp = '10.0.1.4'
var clientPrivateIp = '10.0.1.5'
var forensicsPrivateIp = '10.0.1.6'

// --- NSGs --------------------------------------------------------------------

// redis-vm: reachable only from within the VNet (SSH + Redis 6379). No internet inbound.
resource redisNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-redis-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh-from-vnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'allow-redis-from-vnet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '6379'
        }
      }
    ]
  }
}

// client-vm: SSH from the admin source address only.
resource clientNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-client-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh-from-admin'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceAddress
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// forensics-vm: SSH from admin source AND from redis-vm (for rsync push).
resource forensicsNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-forensics-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh-from-admin'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceAddress
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'allow-ssh-from-redis'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: redisPrivateIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// --- VNet + subnet -----------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
        }
      }
    ]
  }
}

var subnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

// --- Public IPs (client + forensics only) ------------------------------------

resource clientPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${namePrefix}-client-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource forensicsPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${namePrefix}-forensics-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// --- NICs --------------------------------------------------------------------

resource redisNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${namePrefix}-redis-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: redisNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: redisPrivateIp
        }
      }
    ]
  }
  dependsOn: [ vnet ]
}

resource clientNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${namePrefix}-client-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: clientNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: clientPrivateIp
          publicIPAddress: {
            id: clientPip.id
          }
        }
      }
    ]
  }
  dependsOn: [ vnet ]
}

resource forensicsNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${namePrefix}-forensics-nic'
  location: location
  properties: {
    networkSecurityGroup: {
      id: forensicsNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: forensicsPrivateIp
          publicIPAddress: {
            id: forensicsPip.id
          }
        }
      }
    ]
  }
  dependsOn: [ vnet ]
}

// --- Outputs -----------------------------------------------------------------

output redisNicId string = redisNic.id
output clientNicId string = clientNic.id
output forensicsNicId string = forensicsNic.id

output redisPrivateIp string = redisPrivateIp
output clientPrivateIp string = clientPrivateIp
output forensicsPrivateIp string = forensicsPrivateIp
