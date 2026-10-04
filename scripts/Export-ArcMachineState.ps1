<#
.SYNOPSIS
    Captures everything hanging off an Azure Arc-enabled server resource before you disconnect it.

.DESCRIPTION
    Run this BEFORE azcmagent disconnect. Once the resource is deleted, none of this can be queried.
    Captures: resource metadata, tags, managed identity principal ID, role assignments held by that
    identity, installed extensions (public settings only), and Data Collection Rule associations.

.EXAMPLE
    .\Export-ArcMachineState.ps1 -MachineName oldbox02 -ResourceGroupName rg-arc-prod -OutputPath .\oldbox02-state.json

.NOTES
    Requires Az.Accounts, Az.ConnectedMachine, Az.Resources. Protected extension settings are never
    returned by the API, so anything that lives there (workspace keys, credentials) has to be re-supplied.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $MachineName,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [string] $SubscriptionId,
    [string] $OutputPath = ".\$MachineName-arc-state.json"
)

$ErrorActionPreference = 'Stop'

if ($SubscriptionId) { $null = Set-AzContext -SubscriptionId $SubscriptionId }
$ctx = Get-AzContext
Write-Host "Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"

Write-Host "Reading machine resource $MachineName in $ResourceGroupName..."
$machine = Get-AzConnectedMachine -Name $MachineName -ResourceGroupName $ResourceGroupName

$principalId = $machine.IdentityPrincipalId
if (-not $principalId) { $principalId = $machine.Identity.PrincipalId }

Write-Host "Managed identity principal: $principalId"

# Role assignments held by the machine's managed identity, at any scope
$roleAssignments = @()
if ($principalId) {
    $roleAssignments = Get-AzRoleAssignment -ObjectId $principalId | ForEach-Object {
        [pscustomobject]@{
            RoleDefinitionName = $_.RoleDefinitionName
            RoleDefinitionId   = $_.RoleDefinitionId
            Scope              = $_.Scope
        }
    }
}
Write-Host "Role assignments found: $($roleAssignments.Count)"

# Extensions. Protected settings are write-only and will not be present.
$extensions = Get-AzConnectedMachineExtension -MachineName $MachineName -ResourceGroupName $ResourceGroupName |
    ForEach-Object {
        [pscustomobject]@{
            Name                    = $_.Name
            Publisher               = $_.Publisher
            ExtensionType           = $_.MachineExtensionType
            TypeHandlerVersion      = $_.TypeHandlerVersion
            AutoUpgradeMinorVersion = $_.AutoUpgradeMinorVersion
            EnableAutomaticUpgrade  = $_.EnableAutomaticUpgrade
            Settings                = $_.Setting
        }
    }
Write-Host "Extensions found: $($extensions.Count)"

# DCR associations via REST so this works across Az.Monitor versions
$dcrApi = '2022-06-01'
$dcrUri = "$($machine.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=$dcrApi"
$dcrResp = Invoke-AzRestMethod -Method GET -Path $dcrUri
$dcrAssociations = @()
if ($dcrResp.StatusCode -eq 200) {
    $dcrAssociations = ($dcrResp.Content | ConvertFrom-Json).value | ForEach-Object {
        [pscustomobject]@{
            Name                     = $_.name
            DataCollectionRuleId     = $_.properties.dataCollectionRuleId
            DataCollectionEndpointId = $_.properties.dataCollectionEndpointId
            Description              = $_.properties.description
        }
    }
}
Write-Host "DCR associations found: $($dcrAssociations.Count)"

$state = [pscustomobject]@{
    CapturedAt        = (Get-Date).ToUniversalTime().ToString('o')
    SubscriptionId    = $ctx.Subscription.Id
    ResourceGroupName = $ResourceGroupName
    MachineName       = $MachineName
    ResourceId        = $machine.Id
    Location          = $machine.Location
    OSName            = $machine.OSName
    AgentVersion      = $machine.AgentVersion
    Tags              = $machine.Tag
    PrincipalId       = $principalId
    RoleAssignments   = @($roleAssignments)
    Extensions        = @($extensions)
    DcrAssociations   = @($dcrAssociations)
}

$state | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "State written to $OutputPath"
Write-Host ""
Write-Host "Safe to run 'azcmagent disconnect' on the server now."
