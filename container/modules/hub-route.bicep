//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/hub-route.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// A route in the hub's GatewaySubnet route table for this spoke's address range, so return traffic
// from the VPN gateway to the spoke goes through the hub firewall. Deployed into the hub resource
// group, which needs a platform grant (the deploy identity must be allowed to write routes there).
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Name of the existing hub GatewaySubnet route table.')
param routeTableName string

@description('Name of the route to create: the spoke VNet name.')
param routeName string

@description('The spoke address range.')
param addressPrefix string

@description('Private IP of the hub firewall.')
param nextHopIpAddress string

resource routeTable 'Microsoft.Network/routeTables@2023-04-01' existing = {
  name: routeTableName
}

resource route 'Microsoft.Network/routeTables/routes@2023-04-01' = {
  parent: routeTable
  name: routeName
  properties: {
    addressPrefix: addressPrefix
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: nextHopIpAddress
  }
}
