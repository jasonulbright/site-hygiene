# Shared helpers for the Site Hygiene tests. Dot-source from BeforeAll.

$script:AppRoot = Split-Path -Parent $PSScriptRoot

# A module that an earlier test file loaded can leave a nested module behind. Pester then finds two modules of the
# same name and puts its mocks into the wrong one, so every instance is removed before the import.
function Import-AppModule {
    foreach ($name in 'SiteHygieneLive', 'SiteHygieneCommon') { Get-Module -Name $name -All | Remove-Module -Force -ErrorAction SilentlyContinue }
    Import-Module (Join-Path $script:AppRoot 'Module\SiteHygieneCommon.psd1') -Force -DisableNameChecking
}

# SuiteCommon in the global scope, so tests can call and mock its functions the way the shell does.
function Import-SuiteCommonGlobal {
    # SuiteCommon parameter types name MahApps classes; load them so the signatures resolve.
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction SilentlyContinue
    foreach ($dll in 'Microsoft.Xaml.Behaviors.dll', 'ControlzEx.dll', 'MahApps.Metro.dll') {
        [void][System.Reflection.Assembly]::LoadFrom((Join-Path $script:AppRoot "Lib\$dll"))
    }
    Import-Module (Join-Path $script:AppRoot 'Lib\SuiteCommon\SuiteCommon.psd1') -Global -DisableNameChecking
}

# Defines a global stub function for each named ConfigMgr command, so Pester can
# mock it the same way on every machine. A function beats a cmdlet in command
# lookup, so the stub also shadows the real cmdlet on a machine that has the
# ConfigMgr console. Call Remove-CmStub afterwards so the stubs never outlive
# the test file. The stub declares the parameters that the code under test and
# the tests use; the real signatures are checked in CmCmdlet.Contract.Tests.ps1.
$script:CmStubDefinition = {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]$InputObject,
        $Id, $Name, $ModelName, $CollectionId, $CollectionName, $DeploymentId, $Query, $Option,
        $MaintenanceTaskName, $SiteCode, $Enabled, $Revision, $AutoInstall, $Publisher, $RefreshType,
        $MaintenanceWindowName, $ApplicationName,
        [switch]$Fast, [switch]$Force
    )
    process { }
}

# Every ConfigMgr command that the module reads with, and that the fix scripts of the checks call.
$script:CmReadStubNames = 'Get-CMApplication', 'Invoke-CMWmiQuery', 'Get-CMPackage', 'Get-CMProgram', 'Get-CMTaskSequence',
'Get-CMBoundary', 'Get-CMBoundaryGroup', 'Get-CMBootImage', 'Get-CMOperatingSystemImage', 'Get-CMOperatingSystemInstaller',
'Get-CMDriverPackage', 'Get-CMSoftwareUpdateGroup', 'Get-CMSoftwareUpdateDeploymentPackage', 'Get-CMAutoDeploymentRule',
'Get-CMSiteMaintenanceTask', 'Get-CMCollection', 'Get-CMDeployment', 'Get-CMConfigurationItem',
'Get-CMApplicationDeployment', 'Get-CMSoftwareUpdateDeploymentStatus', 'Get-CMPackageDeploymentStatus'

function New-CmStub {
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [scriptblock]$Definition = $script:CmStubDefinition
    )
    foreach ($n in $Name) { Set-Item -Path "function:global:$n" -Value $Definition }
    return $Name
}

function Remove-CmStub {
    param([string[]]$Name)
    foreach ($n in $Name) {
        Remove-Item -Path "function:global:$n" -ErrorAction SilentlyContinue
        # A stub set through function:global: can survive as a copy in the calling scope and shadow the real command.
        $guard = 0
        while ($guard++ -lt 8 -and (Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue)) {
            Remove-Item -Path "function:$n" -Force -ErrorAction SilentlyContinue
        }
    }
}

# The parameter names of one command call: the ones written as -Name, and the keys of a splatted
# hashtable (@params) that the same function or script block builds with a literal or with
# $params['Key'] / $params.Key assignments.
function Get-CommandParameterName {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Command)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Command.CommandElements) {
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) { $names.Add($e.ParameterName) }
        elseif ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and $e.Splatted) {
            $var = $e.VariablePath.UserPath
            $scope = $Command.Parent
            while ($scope -and $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $scope = $scope.Parent }
            if (-not $scope) { continue }
            $assigns = $scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
            foreach ($a in $assigns) {
                $left = $a.Left
                if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and $left.VariablePath.UserPath -eq $var -and $a.Right.Expression -is [System.Management.Automation.Language.HashtableAst]) {
                    foreach ($kv in $a.Right.Expression.KeyValuePairs) { if ($kv.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names.Add($kv.Item1.Value) } }
                }
                elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst] -and $left.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and $left.Target.VariablePath.UserPath -eq $var -and $left.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $names.Add($left.Index.Value)
                }
                elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and $left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $left.Expression.VariablePath.UserPath -eq $var -and $left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $names.Add($left.Member.Value)
                }
            }
        }
    }
    return @($names | Select-Object -Unique)
}

# Lists the ConfigMgr cmdlet calls of a script file with the parameter names of each call.
function Get-CmCmdletCall {
    param([Parameter(Mandatory)][string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    Get-CmCmdletCallFromAst -Ast $ast
}

function Get-CmCmdletCallFromAst {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    $calls = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(Get|Set|New|Remove|Start|Invoke|Add|Copy|Convert|Export|Import|Approve|Deny|Resume)-CM' -and $n.GetCommandName() -ne 'Get-CMConnectionInfo' }, $true)
    foreach ($c in $calls) {
        @{ Command = $c.GetCommandName(); Parameters = @(Get-CommandParameterName -Command $c); Line = $c.Extent.StartLineNumber }
    }
}

# Cuts the named functions out of a script file and returns their text (define them in the caller's scope).
# A function cut out of the script has no $PSScriptRoot; the repository folder replaces it.
function Get-ScriptFunctionText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    foreach ($n in $Name) {
        $def = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
        if (-not $def) { throw "function $n not found in $Path" }
        $def.Extent.Text.Replace('$PSScriptRoot', "'$($script:AppRoot -replace "'", "''")'")
    }
}

# The script block of an event handler such as $btnScan.Add_Click({ ... }) in a script file.
function Get-EventHandlerBlock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$EventName)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $call = $ast.Find({
            param($x)
            $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Member.Value -eq $EventName -and $x.Expression.Extent.Text -eq $Target
        }, $true)
    if (-not $call) { throw "handler $Target.$EventName not found in $Path" }
    $block = $call.Arguments | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1
    if (-not $block) { throw "handler $Target.$EventName has no script block" }
    # The extent includes the braces; the body is what a handler runs.
    $body = $block.ScriptBlock.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    $body.Replace('$PSScriptRoot', "'$($script:AppRoot -replace "'", "''")'")
}

# Cmdlet calls named in the text of a fix script: the parsed calls of the code lines, and the cmdlets
# named in comments (guidance for the operator). Quoted text and <placeholders> are ignored.
function Get-FixTextCall {
    param([Parameter(Mandatory)][string]$Text)
    $calls = @()
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    $calls += @(Get-CmCmdletCallFromAst -Ast $ast)
    foreach ($t in $tokens | Where-Object { $_.Kind -eq 'Comment' }) {
        foreach ($m in [regex]::Matches($t.Text, '(?<cmd>(?:Get|Set|New|Remove|Start|Invoke|Add|Copy|Resume)-CM[A-Za-z]+)(?<args>[^|#(]*)')) {
            $argText = [regex]::Replace($m.Groups['args'].Value, "'[^']*'|<[^>]*>", '')
            $names = @([regex]::Matches($argText, '(?<![\w-])-(?<p>[A-Za-z]+)') | ForEach-Object { $_.Groups['p'].Value })
            $calls += @{ Command = $m.Groups['cmd'].Value; Parameters = $names; Line = 0 }
        }
    }
    return $calls
}

# The text of every -FixScript argument of New-HygieneFinding in a module file, with each {n} placeholder
# replaced by X. An argument built another way (a joined list of lines) is not read.
function Get-FixScriptText {
    param([Parameter(Mandatory)][string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $finds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-HygieneFinding' }, $true)
    foreach ($f in $finds) {
        $els = $f.CommandElements
        for ($i = 0; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -isnot [System.Management.Automation.Language.CommandParameterAst] -or $els[$i].ParameterName -ne 'FixScript') { continue }
            $arg = $els[$i + 1]
            if ($arg -is [System.Management.Automation.Language.ParenExpressionAst]) { $arg = $arg.Pipeline.PipelineElements[0].Expression }
            if ($arg -is [System.Management.Automation.Language.BinaryExpressionAst]) { $arg = $arg.Left }
            if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $arg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                @{ Line = $f.Extent.StartLineNumber; Text = [regex]::Replace($arg.Value, '\{\d+\}', 'X') }
            }
        }
    }
}

# Fix scripts that the module builds at run time (a joined list of lines), which Get-FixScriptText cannot read from the source.
# APP-05 builds one Remove-CMApplicationRevisionHistory line per old revision.
function Get-GeneratedFixText {
    Import-AppModule
    $data = [PSCustomObject]@{
        Applications = @([PSCustomObject]@{ CI_ID = 501; ModelName = 'ScopeId_A/Application_1'; Name = 'App' })
        AppRevisions = @([PSCustomObject]@{ ModelName = 'ScopeId_A/Application_1'; Revision = 1 })
    }
    foreach ($finding in @(Test-HygAppOldRevisions -Data $data)) { @{ Line = 0; Text = [string]$finding.FixScript } }
}
