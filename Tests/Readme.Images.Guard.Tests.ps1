#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Headless guard for the images of the README: every image is a guide image or a mapped copy of one. Only parsing and file compare.

BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
    $script:Images = @([regex]::Matches($readme, '!\[[^\]]*\]\(([^)\s]+)\)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^https?://' } | Sort-Object -Unique | ForEach-Object { @{ Image = $_ } })
    $map = Get-Content -LiteralPath (Join-Path $root 'tools\guide-capture\readme-images.json') -Raw | ConvertFrom-Json
    $script:Mapped = @($map.PSObject.Properties | ForEach-Object { @{ Target = $_.Name; Source = $_.Value } })
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:MapNames = @((Get-Content -LiteralPath (Join-Path $script:Root 'tools\guide-capture\readme-images.json') -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name })
}

Describe 'README images' {
    It 'finds at least one image in the README' {
        @($script:Images).Count | Should -BeGreaterThan 0
    }

    It 'shows <Image> from docs/images or from the map readme-images.json' -ForEach $script:Images {
        ($Image -like 'docs/images/*' -or $script:MapNames -contains $Image) | Should -BeTrue
    }

    It 'maps <Target> to an existing guide image <Source> under docs/images' -ForEach $script:Mapped {
        $Source | Should -BeLike 'docs/images/*'
        Test-Path -LiteralPath (Join-Path $script:Root ($Source -replace '/', '\')) -PathType Leaf | Should -BeTrue
    }

    It 'keeps <Target> byte-identical to <Source>' -ForEach $script:Mapped {
        $a = (Get-FileHash -LiteralPath (Join-Path $script:Root ($Target -replace '/', '\')) -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath (Join-Path $script:Root ($Source -replace '/', '\')) -Algorithm SHA256).Hash
        $a | Should -Be $b -Because 'run tools\guide-capture\Sync-ReadmeImages.ps1 after the capture'
    }

    It 'maps every mapped image that the README shows' {
        $shown = @($script:Images | ForEach-Object { $_.Image })
        @($script:MapNames | Where-Object { $shown -notcontains $_ }) | Should -BeNullOrEmpty -Because 'a mapped image that the README does not show is stale'
    }
}
