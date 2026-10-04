<#
.SYNOPSIS
    Rebuilds tags, role assignments, extensions, and DCR associations on a freshly reconnected Arc-enabled server.

.DESCRIPTION
    Run this AFTER the OS rename and after azcmagent connect has created the new resource.
    Reads the JSON produced by Export-ArcMachineState.ps1 and reapplies it to the new resource name.
    The new managed identity will have a different principal ID; role assignments are recreated against
    the new one. Extensions are redeployed with their public settings only. Use -ProtectedSettings to
    supply anything that lived in protected settings, keyed by extension name.

.EXAMPLE
    .\Restore-ArcMachineState.ps1 -StatePath .\oldbox02-arc-state.json -NewMachineName APP-PRD-07

.EXAMPLE
    .\Restore-ArcMachineState.ps1 -StatePath .\oldbox02-arc-state.json -NewMachineName APP-PRD-07 -SkipExtensions -WhatIf

.NOTES
    Requires Az.Accounts, Az.ConnectedMachine, Az.Resources. Supports -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $NewMachineName,
    [string] $ResourceGroupName,
    [hashtable] $ProtectedSettings = @{},
    [switch] $SkipTags,
    [switch] $SkipRoleAssignments,
    [switch] $SkipExtensions,
    [switch] $SkipDcrAssociations,
    [int] $IdentityWaitSeconds = 120
)

$ErrorActionPreference = 'Stop'

$state = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
if (-not $ResourceGroupName) { $ResourceGroupName = $state.ResourceGroupName }

$null = Set-AzContext -SubscriptionId $state.SubscriptionId
Write-Host "Restoring state from $($state.MachineName) onto $NewMachineName in $ResourceGroupName"

$machine = Get-AzConnectedMachine -Name $NewMachineName -ResourceGroupName $ResourceGroupName
$newPrincipalId = $machine.IdentityPrincipalId
if (-not $newPrincipalId) { $newPrincipalId = $machine.Identity.PrincipalId }
Write-Host "New resource ID: $($machine.Id)"
Write-Host "New managed identity principal: $newPrincipalId"

# ---- Tags ---------------------------------------------------------------
if (-not $SkipTags -and $state.Tags) {
    $tags = @{}
    $state.Tags.PSObject.Properties | ForEach-Object { $tags[$_.Name] = $_.Value }
    if ($tags.Count -gt 0 -and $PSCmdlet.ShouldProcess($NewMachineName, "Apply $($tags.Count) tag(s)")) {
        $null = Update-AzConnectedMachine -Name $NewMachineName -ResourceGroupName $ResourceGroupName -Tag $tags
        Write-Host "Tags applied."
    }
}

# ---- Role assignments ----------------------------------------------------
if (-not $SkipRoleAssignments -and $state.RoleAssignments.Count -gt 0) {
    if (-not $newPrincipalId) {
        Write-Warning "New resource has no managed identity yet. Skipping role assignments."
    } else {
        # Entra ID replication lag is real. Give the new identity time to exist everywhere.
        Write-Host "Waiting up to $IdentityWaitSeconds seconds for the new identity to replicate..."
        $deadline = (Get-Date).AddSeconds($IdentityWaitSeconds)
        do {
            $sp = Get-AzADServicePrincipal -ObjectId $newPrincipalId -ErrorAction SilentlyContinue
            if (-not $sp) { Start-Sleep -Seconds 10 }
        } while (-not $sp -and (Get-Date) -lt $deadline)
        if (-not $sp) { Write-Warning "Identity still not visible in Entra ID. Assignments may fail; rerun with -SkipExtensions -SkipTags later." }

        foreach ($ra in $state.RoleAssignments) {
            $desc = "$($ra.RoleDefinitionName) at $($ra.Scope)"
            if ($PSCmdlet.ShouldProcess($newPrincipalId, "Assign $desc")) {
                $existing = Get-AzRoleAssignment -ObjectId $newPrincipalId -RoleDefinitionId $ra.RoleDefinitionId -Scope $ra.Scope -ErrorAction SilentlyContinue
                if ($existing) { Write-Host "Already present: $desc"; continue }
                $attempt = 0
                do {
                    try {
                        $null = New-AzRoleAssignment -ObjectId $newPrincipalId -RoleDefinitionId $ra.RoleDefinitionId -Scope $ra.Scope -ObjectType ServicePrincipal
                        Write-Host "Assigned: $desc"
                        break
                    } catch {
                        $attempt++
                        if ($attempt -ge 3) { Write-Warning "Failed after 3 attempts: $desc. $($_.Exception.Message)"; break }
                        Start-Sleep -Seconds (10 * $attempt)
                    }
                } while ($true)
            }
        }
    }
}

# ---- Extensions ----------------------------------------------------------
if (-not $SkipExtensions -and $state.Extensions.Count -gt 0) {
    foreach ($ext in $state.Extensions) {
        if ($PSCmdlet.ShouldProcess($NewMachineName, "Deploy extension $($ext.Name) ($($ext.Publisher)/$($ext.ExtensionType))")) {
            $params = @{
                Name                   = $ext.Name
                ResourceGroupName      = $ResourceGroupName
                MachineName            = $NewMachineName
                Location               = $machine.Location
                Publisher              = $ext.Publisher
                ExtensionType          = $ext.ExtensionType
                EnableAutomaticUpgrade = [bool]$ext.EnableAutomaticUpgrade
                NoWait                 = $true
            }
            if ($ext.TypeHandlerVersion -and -not $ext.EnableAutomaticUpgrade) { $params.TypeHandlerVersion = $ext.TypeHandlerVersion }
            if ($ext.Settings) {
                $settings = @{}
                $ext.Settings.PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value }
                if ($settings.Count -gt 0) { $params.Setting = $settings }
            }
            if ($ProtectedSettings.ContainsKey($ext.Name)) { $params.ProtectedSetting = $ProtectedSettings[$ext.Name] }
            try {
                $null = New-AzConnectedMachineExtension @params
                Write-Host "Deployment started: $($ext.Name)"
            } catch {
                Write-Warning "Extension $($ext.Name) failed: $($_.Exception.Message)"
            }
        }
    }
    Write-Host "Extensions are deploying asynchronously. Check status with Get-AzConnectedMachineExtension."
}

# ---- DCR associations ----------------------------------------------------
if (-not $SkipDcrAssociations -and $state.DcrAssociations.Count -gt 0) {
    $dcrApi = '2022-06-01'
    foreach ($dcra in $state.DcrAssociations) {
        if ($PSCmdlet.ShouldProcess($NewMachineName, "Associate DCR $($dcra.Name)")) {
            $props = @{}
            if ($dcra.DataCollectionRuleId)     { $props.dataCollectionRuleId = $dcra.DataCollectionRuleId }
            if ($dcra.DataCollectionEndpointId) { $props.dataCollectionEndpointId = $dcra.DataCollectionEndpointId }
            if ($dcra.Description)              { $props.description = $dcra.Description }
            $body = @{ properties = $props } | ConvertTo-Json -Depth 5
            $uri = "$($machine.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($dcra.Name)?api-version=$dcrApi"
            $resp = Invoke-AzRestMethod -Method PUT -Path $uri -Payload $body
            if ($resp.StatusCode -in 200, 201) { Write-Host "Associated: $($dcra.Name)" }
            else { Write-Warning "DCR association $($dcra.Name) returned $($resp.StatusCode): $($resp.Content)" }
        }
    }
}

Write-Host ""
Write-Host "Restore complete. Verify with:"
Write-Host "  azcmagent show                                   (on the server)"
Write-Host "  Get-AzConnectedMachineExtension -MachineName $NewMachineName -ResourceGroupName $ResourceGroupName"
Write-Host "  Get-AzRoleAssignment -ObjectId $newPrincipalId"
