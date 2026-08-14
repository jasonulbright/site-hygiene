@{
    RootModule        = 'SiteHygieneCommon.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'e94b7c15-2f6a-4d38-8b0c-51a9d3e6f284'
    Author            = 'Jason Ulbright'
    Description       = 'Read-only MECM site hygiene scanning: unused applications and packages, dead collections, stale and failing deployments.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        # Logging and CM connection come from the vendored SuiteCommon
        # module (Lib\SuiteCommon), imported globally by the root module.

        # Catalog / configuration
        'Get-HygieneCheckCatalog'
        'Get-HygieneDefaultThresholds'
        'New-HygieneFinding'

        # Data
        'Get-HygieneData'

        # Checks
        'Test-HygAppNoReferences'
        'Test-HygAppRetiredDeployed'
        'Test-HygAppSupersededDeployed'
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
        'Test-HygUpdateChecks'
        'Test-HygMaintenanceTasks'

        # Relationships (absorbed from the supersedence-auditor tool)
        'ConvertTo-HygRelationships'
        'Get-HygieneRelationshipData'
        'Find-HygCircularEdges'
        'Test-HygRelationshipChecks'
        'Test-HygAppContentPath'
        'Build-HygRelationshipTree'

        # Orchestration
        'Invoke-HygieneScan'
        'Get-HygieneScanSummary'
        'Get-HygieneSuppressionKey'

        # Export
        'Export-HygieneCsv'
        'Export-HygieneHtml'
        'New-HygieneSummaryText'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
