$ErrorActionPreference = 'Stop'
$wizard = Join-Path (Split-Path -Parent $PSScriptRoot) 'wizard/Convert-Docktopus.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "docktopus-wizard-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Analyze([string]$Path) {
    $json = & $wizard -Path $Path -AnalyzeOnly | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Wizard analysis failed for '$Path'" }
    return $json | ConvertFrom-Json
}

try {
    # Compose-managed Drupal with a separate Vite/Node app. Analysis must be
    # read-only and recommend generic DDEV, no Drupal detection, and avoid
    # suggesting duplicate Docktopus app services.
    $composeProject = Join-Path $tempRoot 'compose-project'
    New-Item -ItemType Directory -Force -Path $composeProject | Out-Null
    @'
services:
  drupal:
    ports:
      - "8081:80"
  database:
    image: mariadb:11
'@ | Set-Content -Encoding utf8 (Join-Path $composeProject 'docker-compose.yml')
    '{"scripts":{"dev":"vite"},"dependencies":{"react":"^19.0.0"}}' | Set-Content -Encoding utf8 (Join-Path $composeProject 'package.json')
    New-Item -ItemType Directory -Force -Path (Join-Path $composeProject 'api') | Out-Null

    $composeResult = Analyze $composeProject
    Assert ($composeResult.SuggestedType -eq 'generic') 'Compose Drupal without Composer should recommend generic DDEV.'
    Assert ($null -eq $composeResult.Drupal) 'Compose-managed Drupal should not be mistaken for Composer Drupal.'
    Assert ($composeResult.HasExistingNodeOrFrontend) 'Existing API/Vite app should be detected.'
    Assert ($composeResult.Compose.Services -contains 'drupal') 'Compose Drupal service should be detected.'
    Assert ($composeResult.Compose.HostPorts -contains '8081') 'Published Compose port should be detected.'
    Assert (-not (Test-Path (Join-Path $composeProject '.ddev'))) 'AnalyzeOnly must not create .ddev.'

    # Composer Drupal 10 in a standard project root.
    $drupalProject = Join-Path $tempRoot 'drupal-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $drupalProject 'web') | Out-Null
    '{"require":{"drupal/core-recommended":"^10.3","php":"^8.2"}}' | Set-Content -Encoding utf8 (Join-Path $drupalProject 'composer.json')
    $drupalResult = Analyze $drupalProject
    Assert ($drupalResult.SuggestedType -eq 'drupal10') 'Drupal major version should be detected.'
    Assert ($drupalResult.SuggestedDocroot -eq 'web') 'Standard Drupal web docroot should be detected.'
    Assert ($drupalResult.SuggestedPhpVersion -eq '8.2') 'PHP constraint should be detected.'

    # Nested Composer Drupal should not be configured from its parent root.
    $nestedProject = Join-Path $tempRoot 'nested-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $nestedProject 'drupal/web') | Out-Null
    '{"require":{"drupal/core-recommended":"^11.0"}}' | Set-Content -Encoding utf8 (Join-Path $nestedProject 'drupal/composer.json')
    $nestedResult = Analyze $nestedProject
    Assert ($nestedResult.Drupal.DrupalMajor -eq 11) 'Nested Drupal major version should be detected.'
    Assert (-not $nestedResult.Drupal.ComposerAtProjectRoot) 'Nested Composer root should be marked as nested.'
    Assert ($nestedResult.SuggestedType -eq 'generic') 'Nested Drupal must not default to Drupal project type at the parent.'

    # Legacy/non-Composer Drupal should be detected without being mistaken
    # for a Composer site (the Drupal bootstrap add-on is not applicable).
    $legacyProject = Join-Path $tempRoot 'legacy-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyProject 'drupal/web/core/lib') | Out-Null
    "<?php const VERSION = '9.5.11';" | Set-Content -Encoding utf8 (Join-Path $legacyProject 'drupal/web/core/lib/Drupal.php')
    $legacyResult = Analyze $legacyProject
    Assert ($legacyResult.Drupal.DrupalMajor -eq 9) 'Legacy Drupal source version should be detected.'
    Assert (-not $legacyResult.Drupal.IsComposerManaged) 'Legacy source should be marked non-Composer.'
    Assert ($legacyResult.SuggestedDocroot -eq 'drupal/web') 'Legacy nested docroot should be detected.'

    Write-Host 'All conversion wizard tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
