$tenant = ${Env:SQL_TENANTID}
$clientId = ${Env:SQL_CLIENTID}
$sqlServer = ${Env:SQL_SERVER}
$sqlDB = ${Env:SQL_DB}
$query = @"
"@

Connect-AzAccount -Identity -AccountId $clientId -Tenant $tenant -Force -ErrorAction Stop
$token = Get-AzAccessToken -ResourceUrl "https://database.windows.net/" -ErrorAction Stop
Invoke-SqlCmd -ServerInstance $sqlServer -Database $sqlDB -AccessToken $token -Query $query -ErrorAction Stop