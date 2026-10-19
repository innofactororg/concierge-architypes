@{
  # This checker's own copy of the reserved [#_..._#] substitution-token vocabulary
  # (concierge-app docs/main/concierge-seeding-contract.md SS2, schemaVersion 1 - 15 tokens, not
  # 16). Test-ArchitypeConformance.ps1 cannot import the Concierge PowerShell module, so it
  # carries this copy instead. CI's vocabulary-parity job (architype-ci.yml) checks out
  # concierge-app and asserts Token/CanonicalParameter/Indexed here are identical to what
  # Get-NewSpokeReservedToken returns there, so the two cannot drift apart silently (T-02-1202).
  #
  # `Sample` is this file's own addition, not part of the contract: a representative literal
  # value the checker substitutes for each token when proving a Bicep architype's template and
  # parameter file build TOGETHER (check 5) and scan cleanly under PSRule (check 6). It plays no
  # role in the vocabulary-parity comparison.
  SchemaVersion = 1
  Tokens        = @(
    @{ Token = '[#_service.subscription.id_#]'; CanonicalParameter = 'subscriptionId'; Indexed = $false; Sample = '00000000-0000-0000-0000-000000000000' }
    @{ Token = '[#_service.name_#]'; CanonicalParameter = 'workloadName'; Indexed = $false; Sample = 'unittest' }
    @{ Token = '[#_service.environment_#]'; CanonicalParameter = 'environmentCode'; Indexed = $false; Sample = 't' }
    @{ Token = '[#_service.environmentName_#]'; CanonicalParameter = 'environmentName'; Indexed = $false; Sample = 'test' }
    @{ Token = '[#_service.deployclient.id_#]'; CanonicalParameter = 'deployClientId'; Indexed = $false; Sample = '00000000-0000-0000-0000-000000000000' }
    @{ Token = '[#_service.adoEnvironment.name_#]'; CanonicalParameter = 'adoEnvironmentName'; Indexed = $false; Sample = 'GEN3-TEST' }
    @{ Token = '[#_service.serviceConnection.name_#]'; CanonicalParameter = 'serviceConnectionName'; Indexed = $false; Sample = 'AZ_SP_sub_t-unittest_Owner' }
    @{ Token = '[#_service.managementgroup_#]'; CanonicalParameter = 'managementGroupName'; Indexed = $false; Sample = 'mg-test' }
    @{ Token = '[#_service.vnet.addressPrefix_#]'; CanonicalParameter = 'vnetAddressPrefix'; Indexed = $false; Sample = '10.0.0.0/25' }
    @{ Token = '[#_service.vnet.subnet.NN.addressPrefix_#]'; CanonicalParameter = 'subnetAddressPrefixes'; Indexed = $true; Sample = '10.0.0.0/27' }
    @{ Token = '[#_recoveryservices.rundate_#]'; CanonicalParameter = 'recoveryServicesRunDate'; Indexed = $false; Sample = '2026-09-05' }
    @{ Token = '[#_softwareupdate.run.startdate_#]'; CanonicalParameter = 'softwareUpdateStartDate'; Indexed = $false; Sample = '2026-09-02' }
    @{ Token = '[#_provenance.orderId_#]'; CanonicalParameter = 'orderId'; Indexed = $false; Sample = '12345' }
    @{ Token = '[#_provenance.workload_#]'; CanonicalParameter = 'workloadName'; Indexed = $false; Sample = 'unittest' }
    @{ Token = '[#_provenance.environment_#]'; CanonicalParameter = 'environmentCode'; Indexed = $false; Sample = 't' }
    @{ Token = '[#_provenance.requestedBy_#]'; CanonicalParameter = 'requestedBy'; Indexed = $false; Sample = 'test@example.com' }
    @{ Token = '[#_provenance.architypeVersion_#]'; CanonicalParameter = 'architypeVersion'; Indexed = $false; Sample = '1.0.0' }
  )
}
