@{
    RootModule        = 'SiteHygieneCommon.psm1'
    NestedModules     = @('SiteHygieneLive.psm1')
    ModuleVersion     = '2026.09.25.0020'
    GUID              = 'e94b7c15-2f6a-4d38-8b0c-51a9d3e6f284'
    Author            = 'Jason Ulbright'
    Description       = 'Configuration Manager site hygiene: read-only scanning for unused applications and packages, dead collections, stale and failing deployments, and application relationships, with confirmed per-finding fix execution and live site health views.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        # Logging and CM connection come from the vendored SuiteCommon
        # module (Lib\SuiteCommon), imported globally by the root module.

        # Catalog / configuration
        'Get-HygieneCheckCatalog'
        'Get-HygieneDefaultThresholds'
        'New-HygieneFinding'

        # Data
        'Get-HygieneScanScope'
        'Get-HygieneRequiredDataset'
        'Get-HygieneData'

        # Checks
        'Test-HygAppNoReferences'
        'Test-HygAppRetiredDeployed'
        'Test-HygAppSupersededDeployed'
        'Test-HygAppOldRevisions'
        'Test-HygPackageUnused'
        'Test-HygCollectionEmptyUnused'
        'Test-HygDeploymentEmptyCollection'
        'Test-HygIncrementalCeiling'
        'Test-HygDeploymentExpired'
        'Test-HygDeploymentPastDeadlineFailures'
        'Test-HygDeploymentAvailableUnused'
        'Test-HygDeviceInactive'
        'Test-HygDeviceDuplicates'
        'Test-HygClientVersions'
        'Test-HygBoundaryChecks'
        'Test-HygTaskSequenceRefs'
        'Test-HygTaskSequenceApplications'
        'Test-HygUpdateGroupChecks'
        'Test-HygAdrChecks'
        'Test-HygMaintenanceTasks'
        'Test-HygContentDistribution'
        'Test-HygCollectionEvaluationRunTime'
        'Test-HygDeploymentBroadRequired'
        'Test-HygDeployedDisabledObject'
        'Test-HygUpdateGroupSize'
        'Test-HygUpdatePackageExpiredContent'
        'Test-HygDistributionPointChecks'
        'Test-HygComplianceChecks'
        'Test-HygDriverUnpackaged'
        'Test-HygAdminDeletedAccount'
        'Test-HygMaintenanceWindowExpired'

        # Relationships (absorbed from the supersedence-auditor tool)
        'ConvertTo-HygRelationships'
        'Get-HygieneRelationshipData'
        'Find-HygCircularEdges'
        'Test-HygRelationshipChecks'
        'Test-HygAppContentPath'
        'Build-HygRelationshipTree'
        'Get-HygRelationshipInventory'

        # Orchestration
        'Invoke-HygieneScan'
        'Get-HygieneScanSummary'
        'Get-HygieneSuppressionKey'

        # Export
        'Export-HygieneCsv'
        'Export-HygieneHtml'
        'New-HygieneSummaryText'

        # Fix execution
        'Test-HygieneFixExecutable'
        'Invoke-HygieneFix'

        # Collection evaluation deep-dive
        'Get-HygCollectionReferenceGraph'
        'Test-HygCollectionEvaluationChecks'

        # Rescan deltas
        'Save-HygieneScanResult'
        'Read-HygieneScanResult'
        'Get-HygieneScanDelta'
        # Live area (SiteHygieneLive.psm1)
        'Test-SQLConnection'
        'Get-DeploymentHealth'
        'Get-DeploymentDetails'
        'Get-DeploymentHealthCounts'
        'Get-ContentDistributionHealth'
        'Get-ContentHealthCounts'
        'Get-ContentNameMap'
        'Get-DPHealth'
        'Get-DPDetails'
        'Get-DPHealthCounts'
        'Get-ClientHealthSummary'
        'Get-ClientHealthCounts'
        'Get-InactiveDevices'
        'Get-InactiveDeviceCounts'
        'Get-SiteComponentHealth'
        'Get-SiteSystemHealth'
        'Get-SiteHealthCounts'
        'Add-MetricsHistoryEntry'
        'Get-MetricsHistory'
        'Export-HygieneTableCsv'
        'Export-HygieneTableHtml'
        'New-HygieneLiveSummaryText'
        'Import-HygieneLegacyDashboardState'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
