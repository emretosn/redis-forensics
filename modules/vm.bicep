// =============================================================================
// vm.bicep — reusable Ubuntu 22.04 Linux VM with SSH key auth and cloud-init.
// =============================================================================

@description('Azure region.')
param location string

@description('VM name.')
param vmName string

@description('VM size.')
param vmSize string = 'Standard_B1s'

@description('Admin username for SSH login.')
param adminUsername string

@description('SSH public key for the admin user.')
param adminPublicKey string

@description('Resource ID of the NIC to attach.')
param nicId string

@description('Base64-encoded cloud-init customData.')
param customDataBase64 string

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: customDataBase64
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicId
        }
      ]
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
