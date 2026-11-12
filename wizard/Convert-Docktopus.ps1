[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [switch]$AnalyzeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectName([string]$Directory) {
    $name = (Split-Path -Leaf $Directory).ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
    $name = $name.Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { return 'docktopus-project' }
    if ($name -notmatch '^[a-z]') { return "project-$name" }
    return $name.Substring(0, [Math]::Min(63, $name.Length)).TrimEnd('-')
}

function Get-JsonProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DrupalCandidate([string]$Directory) {
    $candidates = @(
        @{ Composer = (Join-Path $Directory 'composer.json'); Root = $Directory; Relative = '.' },
        @{ Composer = (Join-Path $Directory 'drupal/composer.json'); Root = (Join-Path $Directory 'drupal'); Relative = 'drupal' },
        @{ Composer = (Join-Path $Directory 'web/composer.json'); Root = (Join-Path $Directory 'web'); Relative = 'web' },
        @{ Composer = (Join-Path $Directory 'docroot/composer.json'); Root = (Join-Path $Directory 'docroot'); Relative = 'docroot' }
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Composer -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $candidate.Composer -Raw | ConvertFrom-Json
        } catch {
            continue
        }

        $requirements = @{}
        foreach ($section in @('require', 'require-dev')) {
            $values = Get-JsonProperty $manifest $section
            if ($null -ne $values) {
                foreach ($property in $values.PSObject.Properties) {
                    $requirements[$property.Name] = [string]$property.Value
                }
            }
        }

        $versionConstraint = $requirements['drupal/core-recommended']
        if (-not $versionConstraint) { $versionConstraint = $requirements['drupal/core'] }
        $major = $null
        if ($versionConstraint -match '(?:\^|~|>=?|\*)?\s*(\d+)') { $major = [int]$Matches[1] }
        if (-not $major) {
            foreach ($relativeWebRoot in @('web', 'docroot', 'public_html')) {
                $versionFile = Join-Path $candidate.Root "$relativeWebRoot/core/lib/Drupal.php"
                if (Test-Path -LiteralPath $versionFile) {
                    $versionText = Get-Content -LiteralPath $versionFile -Raw
                    if ($versionText -match "const VERSION = '([0-9]+)") { $major = [int]$Matches[1]; break }
                }
            }
        }
        if (-not $major) { continue }

        $docroot = 'web'
        foreach ($path in @('web', 'docroot', 'public_html')) {
            if (Test-Path -LiteralPath (Join-Path $candidate.Root $path) -PathType Container) { $docroot = $path; break }
        }
        if ($candidate.Relative -ne '.') { $docroot = Join-Path $candidate.Relative $docroot }
        $phpVersion = '8.3'
        if ($requirements.ContainsKey('php') -and $requirements['php'] -match '(?:\^|~|>=?)?\s*(\d+\.\d+)') {
            $phpVersion = $Matches[1]
        }
        return [pscustomobject]@{
            ComposerPath = $candidate.Composer
            ComposerRelativePath = $candidate.Relative
            ComposerAtProjectRoot = ($candidate.Relative -eq '.')
            Docroot = $docroot.Replace('\', '/')
            DrupalMajor = $major
            ProjectType = "drupal$major"
            PhpVersion = $phpVersion
            IsComposerManaged = $true
        }
    }

    # Detect legacy/non-Composer Drupal source trees as well. They are not
    # Composer-managed, so report them and let the user choose a docroot.
    $sourceRoots = @(
        @{ Root = $Directory; Relative = '.' },
        @{ Root = (Join-Path $Directory 'drupal'); Relative = 'drupal' },
        @{ Root = (Join-Path $Directory 'web'); Relative = 'web' },
        @{ Root = (Join-Path $Directory 'docroot'); Relative = 'docroot' }
    )
    foreach ($source in $sourceRoots) {
        foreach ($webroot in @('web', 'docroot', 'public_html', '.')) {
            $drupalPhp = Join-Path $source.Root "$webroot/core/lib/Drupal.php"
            $drupal7 = Join-Path $source.Root "$webroot/includes/bootstrap.inc"
            if (Test-Path -LiteralPath $drupalPhp) {
                $versionText = Get-Content -LiteralPath $drupalPhp -Raw
                if ($versionText -match "const VERSION = '([0-9]+)") {
                    $major = [int]$Matches[1]
                    $docroot = if ($webroot -eq '.') { $source.Relative } else { Join-Path $source.Relative $webroot }
                    return [pscustomobject]@{
                        ComposerPath = $null
                        ComposerRelativePath = $null
                        ComposerAtProjectRoot = $false
                        Docroot = $docroot.Replace('\', '/')
                        DrupalMajor = $major
                        ProjectType = "drupal$major"
                        PhpVersion = '8.3'
                        IsComposerManaged = $false
                    }
                }
            } elseif ((Test-Path -LiteralPath $drupal7) -and $webroot -ne '.') {
                $docroot = Join-Path $source.Relative $webroot
                return [pscustomobject]@{
                    ComposerPath = $null
                    ComposerRelativePath = $null
                    ComposerAtProjectRoot = $false
                    Docroot = $docroot.Replace('\', '/')
                    DrupalMajor = 7
                    ProjectType = 'drupal7'
                    PhpVersion = '7.4'
                    IsComposerManaged = $false
                }
            }
        }
    }
    return $null
}

function Get-ComposeSummary([string]$Directory) {
    $files = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml') |
        ForEach-Object { Join-Path $Directory $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $services = [System.Collections.Generic.List[string]]::new()
    $ports = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file -Raw
        $insideServices = $false
        foreach ($line in ($text -split "`n")) {
            if ($line -match '^services:\s*$') { $insideServices = $true; continue }
            if ($insideServices) {
                if ($line -match '^\S' -and $line.Trim() -ne '') { $insideServices = $false; continue }
                if ($line -match '^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$') { $services.Add($Matches[1]) }
            }
        }
        foreach ($match in [regex]::Matches($text, '(?m)^\s*-\s*["'']?(\d{2,5}):\d{1,5}(?:/\w+)?["'']?')) {
            $ports.Add($match.Groups[1].Value)
        }
    }
    return [pscustomobject]@{
        Files = @($files | ForEach-Object { Split-Path -Leaf $_ })
        Services = @($services | Select-Object -Unique)
        HostPorts = @($ports | Select-Object -Unique)
    }
}

function Invoke-Ddev([string[]]$Arguments) {
    Push-Location -LiteralPath $projectPath
    try {
        $ErrorActionPreference = 'Continue'
        & ddev @Arguments
        if ($LASTEXITCODE -ne 0) { throw "ddev $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

function Read-YesNo([string]$Question, [bool]$Default = $false) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = Read-Host "$Question [$hint]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host 'Responde y o n.' -ForegroundColor Yellow
    }
}

function Install-Addons([string[]]$Repositories) {
    foreach ($repository in $Repositories) {
        Write-Host "`n>>> ddev add-on get $repository" -ForegroundColor Cyan
        Invoke-Ddev @('add-on', 'get', $repository)
    }
}

$projectPath = (Resolve-Path -LiteralPath $Path).Path
$projectName = Get-ProjectName $projectPath
$ddevConfig = Join-Path $projectPath '.ddev/config.yaml'
$drupal = Get-DrupalCandidate $projectPath
$compose = Get-ComposeSummary $projectPath
$rootPackage = Join-Path $projectPath 'package.json'
$hasNodeProject = (Test-Path (Join-Path $projectPath 'api')) -or (Test-Path (Join-Path $projectPath 'server'))
$hasFrontendProject = Test-Path (Join-Path $projectPath 'frontend_react/package.json') -PathType Leaf
if (Test-Path $rootPackage -PathType Leaf) {
    try {
        $package = Get-Content -LiteralPath $rootPackage -Raw | ConvertFrom-Json
        $scripts = Get-JsonProperty $package 'scripts'
        $dependencies = @{}
        foreach ($section in @('dependencies', 'devDependencies')) {
            $values = Get-JsonProperty $package $section
            if ($values) {
                foreach ($property in $values.PSObject.Properties) { $dependencies[$property.Name] = $property.Value }
            }
        }
        $devScript = Get-JsonProperty $scripts 'dev'
        $startScript = Get-JsonProperty $scripts 'start'
        if (($devScript -match 'vite|next') -or $dependencies.ContainsKey('react') -or $dependencies.ContainsKey('next')) { $hasFrontendProject = $true }
        if (($startScript -match 'node|tsx|ts-node') -or $dependencies.ContainsKey('express')) { $hasNodeProject = $true }
    } catch { }
}

$result = [pscustomobject]@{
    Path = $projectPath
    ProjectName = $projectName
    AlreadyDdev = Test-Path -LiteralPath $ddevConfig -PathType Leaf
    Drupal = $drupal
    Compose = $compose
    HasRootPackageJson = Test-Path -LiteralPath $rootPackage -PathType Leaf
    HasExistingNodeOrFrontend = $hasNodeProject
    SuggestedType = if ($drupal -and ($drupal.ComposerAtProjectRoot -or -not $drupal.IsComposerManaged)) { $drupal.ProjectType } else { 'generic' }
    SuggestedDocroot = if ($drupal -and ($drupal.ComposerAtProjectRoot -or -not $drupal.IsComposerManaged)) { $drupal.Docroot } else { '.' }
    SuggestedPhpVersion = if ($drupal) { $drupal.PhpVersion } else { '8.3' }
}
$projectType = $result.SuggestedType
$docroot = $result.SuggestedDocroot
$phpVersion = $result.SuggestedPhpVersion
if ($result.AlreadyDdev) {
    $existingConfig = Get-Content -LiteralPath $ddevConfig -Raw
    if ($existingConfig -match '(?m)^type:\s*["'']?([^\s"'']+)') { $projectType = $Matches[1] }
    if ($existingConfig -match '(?m)^docroot:\s*["'']?([^\r\n"'']*)') { $docroot = $Matches[1].Trim() }
    if ($existingConfig -match '(?m)^php_version:\s*["'']?([^\s"'']+)') { $phpVersion = $Matches[1] }
}
$result.SuggestedType = $projectType
$result.SuggestedDocroot = $docroot
$result.SuggestedPhpVersion = $phpVersion

if ($AnalyzeOnly) {
    $result | ConvertTo-Json -Depth 6
    exit 0
}

Write-Host ''
Write-Host 'DDEV Docktopus project conversion wizard' -ForegroundColor Cyan
Write-Host "Project: $($result.Path)"
Write-Host "Name:    $($result.ProjectName)"
if ($result.AlreadyDdev) { Write-Host 'DDEV:    already configured (.ddev/config.yaml found)' -ForegroundColor Green }
else { Write-Host 'DDEV:    not configured yet' -ForegroundColor Yellow }
if ($drupal) {
    $management = if ($drupal.IsComposerManaged) { 'Composer' } else { 'legacy/non-Composer source' }
    Write-Host "Drupal:  $management project, Drupal $($drupal.DrupalMajor), docroot '$($drupal.Docroot)'"
    if (-not $drupal.ComposerAtProjectRoot) {
        Write-Host "Composer is under '$($drupal.ComposerRelativePath)', not at the DDEV project root. Recommended: rerun the wizard with -Path pointing to that Drupal directory." -ForegroundColor Yellow
    }
} else {
    Write-Host 'Drupal:  no Composer-managed Drupal project detected at the root or common subdirectories' -ForegroundColor Yellow
}
if ($compose.Files.Count -gt 0) {
    Write-Host "Compose: $($compose.Files -join ', ')"
    if ($compose.Services.Count -gt 0) { Write-Host "Services: $($compose.Services -join ', ')" }
    if ($compose.HostPorts.Count -gt 0) { Write-Host "Published host ports: $($compose.HostPorts -join ', ')" }
    $conflictingPorts = @($compose.HostPorts | Where-Object { $_ -in @('10389', '15432') })
    if ($conflictingPorts.Count -gt 0) {
        Write-Host "Potential Docktopus host-port conflicts detected: $($conflictingPorts -join ', '). Resolve before starting the matching add-ons." -ForegroundColor Red
    }
    Write-Host 'The wizard will not edit, stop, import, or delete Compose files, containers, or volumes.' -ForegroundColor Yellow
}
if ($hasNodeProject) {
    Write-Host 'Existing api/server or frontend dev scripts detected; Node/React Docktopus add-ons are opt-in to avoid duplicate scaffolds.' -ForegroundColor Yellow
}
Write-Host ''

if (-not $result.AlreadyDdev) {
    $answer = Read-Host "DDEV project type [$projectType] (Enter accepts; use 'generic' for Compose-managed Drupal)"
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $projectType = $answer.Trim() }
    $answer = Read-Host "DDEV docroot [$docroot]"
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $docroot = $answer.Trim() }
    if ($projectType -eq 'generic') { $phpVersion = '8.3' }
    $database = Read-Host 'DDEV main database [mariadb:10.11] (use postgres:16 or another supported type:version if intended)'
    if ([string]::IsNullOrWhiteSpace($database)) { $database = 'mariadb:10.11' }

    Write-Host "`nWill run: ddev config --project-name=$projectName --project-type=$projectType --docroot=$docroot --php-version=$phpVersion --database=$database"
    if (-not (Read-YesNo 'Create/update DDEV configuration?' $true)) { Write-Host 'Cancelled; no files changed.'; exit 0 }
    Invoke-Ddev @('config', "--project-name=$projectName", "--project-type=$projectType", "--docroot=$docroot", "--php-version=$phpVersion", "--database=$database")
}

if (-not (Read-YesNo 'Start this DDEV project now?' $true)) {
    Write-Host 'DDEV is configured. Start it with ddev start, then rerun this wizard to install add-ons.'
    exit 0
}
Invoke-Ddev @('start', '-y')

Write-Host ''
Write-Host 'Installation modes:'
Write-Host '  1. Full meta add-on (all Docktopus services, including Node and React)'
Write-Host '  2. Curated add-ons (default core services; Node/React asked separately)'
Write-Host '  3. DDEV configuration only'
$mode = Read-Host 'Choose 1, 2, or 3 [2]'
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = '2' }
if ($mode -notin @('1', '2', '3')) { throw "Invalid installation mode '$mode'." }

if ($mode -eq '1') {
    if ($hasNodeProject) {
        Write-Host 'WARNING: the full meta installs Node + React and may scaffold api/ or frontend_react/ alongside existing app code.' -ForegroundColor Yellow
    }
    if (Read-YesNo 'Install the full ddev-docktopus meta add-on?' $false) {
        Install-Addons @('juancalero/ddev-docktopus')
        if ($projectType -eq 'generic' -or -not $drupal -or -not $drupal.ComposerAtProjectRoot -or -not $drupal.IsComposerManaged) {
            New-Item -ItemType Directory -Force -Path (Join-Path $projectPath '.ddev/docktopus-drupal') | Out-Null
            New-Item -ItemType File -Force -Path (Join-Path $projectPath '.ddev/docktopus-drupal/.skip') | Out-Null
            Write-Host 'Disabled the Drupal empty-project bootstrap (.ddev/docktopus-drupal/.skip).'
        }
    }
} elseif ($mode -eq '2') {
    $repositories = @(
        'ddev/ddev-adminer',
        'julienloizelet/ddev-portainer',
        'juancalero/ddev-docktopus-config',
        'juancalero/ddev-docktopus-ldap',
        'juancalero/ddev-docktopus-phpldapadmin',
        'juancalero/ddev-docktopus-postgres',
        'trebormc/ddev-opencode'
    )
    if (Read-YesNo 'Add the Docktopus Node API service?' (-not $hasNodeProject)) { $repositories += 'juancalero/ddev-docktopus-node-api' }
    if (Read-YesNo 'Add the separate Docktopus React/Vite service?' (-not $hasFrontendProject)) { $repositories += 'juancalero/ddev-docktopus-react' }
    $canUseDrupalAddon = ($null -ne $drupal) -and $drupal.ComposerAtProjectRoot -and $drupal.IsComposerManaged
    if (Read-YesNo 'Add the Drupal bootstrap add-on?' $canUseDrupalAddon) { $repositories += 'juancalero/ddev-docktopus-drupal' }
    Install-Addons $repositories
    if (-not $canUseDrupalAddon) {
        New-Item -ItemType Directory -Force -Path (Join-Path $projectPath '.ddev/docktopus-drupal') | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $projectPath '.ddev/docktopus-drupal/.skip') | Out-Null
        Write-Host 'Disabled the Drupal empty-project bootstrap because no root Composer Drupal project was detected.'
    }
} else {
    Write-Host 'Skipped Docktopus add-ons.'
}

if ($mode -ne '3' -and (Read-YesNo 'Restart DDEV now to apply the add-ons?' $true)) {
    Invoke-Ddev @('restart', '-y')
} elseif ($mode -ne '3') {
    Write-Host 'Add-ons are installed. Run ddev restart when ready.'
}

Write-Host "`nConversion wizard finished. Run 'ddev describe' to review service status and URLs." -ForegroundColor Green
if ($compose.Files.Count -gt 0) {
    Write-Host 'Existing Docker Compose configuration and volumes were left untouched. Manage those services separately.' -ForegroundColor Yellow
}
