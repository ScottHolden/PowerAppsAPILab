param prefix string = 'powerappdemo'
param location string = resourceGroup().location
param email string = 'noreply@microsoft.com'

var uniqueName = '${prefix}${uniqueString(prefix, resourceGroup().id)}'

var databaseName = 'ClaimsDB'
var tableName = 'Claims'
var apiName = 'claims'
var apiTitle = 'Claims API'
var operationName = 'getclaims'
var operationTitle = 'Get Claims from Database'
var schemaName = 'ClaimList'
var backendName = uniqueName
var sigNamedValue = '${uniqueName}_${apiName}_sig'
var seedLogicAppName = '${uniqueName}-seed'
var logicAppOperatorRoleId = '515c2055-d9d4-4321-b1b9-bd0c9a0f79fe'

var claimsPolicyXML = loadTextContent('Policies/claimsPolicy.xml')
var claimsListSchema = json('{"${schemaName}":${loadTextContent('Schemas/claimList.json')}}')
// For faster deploys, switched to logic app deployment
//var sqlScript = loadTextContent('Scripts/sqlScript.ps1')
var sqlSeedQuery = replace(loadTextContent('Scripts/seed.sql'), '{{TABLENAME}}', tableName)

// Putting this into a single file instead of modules so only a single deployment shows up

resource apim 'Microsoft.ApiManagement/service@2021-08-01' = {
  name: uniqueName
  location: location
  sku: {
    capacity: 0
    name: 'Consumption'
  }
  properties: {
    publisherEmail: email
    publisherName: prefix
  }

  resource backend 'backends@2021-08-01' = {
    name: backendName
    properties: {
      protocol: 'http'
      url: '${logicApp.properties.accessEndpoint}/triggers'
      resourceId: 'https://${environment().resourceManager}/${logicApp.id}'
      description: backendName
    }
  }

  resource sig 'namedValues@2021-08-01' = {
    name: sigNamedValue
    properties: {
      displayName: sigNamedValue
      secret: true
      value: listCallbackUrl('${logicApp.id}/triggers/manual', '2016-10-01').queries.sig
    }
  }

  resource api 'apis@2021-08-01' = {
    name: apiName
    properties: {
      displayName: apiTitle
      protocols: [
        'https'
      ]
      path: apiName
      serviceUrl: '${logicApp.properties.accessEndpoint}/triggers'
      subscriptionRequired: true
    }
    resource listSchema 'schemas@2021-08-01' = {
      name: uniqueString(schemaName)
      properties: {
        contentType: 'application/vnd.oai.openapi.components+json'
        document: {
          components: {
            schemas: claimsListSchema
          }
        }
      }
    }
    resource getApi 'operations@2021-08-01' = {
      name: operationName
      properties: {
        displayName: operationTitle
        method: 'get'
        urlTemplate: '/'
        responses: [
          {
            statusCode: 200
            description: operationTitle
            representations: [
              {
                contentType: 'application/json'
                schemaId: uniqueString(schemaName)
                typeName: schemaName
              }
            ]
          }
        ]
      }
      dependsOn: [
        listSchema
      ]
      resource policy 'policies@2021-08-01' = {
        name: 'policy'
        properties: {
          format: 'rawxml'
          value: replace(replace(claimsPolicyXML, '{{sigNamedValue}}', '{{${sigNamedValue}}}'), '{{backendId}}', backendName)
        }
      }
    }
  }
}

resource sqlServer 'Microsoft.Sql/servers@2021-08-01-preview' = {
  name: uniqueName
  location: location
  properties: {
    version: '12.0'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'Application'
      login: sqlAdminIdentity.name
      sid: sqlAdminIdentity.properties.principalId
      tenantId: sqlAdminIdentity.properties.tenantId
    }
  }

  resource allowedIps 'firewallRules@2021-08-01-preview' = {
    name: 'AllowAllWindowsAzureIps'
    properties: {
      endIpAddress: '0.0.0.0'
      startIpAddress: '0.0.0.0'
    }
  }
}

resource sqlDB 'Microsoft.Sql/servers/databases@2021-08-01-preview' = {
  name: databaseName
  location: location
  parent: sqlServer
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

resource sqlAdminIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: uniqueName
  location: location
}

resource sqlConnection 'Microsoft.Web/connections@2018-07-01-preview' = {
  name: 'sql'
  location: location
  properties: {
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
    }
    displayName: 'sqlConnection'
    parameterValueSet: {
      name: 'oauthMI'
      values: {}
    }
  }
}

resource armConnection 'Microsoft.Web/connections@2018-07-01-preview' = {
  name: 'arm'
  location: location
  properties: {
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'arm')
    }
    displayName: 'arm'
    parameterValueType: 'Alternative'
    alternativeParameterValues: {}
  }
}

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: uniqueName
  location: location
  properties: {
    parameters: {
      '$connections': {
        value: {
          sql: {
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
            connectionId: sqlConnection.id
            connectionName: 'sql'
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: sqlAdminIdentity.id
              }
            }
          }
        }
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          type: 'Object'
        }
      }
      triggers: {
        manual: {
          kind: 'Http'
          type: 'Request'
          inputs: {
            method: 'GET'
            schema: {}
          }
        }
      }
      actions: {
        SqlQuery: {
          type: 'ApiConnection'
          inputs: {
            body: {
              query: 'SELECT * FROM ${tableName}'
            }
            method: 'post'
            path: '/v2/datasets/@{encodeURIComponent(encodeURIComponent(\'${sqlServer.properties.fullyQualifiedDomainName}\'))},@{encodeURIComponent(encodeURIComponent(\'${databaseName}\'))}/query/sql'
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'sql\'][\'connectionId\']'
              }
            }
          }
        }
        Response: {
          kind: 'Http'
          type: 'Response'
          inputs: {
            statusCode: 200
            body: '@body(\'SqlQuery\')?[\'resultsets\']?[\'Table1\']'
          }
          runAfter: {
            SqlQuery: [
              'Succeeded'
            ]
          }
        }
      }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sqlAdminIdentity.id}': {}
    }
  }
}

resource logicAppSeed 'Microsoft.Logic/workflows@2019-05-01' = {
  name: seedLogicAppName
  location: location
  properties: {
    parameters: {
      '$connections': {
        value: {
          sql: {
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sql')
            connectionId: sqlConnection.id
            connectionName: 'sql'
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: sqlAdminIdentity.id
              }
            }
          }
          arm: {
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'arm')
            connectionId: armConnection.id
            connectionName: 'arm'
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: sqlAdminIdentity.id
              }
            }
          }
        }
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          type: 'Object'
        }
      }
      triggers: {
        Recurrence: {
          recurrence: {
              frequency: 'Minute'
              interval: 1
          }
          type: 'Recurrence'
        }
      }
      actions: {
        SqlQuery: {
          type: 'ApiConnection'
          inputs: {
            body: {
              query: sqlSeedQuery
            }
            method: 'post'
            path: '/v2/datasets/@{encodeURIComponent(encodeURIComponent(\'${sqlServer.properties.fullyQualifiedDomainName}\'))},@{encodeURIComponent(encodeURIComponent(\'${databaseName}\'))}/query/sql'
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'sql\'][\'connectionId\']'
              }
            }
          }
        }
        DisableLogicApp: {
          inputs: {
              host: {
                  connection: {
                      name: '@parameters(\'$connections\')[\'arm\'][\'connectionId\']'
                  }
              }
              method: 'post'
              path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resourcegroups/@{encodeURIComponent(\'${resourceGroup().name}\')}/providers/@{encodeURIComponent(\'Microsoft.Logic\')}/@{encodeURIComponent(\'workflows/${seedLogicAppName}\')}/@{encodeURIComponent(\'disable\')}'
              queries: {
                  'x-ms-api-version': '2016-06-01'
              }
          }
          runAfter: {
              SqlQuery: [
                  'Succeeded'
              ]
          }
          type: 'ApiConnection'
        }
      }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sqlAdminIdentity.id}': {} 
    }
  }
  dependsOn: [
    sqlDB
  ]
}

resource logicAppOperatorRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: logicAppOperatorRoleId
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  scope: logicAppSeed
  name: guid(logicAppSeed.id, sqlAdminIdentity.id, logicAppOperatorRoleId)
  properties: {
    roleDefinitionId: logicAppOperatorRoleDefinition.id
    principalId: sqlAdminIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Replaced with seed logic app
/*
resource sqlDeploymentScript 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: uniqueName
  location: location
  kind: 'AzurePowerShell'
  properties: {
    azPowerShellVersion: 'az7.4'
    retentionInterval: 'P1D'
    timeout: 'PT5M'
    cleanupPreference: 'Always'
    scriptContent: sqlScript
    environmentVariables: [
      {
        name: 'SQL_SERVER'
        value: sqlServer.properties.fullyQualifiedDomainName
      }
      {
        name: 'SQL_DB'
        value: databaseName
      }
      {
        name: 'SQL_TENANTID'
        value: sqlAdminIdentity.properties.tenantId
      }
      {
        name: 'SQL_CLIENTID'
        value: sqlAdminIdentity.properties.clientId
      }
    ]
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sqlAdminIdentity.id}': {} 
    }
  }
}
*/
