<#
.SYNOPSIS
    Core module for Site Hygiene.

.DESCRIPTION
    Import this module to get:
      - Structured logging and CM site connection management via the
        vendored SuiteCommon module (Lib\SuiteCommon)
      - One-pass site data prefetch (Get-HygieneData)
      - Pure hygiene checks over the prefetched data (Test-Hyg*)
      - Scan orchestration (Invoke-HygieneScan)
      - Findings export to CSV, HTML, and plain-text summary

    A scan is read-only: the prefetch uses Get-CM* cmdlets plus two CIM
    reads and never mutates the site. Every finding carries the evidence
    that produced it, a recommendation, and the PowerShell a fix would
    run - the script is displayed, never executed, by this module.

.EXAMPLE
    Import-Module "$PSScriptRoot\Module\SiteHygieneCommon.psd1" -Force
    Initialize-Logging -LogPath "C:\temp\hygiene.log"
    Connect-CMSite -SiteCode 'MCM' -SMSProvider 'cm01.contoso.com'
    $data     = Get-HygieneData
    $findings = Invoke-HygieneScan -Data $data
#>

# ---------------------------------------------------------------------------
# Shared core (vendored SuiteCommon)
# ---------------------------------------------------------------------------
if (-not (Get-Module SuiteCommon)) {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\SuiteCommon\SuiteCommon.psd1') -Global -DisableNameChecking
}

# ---------------------------------------------------------------------------
# Check catalog
# ---------------------------------------------------------------------------

function Get-HygieneCheckCatalog {
    <#
    .SYNOPSIS
        Returns the implemented check catalog: Id, Category, Severity,
        Title. Stable IDs come from the project register.
    #>
    return @(
        [pscustomobject]@{ Id = 'APP-01'; Category = 'Applications'; Severity = 'Warning'; Title = 'Application with no deployments or references' }
        [pscustomobject]@{ Id = 'APP-02'; Category = 'Applications'; Severity = 'Error';   Title = 'Retired application still deployed' }
        [pscustomobject]@{ Id = 'APP-03'; Category = 'Applications'; Severity = 'Warning'; Title = 'Superseded application still deployed' }
        [pscustomobject]@{ Id = 'APP-04'; Category = 'Applications'; Severity = 'Warning'; Title = 'Deployment type content source missing or unreachable' }
        [pscustomobject]@{ Id = 'PKG-01'; Category = 'Packages';     Severity = 'Warning'; Title = 'Package with no programs and no references' }
        [pscustomobject]@{ Id = 'SUP-01'; Category = 'Relationships'; Severity = 'Error';   Title = 'Supersedence referencing a deleted application' }
        [pscustomobject]@{ Id = 'SUP-02'; Category = 'Relationships'; Severity = 'Error';   Title = 'Circular supersedence chain' }
        [pscustomobject]@{ Id = 'SUP-03'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Superseding application disabled' }
        [pscustomobject]@{ Id = 'SUP-04'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Supersedence target retired or expired' }
        [pscustomobject]@{ Id = 'DEP-01'; Category = 'Relationships'; Severity = 'Error';   Title = 'Dependency referencing a deleted application' }
        [pscustomobject]@{ Id = 'DEP-02'; Category = 'Relationships'; Severity = 'Error';   Title = 'Circular dependency' }
        [pscustomobject]@{ Id = 'DEP-03'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Dependency target disabled' }
        [pscustomobject]@{ Id = 'DEP-04'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Dependency target retired or expired' }
        [pscustomobject]@{ Id = 'DEP-05'; Category = 'Relationships'; Severity = 'Error';   Title = 'Dependency target with no distributed content' }
        [pscustomobject]@{ Id = 'REL-01'; Category = 'Relationships'; Severity = 'Info';    Title = 'Application relationships without manufacturer metadata' }
        [pscustomobject]@{ Id = 'COL-01'; Category = 'Collections';  Severity = 'Info';    Title = 'Empty collection nothing references' }
        [pscustomobject]@{ Id = 'COL-02'; Category = 'Collections';  Severity = 'Warning'; Title = 'Deployment targeting an empty collection' }
        [pscustomobject]@{ Id = 'COL-03'; Category = 'Collections';  Severity = 'Warning'; Title = 'Incremental-evaluation collection count over ceiling' }
        [pscustomobject]@{ Id = 'DPL-01'; Category = 'Deployments';  Severity = 'Info';    Title = 'Deployment past its expiration time' }
        [pscustomobject]@{ Id = 'DPL-02'; Category = 'Deployments';  Severity = 'Error';   Title = 'Required deployment past deadline with high failures' }
        [pscustomobject]@{ Id = 'DPL-03'; Category = 'Deployments';  Severity = 'Info';    Title = 'Available deployment with no takers' }
    )
}

function Get-HygieneDefaultThresholds {
    <#
    .SYNOPSIS
        Default tunables for the checks that take one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full thresholds hashtable by design.')]
    param()
    return @{
        AppUnusedMinAgeDays       = 30
        IncrementalCeiling        = 200
        DeadlineGraceDays         = 7
        FailurePctThreshold       = 20
        AvailableUnusedMinAgeDays = 30
    }
}

function New-HygieneFinding {
    <#
    .SYNOPSIS
        Uniform finding object every check returns.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Constructs an in-memory finding object; changes no system state.')]
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][ValidateSet('Error', 'Warning', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$ObjectType,
        [AllowEmptyString()][string]$ObjectId = '',
        [Parameter(Mandatory)][string]$ObjectName,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$Recommendation,
        [AllowEmptyString()][string]$FixScript = ''
    )

    return [pscustomobject]@{
        CheckId        = $CheckId
        Severity       = $Severity
        Category       = $Category
        ObjectType     = $ObjectType
        ObjectId       = $ObjectId
        ObjectName     = $ObjectName
        Evidence       = $Evidence
        Recommendation = $Recommendation
        FixScript      = $FixScript
    }
}

# ---------------------------------------------------------------------------
# Data prefetch (the only CM-touching part of a scan)
# ---------------------------------------------------------------------------

function Get-HygieneData {
    <#
    .SYNOPSIS
        Pulls every dataset the checks need in one pass.

    .DESCRIPTION
        Bulk cmdlet reads plus two CIM queries; each dataset degrades to an
        empty set on failure with a note in DatasetNotes so one missing
        class or right never kills the whole scan. Requires an established
        CM connection (Connect-CMSite) because the CIM queries read the
        provider recorded by Get-CMConnectionInfo.
    #>
    param()

    $notes = New-Object System.Collections.Generic.List[string]

    $apps = @()
    try {
        $apps = @(Get-CMApplication -Fast -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                CI_ID         = [int]$_.CI_ID
                ModelName     = [string]$_.ModelName
                Name          = [string]$_.LocalizedDisplayName
                IsDeployed    = [bool]$_.IsDeployed
                IsExpired     = [bool]$_.IsExpired
                IsSuperseded  = [bool]$_.IsSuperseded
                IsSuperseding = [bool]$_.IsSuperseding
                PackageID     = [string]$_.PackageID
                DateCreated   = $_.DateCreated
            }
        })
        Write-Log "Loaded $($apps.Count) applications"
    } catch { $notes.Add("Applications unavailable: $($_.Exception.Message)"); Write-Log "Applications unavailable: $($_.Exception.Message)" -Level WARN }

    $packages = @()
    try {
        $packages = @(Get-CMPackage -Fast -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
        })
        Write-Log "Loaded $($packages.Count) packages"
    } catch { $notes.Add("Packages unavailable: $($_.Exception.Message)"); Write-Log "Packages unavailable: $($_.Exception.Message)" -Level WARN }

    $programs = @()
    try {
        $programs = @(Get-CMProgram -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ PackageID = [string]$_.PackageID; ProgramName = [string]$_.ProgramName }
        })
        Write-Log "Loaded $($programs.Count) programs"
    } catch { $notes.Add("Programs unavailable: $($_.Exception.Message)"); Write-Log "Programs unavailable: $($_.Exception.Message)" -Level WARN }

    $taskSequences = @()
    try {
        $taskSequences = @(Get-CMTaskSequence -ErrorAction Stop | ForEach-Object {
            $refs = @()
            if ($_.References) { $refs = @($_.References | ForEach-Object { [string]$_.Package }) }
            [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name; ReferencedIDs = $refs }
        })
        Write-Log "Loaded $($taskSequences.Count) task sequences"
    } catch { $notes.Add("Task sequences unavailable: $($_.Exception.Message)"); Write-Log "Task sequences unavailable: $($_.Exception.Message)" -Level WARN }

    $collections = @()
    try {
        $collections = @(Get-CMCollection -ErrorAction Stop | ForEach-Object {
            $includeIds = @()
            $excludeIds = @()
            if ($_.CollectionRules) {
                foreach ($rule in $_.CollectionRules) {
                    # Embedded rule objects frequently carry an empty
                    # SmsProviderObjectPath; the .NET type name is the
                    # reliable discriminator. Without the fallback no rule
                    # ever classifies and COL-01 flags collections that
                    # include/exclude rules still reference.
                    $typeName = $null
                    try { $typeName = [string]$rule.SmsProviderObjectPath } catch { $typeName = $null }
                    if (-not $typeName) { try { $typeName = $rule.GetType().Name } catch { continue } }
                    if ($typeName -match 'IncludeCollection') { $includeIds += [string]$rule.IncludeCollectionID }
                    elseif ($typeName -match 'ExcludeCollection') { $excludeIds += [string]$rule.ExcludeCollectionID }
                }
            }
            [pscustomobject]@{
                CollectionID        = [string]$_.CollectionID
                Name                = [string]$_.Name
                MemberCount         = [int]$_.MemberCount
                RefreshType         = [int]$_.RefreshType
                LimitToCollectionID = [string]$_.LimitToCollectionID
                IsBuiltIn           = ([string]$_.CollectionID -like 'SMS*')
                IncludeIDs          = $includeIds
                ExcludeIDs          = $excludeIds
            }
        })
        Write-Log "Loaded $($collections.Count) collections"
    } catch { $notes.Add("Collections unavailable: $($_.Exception.Message)"); Write-Log "Collections unavailable: $($_.Exception.Message)" -Level WARN }

    $deployments = @()
    try {
        $deployments = @(Get-CMDeployment -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                SoftwareName        = [string]$_.SoftwareName
                PackageID           = [string]$_.PackageID
                CollectionID        = [string]$_.CollectionID
                CollectionName      = [string]$_.CollectionName
                DeploymentIntent    = [int]$_.DeploymentIntent
                FeatureType         = [int]$_.FeatureType
                NumberTargeted      = [int]$_.NumberTargeted
                NumberSuccess       = [int]$_.NumberSuccess
                NumberInProgress    = [int]$_.NumberInProgress
                NumberErrors        = [int]$_.NumberErrors
                EnforcementDeadline = $_.EnforcementDeadline
                CreationTime        = $_.CreationTime
            }
        })
        Write-Log "Loaded $($deployments.Count) deployment summaries"
    } catch { $notes.Add("Deployment summaries unavailable: $($_.Exception.Message)"); Write-Log "Deployment summaries unavailable: $($_.Exception.Message)" -Level WARN }

    $appDeployments = @()
    try {
        $appDeployments = @(Get-CMApplicationDeployment -ErrorAction Stop | ForEach-Object {
            $expEnabled = $false
            $expTime = $null
            $p = $_.PSObject.Properties['ExpirationTimeEnabled']
            if ($p) { $expEnabled = [bool]$p.Value }
            $p = $_.PSObject.Properties['ExpirationTime']
            if ($p) { $expTime = $p.Value }
            [pscustomobject]@{
                ApplicationName       = [string]$_.ApplicationName
                CollectionName        = [string]$_.CollectionName
                TargetCollectionID    = [string]$_.TargetCollectionID
                ExpirationTimeEnabled = $expEnabled
                ExpirationTime        = $expTime
            }
        })
        Write-Log "Loaded $($appDeployments.Count) application deployments"
    } catch { $notes.Add("Application deployments unavailable: $($_.Exception.Message)"); Write-Log "Application deployments unavailable: $($_.Exception.Message)" -Level WARN }

    $conn = Get-CMConnectionInfo
    $collectionsWithSettings = @()
    $dependencyTargetCIIDs = @()

    if ($conn) {
        $ns = "root\SMS\site_$($conn.SiteCode)"

        # Collections that carry variables/settings live in
        # SMS_CollectionSettings; one query beats N per-collection cmdlet
        # round-trips.
        try {
            $collectionsWithSettings = @(
                Get-CimInstance -ComputerName $conn.SMSProvider -Namespace $ns `
                    -Query 'SELECT CollectionID FROM SMS_CollectionSettings' -ErrorAction Stop |
                ForEach-Object { [string]$_.CollectionID }
            )
            Write-Log "Loaded $($collectionsWithSettings.Count) collection-settings rows"
        } catch { $notes.Add("Collection settings unavailable (COL-01 cannot rule out variables): $($_.Exception.Message)"); Write-Log "Collection settings unavailable: $($_.Exception.Message)" -Level WARN }

        try {
            $dependencyTargetCIIDs = @(
                Get-CimInstance -ComputerName $conn.SMSProvider -Namespace $ns `
                    -Query 'SELECT ToApplicationCIID FROM SMS_AppDependenceRelation' -ErrorAction Stop |
                ForEach-Object { [int]$_.ToApplicationCIID }
            )
            Write-Log "Loaded $($dependencyTargetCIIDs.Count) dependency relations"
        } catch { $notes.Add("Dependency relations unavailable (APP-01 may over-report dependency-only applications): $($_.Exception.Message)"); Write-Log "Dependency relations unavailable: $($_.Exception.Message)" -Level WARN }
    }
    else {
        $notes.Add('No CM connection recorded; CIM datasets (collection settings, dependency relations) skipped.')
    }

    return [pscustomobject]@{
        Applications            = $apps
        Packages                = $packages
        Programs                = $programs
        TaskSequences           = $taskSequences
        Collections             = $collections
        Deployments             = $deployments
        AppDeployments          = $appDeployments
        CollectionsWithSettings = $collectionsWithSettings
        DependencyTargetCIIDs   = $dependencyTargetCIIDs
        DatasetNotes            = $notes.ToArray()
        CollectedAt             = Get-Date
    }
}

# ---------------------------------------------------------------------------
# Checks: Applications
# ---------------------------------------------------------------------------

function Test-HygAppNoReferences {
    <#
    .SYNOPSIS
        APP-01: applications with no deployments, no task sequence
        references, no supersedence role, and no dependency targeting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the reference-absence condition it tests.')]
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $tsRefs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ts in @($Data.TaskSequences)) {
        foreach ($r in @($ts.ReferencedIDs)) { [void]$tsRefs.Add([string]$r) }
    }
    $depTargets = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($id in @($Data.DependencyTargetCIIDs)) { [void]$depTargets.Add([int]$id) }

    $minAge = [int]$Thresholds.AppUnusedMinAgeDays
    $cutoff = (Get-Date).AddDays(-$minAge)

    foreach ($app in @($Data.Applications)) {
        if ($app.IsDeployed -or $app.IsSuperseding -or $app.IsSuperseded) { continue }
        if ($depTargets.Contains([int]$app.CI_ID)) { continue }
        if ($app.PackageID -and $tsRefs.Contains([string]$app.PackageID)) { continue }
        if ($app.ModelName -and $tsRefs.Contains([string]$app.ModelName)) { continue }
        if ($app.DateCreated -and $app.DateCreated -gt $cutoff) { continue }

        New-HygieneFinding -CheckId 'APP-01' -Severity Warning -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
            -Evidence ("No deployments, no task sequence references, not part of any supersedence relationship, not a dependency target; created {0}, older than the {1}-day grace window." -f $app.DateCreated, $minAge) `
            -Recommendation 'Candidate for retirement and removal. Verify no out-of-band use (scripts, documentation) before deleting.' `
            -FixScript ("Remove-CMApplication -Name '{0}' -Force" -f ($app.Name -replace "'", "''"))
    }
}

function Test-HygAppRetiredDeployed {
    <#
    .SYNOPSIS
        APP-02: retired (expired) applications that still have deployments.
    #>
    param([Parameter(Mandatory)]$Data)

    foreach ($app in @($Data.Applications)) {
        if (-not ($app.IsExpired -and $app.IsDeployed)) { continue }

        New-HygieneFinding -CheckId 'APP-02' -Severity Error -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
            -Evidence 'Application is retired (expired) but still has active deployments; clients targeted by them cannot install it.' `
            -Recommendation 'Remove the deployments, or reinstate the application if retiring it was a mistake.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' | Remove-CMApplicationDeployment -Force" -f ($app.Name -replace "'", "''"))
    }
}

function Test-HygAppSupersededDeployed {
    <#
    .SYNOPSIS
        APP-03: superseded applications still deployed.
    #>
    param([Parameter(Mandatory)]$Data)

    foreach ($app in @($Data.Applications)) {
        if (-not ($app.IsSuperseded -and $app.IsDeployed)) { continue }
        if ($app.IsExpired) { continue }  # APP-02 already carries the louder finding

        New-HygieneFinding -CheckId 'APP-03' -Severity Warning -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
            -Evidence 'Application is superseded by a newer application but its own deployments are still active.' `
            -Recommendation 'Deploy the superseding application and retire these deployments so clients converge on the replacement.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' | Remove-CMApplicationDeployment -Force" -f ($app.Name -replace "'", "''"))
    }
}

# ---------------------------------------------------------------------------
# Checks: Packages
# ---------------------------------------------------------------------------

function Test-HygPackageUnused {
    <#
    .SYNOPSIS
        PKG-01: legacy packages with no programs, no deployments, and no
        task sequence references.
    #>
    param([Parameter(Mandatory)]$Data)

    $withPrograms = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Data.Programs)) { [void]$withPrograms.Add([string]$p.PackageID) }

    $deployed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($Data.Deployments)) { if ($d.PackageID) { [void]$deployed.Add([string]$d.PackageID) } }

    $tsRefs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ts in @($Data.TaskSequences)) {
        foreach ($r in @($ts.ReferencedIDs)) { [void]$tsRefs.Add([string]$r) }
    }

    foreach ($pkg in @($Data.Packages)) {
        # Default client packages ship without programs and would always
        # flag; they are site plumbing, not clutter.
        if ($pkg.Name -match '^Configuration Manager Client') { continue }
        $id = [string]$pkg.PackageID
        if ($withPrograms.Contains($id)) { continue }
        if ($deployed.Contains($id)) { continue }
        if ($tsRefs.Contains($id)) { continue }

        New-HygieneFinding -CheckId 'PKG-01' -Severity Warning -Category 'Packages' `
            -ObjectType 'Package' -ObjectId $id -ObjectName $pkg.Name `
            -Evidence 'Package has no programs, no deployments, and no task sequence references.' `
            -Recommendation 'Candidate for deletion; its content still occupies distribution points and the content library.' `
            -FixScript ("Remove-CMPackage -Id '{0}' -Force" -f $id)
    }
}

# ---------------------------------------------------------------------------
# Checks: Collections
# ---------------------------------------------------------------------------

function Test-HygCollectionEmptyUnused {
    <#
    .SYNOPSIS
        COL-01: empty collections that nothing references - no deployments,
        no include/exclude rule from another collection, not anyone's
        limiting collection, no collection variables/settings.
    #>
    param([Parameter(Mandatory)]$Data)

    $deploymentTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($Data.Deployments)) { if ($d.CollectionID) { [void]$deploymentTargets.Add([string]$d.CollectionID) } }

    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in @($Data.Collections)) {
        foreach ($id in @($c.IncludeIDs)) { [void]$referenced.Add([string]$id) }
        foreach ($id in @($c.ExcludeIDs)) { [void]$referenced.Add([string]$id) }
        if ($c.LimitToCollectionID) { [void]$referenced.Add([string]$c.LimitToCollectionID) }
    }

    $withSettings = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Data.CollectionsWithSettings)) { [void]$withSettings.Add([string]$id) }

    foreach ($c in @($Data.Collections)) {
        if ($c.IsBuiltIn) { continue }
        if ($c.MemberCount -ne 0) { continue }
        $id = [string]$c.CollectionID
        if ($deploymentTargets.Contains($id)) { continue }
        if ($referenced.Contains($id)) { continue }
        if ($withSettings.Contains($id)) { continue }

        New-HygieneFinding -CheckId 'COL-01' -Severity Info -Category 'Collections' `
            -ObjectType 'Collection' -ObjectId $id -ObjectName $c.Name `
            -Evidence 'Empty collection with no deployments, no include/exclude references from other collections, not used as a limiting collection, and no collection variables.' `
            -Recommendation 'Delete unless it is a staging container someone still fills by hand.' `
            -FixScript ("Remove-CMCollection -Id '{0}' -Force" -f $id)
    }
}

function Test-HygDeploymentEmptyCollection {
    <#
    .SYNOPSIS
        COL-02: deployments whose target collection has zero members.
    #>
    param([Parameter(Mandatory)]$Data)

    $emptyCollections = @{}
    foreach ($c in @($Data.Collections)) {
        if ($c.MemberCount -eq 0) { $emptyCollections[[string]$c.CollectionID] = $c }
    }

    foreach ($d in @($Data.Deployments)) {
        $cid = [string]$d.CollectionID
        if (-not $cid -or -not $emptyCollections.ContainsKey($cid)) { continue }

        New-HygieneFinding -CheckId 'COL-02' -Severity Warning -Category 'Collections' `
            -ObjectType 'Deployment' -ObjectId $cid -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("Deployment targets collection '{0}' ({1}), which currently has zero members - it can never apply." -f $d.CollectionName, $cid) `
            -Recommendation 'Remove the deployment, or fix the collection membership if it emptied by accident.' `
            -FixScript ("# Review in console: deployment of '{0}' to collection '{1}'" -f $d.SoftwareName, $d.CollectionName)
    }
}

function Test-HygIncrementalCeiling {
    <#
    .SYNOPSIS
        COL-03: count of incremental-evaluation collections against the
        recommended ceiling. RefreshType 4 (Continuous) and 6 (Both)
        enroll a collection in incremental evaluation.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $ceiling = [int]$Thresholds.IncrementalCeiling
    $incremental = @($Data.Collections | Where-Object { $_.RefreshType -in 4, 6 })
    if ($incremental.Count -le $ceiling) { return }

    $sample = @($incremental | Sort-Object Name | Select-Object -First 15 | ForEach-Object { $_.Name }) -join ', '

    New-HygieneFinding -CheckId 'COL-03' -Severity Warning -Category 'Collections' `
        -ObjectType 'Site' -ObjectId '' -ObjectName 'Incremental evaluation load' `
        -Evidence ("{0} collections use incremental evaluation; above the recommended ceiling of {1}, evaluation latency degrades site-wide. First 15 by name: {2}" -f $incremental.Count, $ceiling, $sample) `
        -Recommendation 'Switch rarely-changing collections to scheduled-only refresh until the count sits under the ceiling.' `
        -FixScript "# Per collection: Set-CMCollection -Id <CollectionID> -RefreshType Periodic"
}

# ---------------------------------------------------------------------------
# Checks: Deployments
# ---------------------------------------------------------------------------

function Test-HygDeploymentExpired {
    <#
    .SYNOPSIS
        DPL-01: application deployments whose expiration time has passed.
    #>
    param([Parameter(Mandatory)]$Data)

    $now = Get-Date
    foreach ($d in @($Data.AppDeployments)) {
        if (-not $d.ExpirationTimeEnabled) { continue }
        if (-not $d.ExpirationTime -or $d.ExpirationTime -ge $now) { continue }

        New-HygieneFinding -CheckId 'DPL-01' -Severity Info -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.TargetCollectionID) -ObjectName ("{0} -> {1}" -f $d.ApplicationName, $d.CollectionName) `
            -Evidence ("Deployment expired {0} and no longer offers to clients; it is clutter in every deployment view." -f $d.ExpirationTime) `
            -Recommendation 'Remove the expired deployment.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' -CollectionName '{1}' | Remove-CMApplicationDeployment -Force" -f ($d.ApplicationName -replace "'", "''"), ($d.CollectionName -replace "'", "''"))
    }
}

function Test-HygDeploymentPastDeadlineFailures {
    <#
    .SYNOPSIS
        DPL-02: required deployments past their enforcement deadline with a
        failure rate over the threshold.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the failure condition it tests.')]
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $grace = [int]$Thresholds.DeadlineGraceDays
    $pctThreshold = [int]$Thresholds.FailurePctThreshold
    $cutoff = (Get-Date).AddDays(-$grace)

    foreach ($d in @($Data.Deployments)) {
        if ($d.DeploymentIntent -ne 1) { continue }
        if (-not $d.EnforcementDeadline -or $d.EnforcementDeadline -gt $cutoff) { continue }
        if ($d.NumberTargeted -le 0 -or $d.NumberErrors -le 0) { continue }
        $pct = [math]::Round(($d.NumberErrors / $d.NumberTargeted) * 100, 1)
        if ($pct -lt $pctThreshold) { continue }

        New-HygieneFinding -CheckId 'DPL-02' -Severity Error -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.CollectionID) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("Required deployment passed its deadline {0} (over {1} days ago) with {2} of {3} targeted clients in error ({4}%)." -f $d.EnforcementDeadline, $grace, $d.NumberErrors, $d.NumberTargeted, $pct) `
            -Recommendation 'Investigate the client errors; a deployment stuck past deadline at this failure rate needs a fix or retirement, not more time.' `
            -FixScript ("# Triage first: deployment status for '{0}' on collection '{1}' in the console or via Get-CMDeployment" -f $d.SoftwareName, $d.CollectionName)
    }
}

function Test-HygDeploymentAvailableUnused {
    <#
    .SYNOPSIS
        DPL-03: available deployments old enough to judge with zero
        successes and nothing in progress.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $minAge = [int]$Thresholds.AvailableUnusedMinAgeDays
    $cutoff = (Get-Date).AddDays(-$minAge)

    foreach ($d in @($Data.Deployments)) {
        if ($d.DeploymentIntent -ne 2) { continue }
        if (-not $d.CreationTime -or $d.CreationTime -gt $cutoff) { continue }
        if ($d.NumberTargeted -le 0) { continue }
        if (($d.NumberSuccess + $d.NumberInProgress) -gt 0) { continue }

        New-HygieneFinding -CheckId 'DPL-03' -Severity Info -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.CollectionID) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("Available deployment created {0} (over {1} days ago) targets {2} clients with zero installs and nothing in progress." -f $d.CreationTime, $minAge, $d.NumberTargeted) `
            -Recommendation 'Nobody is opting in; remove the deployment or rethink how it is offered.' `
            -FixScript ("# Review: deployment of '{0}' to '{1}'" -f $d.SoftwareName, $d.CollectionName)
    }
}

# ---------------------------------------------------------------------------
# Application relationships (absorbed from the supersedence-auditor tool)
# ---------------------------------------------------------------------------

function ConvertTo-HygRelationships {
    <#
    .SYNOPSIS
        Parses SDMPackageXML into supersedence/dependency relationship
        records and deployment-type content locations. Pure over its input.

    .DESCRIPTION
        One in-memory XPath pass replaces per-app cmdlet round-trips. The
        XML shape: /AppMgmtDigest/DeploymentType (digest namespace) with
        Supersedes and Dependencies rule blocks in the Rules namespace;
        each DeploymentTypeIntentExpression carries the referenced
        application's AuthoringScopeId/LogicalName (its ModelName) and,
        for dependencies, a DesiredState of Required or Optional.

    .PARAMETER Applications
        Objects with CI_ID, ModelName, Name, SoftwareVersion, IsSuperseding,
        NumberOfDeploymentTypes, SDMPackageXML.

    .OUTPUTS
        [pscustomobject] Relationships (FromAppCIID/FromAppName/FromDTName/
        ToAppCIID/ToAppName/ToModelName/ToAppExists/Kind/DependencyState),
        ContentLocations (AppCIID/AppName/DTName/Location), ParseNotes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Converts to the full relationship set by design.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Applications
    )

    $modelToApp = @{}
    foreach ($app in $Applications) {
        if ($app.ModelName) { $modelToApp[[string]$app.ModelName] = $app }
    }

    $relationships = New-Object System.Collections.Generic.List[object]
    $contentLocations = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]

    $nsDigest = 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'
    $nsRules  = 'https://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules'

    $withXml = @($Applications | Where-Object { $_.NumberOfDeploymentTypes -gt 0 -and $_.SDMPackageXML })

    foreach ($app in $withXml) {
        try {
            [xml]$xml = $app.SDMPackageXML
        }
        catch {
            $notes.Add(("SDMPackageXML for '{0}' did not parse: {1}" -f $app.Name, $_.Exception.Message))
            continue
        }

        $nsm = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $nsm.AddNamespace('d', $nsDigest)
        $nsm.AddNamespace('r', $nsRules)

        $dtNodes = $xml.SelectNodes('/d:AppMgmtDigest/d:DeploymentType', $nsm)
        foreach ($dtNode in $dtNodes) {
            $dtTitle = ''
            $titleNode = $dtNode.SelectSingleNode('d:Title', $nsm)
            if ($titleNode) { $dtTitle = $titleNode.InnerText }

            foreach ($loc in $dtNode.SelectNodes('d:Installer/d:Contents/d:Content/d:Location', $nsm)) {
                $path = [string]$loc.InnerText
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $contentLocations.Add([pscustomobject]@{
                        AppCIID = [int]$app.CI_ID
                        AppName = [string]$app.Name
                        DTName  = $dtTitle
                        Location = $path.Trim()
                    })
                }
            }

            if ($app.IsSuperseding) {
                foreach ($rule in $dtNode.SelectNodes('d:Supersedes/r:DeploymentTypeRule', $nsm)) {
                    foreach ($intent in $rule.SelectNodes('.//r:DeploymentTypeIntentExpression', $nsm)) {
                        $appRef = $intent.SelectSingleNode('r:DeploymentTypeApplicationReference', $nsm)
                        if (-not $appRef) { continue }
                        $refModel = '{0}/{1}' -f $appRef.GetAttribute('AuthoringScopeId'), $appRef.GetAttribute('LogicalName')
                        $toApp = $null
                        if ($modelToApp.ContainsKey($refModel)) { $toApp = $modelToApp[$refModel] }

                        $relationships.Add([pscustomobject]@{
                            FromAppCIID     = [int]$app.CI_ID
                            FromAppName     = [string]$app.Name
                            FromDTName      = $dtTitle
                            ToAppCIID       = if ($toApp) { [int]$toApp.CI_ID } else { 0 }
                            ToAppName       = if ($toApp) { [string]$toApp.Name } else { "Unknown ($refModel)" }
                            ToModelName     = $refModel
                            ToAppExists     = ($null -ne $toApp)
                            Kind            = 'Supersedence'
                            DependencyState = ''
                        })
                    }
                }
            }

            foreach ($rule in $dtNode.SelectNodes('d:Dependencies/r:DeploymentTypeRule', $nsm)) {
                foreach ($intent in $rule.SelectNodes('.//r:DeploymentTypeIntentExpression', $nsm)) {
                    $appRef = $intent.SelectSingleNode('r:DeploymentTypeApplicationReference', $nsm)
                    if (-not $appRef) { continue }
                    $refModel = '{0}/{1}' -f $appRef.GetAttribute('AuthoringScopeId'), $appRef.GetAttribute('LogicalName')
                    $toApp = $null
                    if ($modelToApp.ContainsKey($refModel)) { $toApp = $modelToApp[$refModel] }

                    $desired = [string]$intent.GetAttribute('DesiredState')
                    $depState = switch ($desired) {
                        'Required' { 'Required' }
                        'Optional' { 'Optional' }
                        default    { 'AppDependence' }
                    }

                    $relationships.Add([pscustomobject]@{
                        FromAppCIID     = [int]$app.CI_ID
                        FromAppName     = [string]$app.Name
                        FromDTName      = $dtTitle
                        ToAppCIID       = if ($toApp) { [int]$toApp.CI_ID } else { 0 }
                        ToAppName       = if ($toApp) { [string]$toApp.Name } else { "Unknown ($refModel)" }
                        ToModelName     = $refModel
                        ToAppExists     = ($null -ne $toApp)
                        Kind            = 'Dependency'
                        DependencyState = $depState
                    })
                }
            }
        }
    }

    # .ToArray(), not @(...): wrapping a generic List of PSCustomObjects in
    # an array subexpression throws "Argument types do not match" on some
    # PowerShell 7 builds.
    return [pscustomobject]@{
        Relationships    = $relationships.ToArray()
        ContentLocations = $contentLocations.ToArray()
        ParseNotes       = $notes.ToArray()
    }
}

function Get-HygieneRelationshipData {
    <#
    .SYNOPSIS
        Bulk-loads applications WITH SDMPackageXML and resolves every
        supersedence/dependency relationship in one pass.

    .DESCRIPTION
        One Get-CMApplication call (no -Fast: the XML is the point)
        followed by the pure parser. Requires an established CM
        connection. Returns $null on total failure with the reason logged.
    #>
    param()

    try {
        Write-Log 'Loading applications with SDMPackageXML for relationship analysis...'
        $apps = @(Get-CMApplication -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                CI_ID                   = [int]$_.CI_ID
                ModelName               = [string]$_.ModelName
                Name                    = [string]$_.LocalizedDisplayName
                SoftwareVersion         = [string]$_.SoftwareVersion
                Manufacturer            = [string]$_.Manufacturer
                IsEnabled               = [bool]$_.IsEnabled
                IsExpired               = [bool]$_.IsExpired
                IsSuperseded            = [bool]$_.IsSuperseded
                IsSuperseding           = [bool]$_.IsSuperseding
                HasContent              = [bool]$_.HasContent
                NumberOfDeploymentTypes = [int]$_.NumberOfDeploymentTypes
                SDMPackageXML           = [string]$_.SDMPackageXML
            }
        })

        $parsed = ConvertTo-HygRelationships -Applications $apps

        # The lookup drops SDMPackageXML: consumers need flags and names
        # only, and the XML blobs would otherwise ride along through the
        # background-runspace state transfer.
        $lookup = @{}
        foreach ($a in $apps) {
            $lookup[[int]$a.CI_ID] = [pscustomobject]@{
                CI_ID                   = $a.CI_ID
                ModelName               = $a.ModelName
                Name                    = $a.Name
                SoftwareVersion         = $a.SoftwareVersion
                Manufacturer            = $a.Manufacturer
                IsEnabled               = $a.IsEnabled
                IsExpired               = $a.IsExpired
                IsSuperseded            = $a.IsSuperseded
                IsSuperseding           = $a.IsSuperseding
                HasContent              = $a.HasContent
                NumberOfDeploymentTypes = $a.NumberOfDeploymentTypes
            }
        }

        Write-Log ("Resolved {0} relationships and {1} content locations from {2} applications" -f @($parsed.Relationships).Count, @($parsed.ContentLocations).Count, $apps.Count)

        return [pscustomobject]@{
            Apps             = $lookup
            Relationships    = $parsed.Relationships
            ContentLocations = $parsed.ContentLocations
            DatasetNotes     = $parsed.ParseNotes
        }
    }
    catch {
        Write-Log ("Relationship data unavailable: {0}" -f $_.Exception.Message) -Level WARN
        return $null
    }
}

function Find-HygCircularEdges {
    <#
    .SYNOPSIS
        Returns the set of edges that participate in a cycle: an edge
        (From -> To) is circular when From is reachable from To.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the circular edge set by design.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Edges
    )

    $adj = @{}
    foreach ($e in $Edges) {
        $k = [int]$e.FromAppCIID
        if (-not $adj.ContainsKey($k)) { $adj[$k] = New-Object System.Collections.Generic.List[int] }
        $adj[$k].Add([int]$e.ToAppCIID)
    }

    $reachCache = @{}
    $reach = {
        param([int]$From, [int]$Target)
        $key = "$From>$Target"
        if ($reachCache.ContainsKey($key)) { return $reachCache[$key] }
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        $stack = New-Object System.Collections.Generic.Stack[int]
        $stack.Push($From)
        $found = $false
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n -eq $Target) { $found = $true; break }
            if (-not $seen.Add($n)) { continue }
            if ($adj.ContainsKey($n)) { foreach ($m in $adj[$n]) { $stack.Push($m) } }
        }
        $reachCache[$key] = $found
        return $found
    }

    $circular = @()
    foreach ($e in $Edges) {
        if ([int]$e.ToAppCIID -eq 0) { continue }
        if (& $reach ([int]$e.ToAppCIID) ([int]$e.FromAppCIID)) { $circular += ,$e }
    }
    # Emit unrolled: callers rebuild with @(...).
    return $circular
}

function Test-HygRelationshipChecks {
    <#
    .SYNOPSIS
        SUP-01..04, DEP-01..05, REL-01 over parsed relationship data.

    .DESCRIPTION
        Status semantics match the absorbed auditor: orphaned reference and
        circular chains are errors, expired targets and disabled
        source/target are warnings, a dependency target without content is
        an error, relationships without manufacturer metadata are
        informational. Supersedence and dependency rules have no removal
        cmdlet, so the fix scripts are console guidance.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the full relationship check family by design.')]
    param(
        [Parameter(Mandatory)]$RelationshipData
    )

    $apps = $RelationshipData.Apps
    $rels = @($RelationshipData.Relationships)
    $sup  = @($rels | Where-Object { $_.Kind -eq 'Supersedence' })
    $dep  = @($rels | Where-Object { $_.Kind -eq 'Dependency' })

    foreach ($r in $sup) {
        $pair = "'{0}' -> '{1}'" -f $r.FromAppName, $r.ToAppName
        if (-not $r.ToAppExists) {
            New-HygieneFinding -CheckId 'SUP-01' -Severity Error -Category 'Relationships' `
                -ObjectType 'Supersedence' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Supersedence on deployment type '{0}' references {1}, which no longer exists in the site." -f $r.FromDTName, $r.ToModelName) `
                -Recommendation 'Remove the broken supersedence reference.' `
                -FixScript ("# Console: '{0}' Properties > Supersedence tab - remove the reference to the deleted application" -f $r.FromAppName)
            continue
        }
        $fromApp = $apps[[int]$r.FromAppCIID]
        $toApp   = $apps[[int]$r.ToAppCIID]
        if ($toApp -and $toApp.IsExpired) {
            New-HygieneFinding -CheckId 'SUP-04' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Supersedence' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Superseded application '{0}' is retired; the rule still exists but its target is inactive." -f $r.ToAppName) `
                -Recommendation 'Remove the supersedence relationship or delete the retired application once nothing references it.' `
                -FixScript ("# Console: '{0}' Properties > Supersedence tab - review the reference to retired '{1}'" -f $r.FromAppName, $r.ToAppName)
        }
        elseif ($fromApp -and -not $fromApp.IsEnabled) {
            New-HygieneFinding -CheckId 'SUP-03' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Supersedence' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Superseding application '{0}' is disabled; the replacement cannot deploy while the rule stands." -f $r.FromAppName) `
                -Recommendation 'Enable the superseding application or remove the supersedence relationship.' `
                -FixScript ("Get-CMApplication -Name '{0}' | Enable-CMApplication" -f ($r.FromAppName -replace "'", "''"))
        }
    }

    foreach ($e in (Find-HygCircularEdges -Edges $sup)) {
        New-HygieneFinding -CheckId 'SUP-02' -Severity Error -Category 'Relationships' `
            -ObjectType 'Supersedence' -ObjectId ([string]$e.FromAppCIID) -ObjectName ("'{0}' -> '{1}'" -f $e.FromAppName, $e.ToAppName) `
            -Evidence 'This supersedence edge is part of a loop: following the chain from the superseded application eventually returns to the superseding one.' `
            -Recommendation 'Break the loop by removing the relationship that closes it.' `
            -FixScript ("# Console: review the supersedence chain starting at '{0}' and remove the looping reference" -f $e.FromAppName)
    }

    foreach ($r in $dep) {
        $pair = "'{0}' -> '{1}'" -f $r.FromAppName, $r.ToAppName
        if (-not $r.ToAppExists) {
            New-HygieneFinding -CheckId 'DEP-01' -Severity Error -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency on deployment type '{0}' references {1}, which no longer exists in the site." -f $r.FromDTName, $r.ToModelName) `
                -Recommendation 'Remove the broken dependency; installs of the parent fail while it references a deleted application.' `
                -FixScript ("# Console: '{0}' > Deployment Types > '{1}' > Dependencies - remove the broken reference" -f $r.FromAppName, $r.FromDTName)
            continue
        }
        $toApp = $apps[[int]$r.ToAppCIID]
        if ($toApp -and $toApp.IsExpired) {
            New-HygieneFinding -CheckId 'DEP-04' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency target '{0}' is retired; {1} installs relying on it will fail." -f $r.ToAppName, $r.DependencyState) `
                -Recommendation 'Point the dependency at the current application or reinstate the target.' `
                -FixScript ("# Console: '{0}' > Deployment Types > '{1}' > Dependencies - update the reference to retired '{2}'" -f $r.FromAppName, $r.FromDTName, $r.ToAppName)
        }
        elseif ($toApp -and -not $toApp.IsEnabled) {
            New-HygieneFinding -CheckId 'DEP-03' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency target '{0}' is disabled; automatic dependency installs will fail." -f $r.ToAppName) `
                -Recommendation 'Enable the dependency target or remove the dependency.' `
                -FixScript ("Get-CMApplication -Name '{0}' | Enable-CMApplication" -f ($r.ToAppName -replace "'", "''"))
        }
        elseif ($toApp -and -not $toApp.HasContent) {
            New-HygieneFinding -CheckId 'DEP-05' -Severity Error -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId ([string]$r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency target '{0}' has no distributed content; automatic dependency installs cannot download it." -f $r.ToAppName) `
                -Recommendation 'Distribute the dependency target content to the DPs serving the parent.' `
                -FixScript ("Start-CMContentDistribution -ApplicationName '{0}' -DistributionPointGroupName '<group>'" -f ($r.ToAppName -replace "'", "''"))
        }
    }

    foreach ($e in (Find-HygCircularEdges -Edges $dep)) {
        New-HygieneFinding -CheckId 'DEP-02' -Severity Error -Category 'Relationships' `
            -ObjectType 'Dependency' -ObjectId ([string]$e.FromAppCIID) -ObjectName ("'{0}' -> '{1}'" -f $e.FromAppName, $e.ToAppName) `
            -Evidence 'This dependency edge is part of a loop: the target eventually depends back on the source, which deadlocks automatic installs.' `
            -Recommendation 'Break the loop by removing one dependency in the cycle.' `
            -FixScript ("# Console: review the dependency chain starting at '{0}' and remove the looping reference" -f $e.FromAppName)
    }

    # REL-01: apps carrying relationships but no manufacturer metadata.
    $participants = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($r in $rels) {
        [void]$participants.Add([int]$r.FromAppCIID)
        if ([int]$r.ToAppCIID -ne 0) { [void]$participants.Add([int]$r.ToAppCIID) }
    }
    foreach ($ciid in $participants) {
        $app = $apps[[int]$ciid]
        if ($app -and [string]::IsNullOrWhiteSpace([string]$app.Manufacturer)) {
            New-HygieneFinding -CheckId 'REL-01' -Severity Info -Category 'Relationships' `
                -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
                -Evidence 'Application participates in supersedence/dependency relationships but has no Manufacturer set, which makes relationship views hard to audit.' `
                -Recommendation 'Fill in the Manufacturer field.' `
                -FixScript ("Set-CMApplication -Name '{0}' -Publisher '<manufacturer>'" -f ($app.Name -replace "'", "''"))
        }
    }
}

function Build-HygRelationshipTree {
    <#
    .SYNOPSIS
        Builds a nested node tree for one relationship kind, rooted at
        applications nothing of that kind points to. Pure over its input.

    .DESCRIPTION
        Node shape: Label, Glyph, AppCIID, Children[]. Glyphs: check for
        healthy, warn for disabled or content-less, x for missing or
        retired. A path-local visited set stops circular chains; MaxDepth
        bounds pathological graphs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the tree it builds.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxDepth', Justification='Consumed inside the nested New-Node function via dynamic scope.')]
    param(
        [Parameter(Mandatory)]$RelationshipData,
        [Parameter(Mandatory)][ValidateSet('Supersedence', 'Dependency')][string]$Kind,
        [int]$MaxDepth = 12
    )

    $apps  = $RelationshipData.Apps
    $edges = @($RelationshipData.Relationships | Where-Object { $_.Kind -eq $Kind })

    $adj = @{}
    $targets = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($e in $edges) {
        $k = [int]$e.FromAppCIID
        if (-not $adj.ContainsKey($k)) { $adj[$k] = New-Object System.Collections.Generic.List[object] }
        $adj[$k].Add($e)
        if ([int]$e.ToAppCIID -ne 0) { [void]$targets.Add([int]$e.ToAppCIID) }
    }

    function Get-NodeGlyph {
        param($App, [bool]$Exists)
        if (-not $Exists -or -not $App) { return [char]0x2717 }
        if ($App.IsExpired) { return [char]0x2717 }
        if (-not $App.IsEnabled) { return [char]0x26A0 }
        if (-not $App.HasContent) { return [char]0x26A0 }
        return [char]0x2713
    }

    function New-Node {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Constructs an in-memory tree node; changes no system state.')]
        param([int]$CIID, [string]$FallbackLabel, [bool]$Exists, [int]$Depth, $Path)
        $app = if ($Exists) { $apps[[int]$CIID] } else { $null }
        $label = if ($app) {
            if ($app.SoftwareVersion) { '{0} ({1})' -f $app.Name, $app.SoftwareVersion } else { [string]$app.Name }
        } else { $FallbackLabel }

        $children = @()
        if ($Exists -and $Depth -lt $MaxDepth -and $adj.ContainsKey($CIID) -and -not $Path.Contains($CIID)) {
            [void]$Path.Add($CIID)
            foreach ($e in $adj[$CIID]) {
                if ([int]$e.ToAppCIID -ne 0 -and $Path.Contains([int]$e.ToAppCIID)) {
                    $children += [pscustomobject]@{
                        Label = ('{0} (circular reference)' -f $e.ToAppName)
                        Glyph = [char]0x2717
                        AppCIID = [int]$e.ToAppCIID
                        Children = @()
                    }
                    continue
                }
                $children += New-Node -CIID ([int]$e.ToAppCIID) -FallbackLabel ([string]$e.ToAppName) -Exists $e.ToAppExists -Depth ($Depth + 1) -Path $Path
            }
            [void]$Path.Remove($CIID)
        }

        return [pscustomobject]@{
            Label    = $label
            Glyph    = Get-NodeGlyph -App $app -Exists $Exists
            AppCIID  = [int]$CIID
            Children = @($children)
        }
    }

    $roots = @($adj.Keys | Where-Object { -not $targets.Contains([int]$_) } | Sort-Object { $apps[[int]$_].Name })
    # In a pure cycle every node is also a target; fall back to every edge
    # source so the loop still renders.
    if ($roots.Count -eq 0 -and $adj.Keys.Count -gt 0) { $roots = @($adj.Keys) }

    $nodes = foreach ($r in $roots) {
        New-Node -CIID ([int]$r) -FallbackLabel 'Unknown' -Exists $true -Depth 0 -Path (New-Object System.Collections.Generic.List[int])
    }
    return @($nodes)
}

function Test-HygAppContentPath {
    <#
    .SYNOPSIS
        APP-04: deployment-type content source folders that are missing or
        unreachable from this workstation.

    .DESCRIPTION
        Probes each unique content location once with a bounded Test-Path.
        Unreachable can mean deleted source or no rights from here - the
        evidence says which app/DT so the operator can judge.
    #>
    param(
        [Parameter(Mandatory)]$RelationshipData
    )

    $checked = @{}
    foreach ($loc in @($RelationshipData.ContentLocations)) {
        $path = [string]$loc.Location
        if (-not $checked.ContainsKey($path)) {
            $ok = $false
            try { $ok = Test-Path -LiteralPath $path -ErrorAction Stop } catch { $ok = $false }
            $checked[$path] = $ok
        }
        if ($checked[$path]) { continue }

        New-HygieneFinding -CheckId 'APP-04' -Severity Warning -Category 'Applications' `
            -ObjectType 'DeploymentType' -ObjectId ([string]$loc.AppCIID) -ObjectName ("{0} / {1}" -f $loc.AppName, $loc.DTName) `
            -Evidence ("Content source '{0}' is missing or unreachable from this workstation; content updates and new distributions will fail." -f $path) `
            -Recommendation 'Restore the source folder, correct the deployment type content location, or verify share permissions.' `
            -FixScript ("# Console: '{0}' > Deployment Types > '{1}' > Content - correct the content location" -f $loc.AppName, $loc.DTName)
    }
}

# ---------------------------------------------------------------------------
# Scan orchestration
# ---------------------------------------------------------------------------

function Invoke-HygieneScan {
    <#
    .SYNOPSIS
        Runs every implemented check over a prefetched dataset and returns
        findings sorted by severity, then check id, then object name.

    .DESCRIPTION
        Pure over its input: pass real data from Get-HygieneData or
        synthetic data of the same shape. A check that throws is recorded
        as a finding against the scan itself rather than aborting the run.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds),
        $RelationshipData = $null
    )

    # Threshold-less checks take only $d; the runner still passes every
    # argument and the extras land in $args, keeping one invocation shape.
    $checks = @(
        @{ Id = 'APP-01'; Run = { param($d, $t) Test-HygAppNoReferences -Data $d -Thresholds $t } }
        @{ Id = 'APP-02'; Run = { param($d) Test-HygAppRetiredDeployed -Data $d } }
        @{ Id = 'APP-03'; Run = { param($d) Test-HygAppSupersededDeployed -Data $d } }
        @{ Id = 'PKG-01'; Run = { param($d) Test-HygPackageUnused -Data $d } }
        @{ Id = 'COL-01'; Run = { param($d) Test-HygCollectionEmptyUnused -Data $d } }
        @{ Id = 'COL-02'; Run = { param($d) Test-HygDeploymentEmptyCollection -Data $d } }
        @{ Id = 'COL-03'; Run = { param($d, $t) Test-HygIncrementalCeiling -Data $d -Thresholds $t } }
        @{ Id = 'DPL-01'; Run = { param($d) Test-HygDeploymentExpired -Data $d } }
        @{ Id = 'DPL-02'; Run = { param($d, $t) Test-HygDeploymentPastDeadlineFailures -Data $d -Thresholds $t } }
        @{ Id = 'DPL-03'; Run = { param($d, $t) Test-HygDeploymentAvailableUnused -Data $d -Thresholds $t } }
    )
    if ($RelationshipData) {
        # $args-based: these only consume the third runner argument.
        $checks += @(
            @{ Id = 'SUP/DEP/REL'; Run = { Test-HygRelationshipChecks -RelationshipData $args[2] } }
            @{ Id = 'APP-04';      Run = { Test-HygAppContentPath -RelationshipData $args[2] } }
        )
    }
    else {
        Write-Log 'Relationship data not collected; SUP/DEP/REL and APP-04 checks skipped this scan.' -Level WARN
    }

    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($check in $checks) {
        try {
            foreach ($f in @(& $check.Run $Data $Thresholds $RelationshipData)) {
                if ($f) { $findings.Add($f) }
            }
        }
        catch {
            Write-Log ("Check {0} failed: {1}" -f $check.Id, $_.Exception.Message) -Level WARN
            $findings.Add((New-HygieneFinding -CheckId $check.Id -Severity Warning -Category 'Scan' `
                -ObjectType 'Check' -ObjectName ("Check {0} did not run" -f $check.Id) `
                -Evidence ("The check itself failed: {0}" -f $_.Exception.Message) `
                -Recommendation 'Findings from this check are missing from the results; the failure is a defect worth reporting.'))
        }
    }

    $severityRank = @{ 'Error' = 0; 'Warning' = 1; 'Info' = 2 }
    $sorted = @($findings | Sort-Object -Property @{ Expression = { $severityRank[$_.Severity] } }, CheckId, ObjectName)
    Write-Log ("Hygiene scan produced {0} finding(s)" -f $sorted.Count)
    # Emit unrolled: callers rebuild with @(...) and a wrapped return would
    # hand them a single array element instead of N findings.
    return $sorted
}

function Get-HygieneScanSummary {
    <#
    .SYNOPSIS
        Aggregates findings into per-check rows for the Summary view.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings
    )

    $byCheck = @{}
    foreach ($f in $Findings) {
        if (-not $byCheck.ContainsKey($f.CheckId)) { $byCheck[$f.CheckId] = 0 }
        $byCheck[$f.CheckId]++
    }

    $rows = foreach ($check in (Get-HygieneCheckCatalog)) {
        $count = 0
        if ($byCheck.ContainsKey($check.Id)) { $count = $byCheck[$check.Id] }
        [pscustomobject]@{
            CheckId  = $check.Id
            Severity = $check.Severity
            Category = $check.Category
            Title    = $check.Title
            Findings = $count
        }
    }
    return @($rows)
}

function Get-HygieneSuppressionKey {
    <#
    .SYNOPSIS
        Stable identity for a finding, used by the suppression list and
        rescan comparisons.
    #>
    param(
        [Parameter(Mandatory)]$Finding
    )
    return '{0}|{1}|{2}|{3}' -f $Finding.CheckId, $Finding.ObjectType, $Finding.ObjectId, $Finding.ObjectName
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

function Export-HygieneCsv {
    <#
    .SYNOPSIS
        Exports findings to CSV.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $parentDir = Split-Path -Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $Findings |
        Select-Object CheckId, Severity, Category, ObjectType, ObjectId, ObjectName, Evidence, Recommendation, FixScript |
        Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Log "Exported CSV to $OutputPath"
}

function Export-HygieneHtml {
    <#
    .SYNOPSIS
        Exports findings to a self-contained HTML report with
        severity-coded rows.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Site Hygiene Report'
    )

    $parentDir = Split-Path -Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $css = @(
        '<style>',
        'body { font-family: "Segoe UI", Arial, sans-serif; margin: 20px; background: #fafafa; }',
        'h1 { color: #0078D4; margin-bottom: 4px; }',
        '.summary { color: #555; margin-bottom: 16px; }',
        'table { border-collapse: collapse; width: 100%; margin-top: 12px; }',
        'th { background: #0078D4; color: #fff; padding: 8px 12px; text-align: left; }',
        'td { padding: 6px 12px; border-bottom: 1px solid #e0e0e0; vertical-align: top; }',
        'tr:nth-child(even) { background: #f5f5f5; }',
        '.sev-Error { color: #c00; font-weight: bold; }',
        '.sev-Warning { color: #b87800; font-weight: bold; }',
        '.sev-Info { color: #228b22; }',
        'code { font-family: Consolas, monospace; font-size: 0.9em; }',
        '</style>'
    ) -join "`r`n"

    $encode = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

    $bodyRows = foreach ($f in $Findings) {
        $cells = @(
            ('<td class="sev-{0}">{0}</td>' -f (& $encode $f.Severity)),
            ('<td>{0}</td>' -f (& $encode $f.CheckId)),
            ('<td>{0}</td>' -f (& $encode $f.Category)),
            ('<td>{0}</td>' -f (& $encode $f.ObjectName)),
            ('<td>{0}</td>' -f (& $encode $f.Evidence)),
            ('<td>{0}</td>' -f (& $encode $f.Recommendation)),
            ('<td><code>{0}</code></td>' -f (& $encode $f.FixScript))
        )
        "<tr>$($cells -join '')</tr>"
    }

    $counts = @($Findings | Group-Object Severity | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }) -join ', '
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $html = @(
        '<!DOCTYPE html>',
        '<html><head><meta charset="utf-8"><title>' + (& $encode $ReportTitle) + '</title>',
        $css,
        '</head><body>',
        ('<h1>{0}</h1>' -f (& $encode $ReportTitle)),
        ('<div class="summary">Generated: {0} | Findings: {1}{2}</div>' -f $timestamp, @($Findings).Count, $(if ($counts) { " ($counts)" } else { '' })),
        '<table><thead><tr><th>Severity</th><th>Check</th><th>Category</th><th>Object</th><th>Evidence</th><th>Recommendation</th><th>Fix script</th></tr></thead>',
        "<tbody>$($bodyRows -join "`r`n")</tbody></table>",
        '</body></html>'
    ) -join "`r`n"

    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    Write-Log "Exported HTML to $OutputPath"
}

function New-HygieneSummaryText {
    <#
    .SYNOPSIS
        Plain-text scan summary for clipboard or log.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Builds a string; changes no system state.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [string[]]$DatasetNotes = @()
    )

    $lines = @()
    $lines += '=== Site Hygiene Summary ==='
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''
    $lines += "Total findings: $(@($Findings).Count)"
    foreach ($group in ($Findings | Group-Object Severity | Sort-Object Name)) {
        $lines += ("  {0}: {1}" -f $group.Name, $group.Count)
    }
    $lines += ''
    foreach ($group in ($Findings | Group-Object CheckId | Sort-Object Name)) {
        $lines += ("  {0}: {1} finding(s)" -f $group.Name, $group.Count)
    }
    if ($DatasetNotes.Count -gt 0) {
        $lines += ''
        $lines += '--- Dataset notes ---'
        foreach ($n in $DatasetNotes) { $lines += "  $n" }
    }
    return ($lines -join "`r`n")
}
