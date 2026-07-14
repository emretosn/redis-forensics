// =============================================================================
// network.bicep — two peered VNets, subnets, NSGs, public IPs and NICs.
//
// Layout (production-shaped): the collector lives in a SEPARATE VNet from the
// Redis source so a compromise of the Redis network cannot reach the evidence
// network beyond the single, one-directional pull path.
//
//   VNet-A  10.0.0.0/16  subnet 'lab' 10.0.1.0/24
//     redis   10.0.1.4   (private only)
//     client  10.0.1.5   (public SSH)
//   VNet-B  10.1.0.0/16  subnet 'fx'  10.1.1.0/24
//     forensics 10.1.1.6 (public SSH)
//
// A<->B VNet peering lets forensics-vm PULL evidence from redis-vm over private
// IPs on the Azure backbone. Address spaces do not overlap (peering requires it).
// =============================================================================

@description('Azure region for all resources.')
param location string

@description('Prefix for resource names.')
param namePrefix string

@description('Public source IP/CIDR allowed to SSH into client & forensics VMs.')
param adminSourceAddress string

// --- VNet-A (redis + client) -------------------------------------------------
var vnetAName = '${namePrefix}-vnet'
var subnetAName = 'lab'
var vnetAPrefix = '10.0.0.0/16'
var subnetAPrefix = '10.0.1.0/24'
var redisPrivateIp = '10.0.1.4'
var clientPrivateIp = '10.0.1.5'

// --- VNet-B (forensics collector) --------------------------------------------
var vnetBName = '${namePrefix}-fx-vnet'
var subnetBName = 'fx'
var vnetBPrefix = '10.1.0.0/16'
var subnetBPrefix = '10.1.1.0/24'
var forensicsPrivateIp = '10.1.1.6'

// --- NSGs --------------------------------------------------------------------

// redis-vm: reachable only from within the (peered) VNet address space.
// The 'VirtualNetwork' service tag includes peered VNets, so forensics-vm's pull
// (SSH to 22) and the client's queries (6379) are both covered. An explicit rule
// for the forensics IP documents the evidence-pull path.
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
        name: 'allow-ssh-from-forensics'
        properties: {
          priority: 105
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: forensicsPrivateIp
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

// forensics-vm: SSH from admin ONLY. In the pull model the collector initiates
// all transfers, so it needs NO inbound rule for redis-vm (smaller attack surface,
// and redis-vm has no network path into the evidence VNet).
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
    ]
  }
}

// --- VNets + subnets ---------------------------------------------------------

resource vnetA 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetAName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAPrefix ]
    }
    subnets: [
      {
        name: subnetAName
        properties: {
          addressPrefix: subnetAPrefix
        }
      }
    ]
  }
}

resource vnetB 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetBName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetBPrefix ]
    }
    subnets: [
      {
        name: subnetBName
        properties: {
          addressPrefix: subnetBPrefix
        }
      }
    ]
  }
}

// --- VNet peering A <-> B ----------------------------------------------------

resource peerAtoB 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: vnetA
  name: 'to-${vnetBName}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: vnetB.id
    }
  }
}

resource peerBtoA 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: vnetB
  name: 'to-${vnetAName}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: vnetA.id
    }
  }
}

var subnetAId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetAName, subnetAName)
var subnetBId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetBName, subnetBName)

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
            id: subnetAId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: redisPrivateIp
        }
      }
    ]
  }
  dependsOn: [ vnetA ]
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
            id: subnetAId
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
  dependsOn: [ vnetA ]
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
            id: subnetBId
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
  dependsOn: [ vnetB ]
}

// --- Outputs -----------------------------------------------------------------

output redisNicId string = redisNic.id
output clientNicId string = clientNic.id
output forensicsNicId string = forensicsNic.id

output redisPrivateIp string = redisPrivateIp
output clientPrivateIp string = clientPrivateIp
output forensicsPrivateIp string = forensicsPrivateIp

output clientPublicIp string = clientPip.properties.ipAddress
output forensicsPublicIp string = forensicsPip.properties.ipAddress
