<#
.SYNOPSIS
  Declarative Desired State Configuration (DSC) engine for Scoop.
  תומך במניפסטים בפורמט JSON ו-YAML, עם תיאורי חבילות והרצה אידמפוטנטית.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Manifest = "$PSScriptRoot/../scoop.manifest.yaml",

    [switch]$UpdateBuckets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 1. וידוא התקנת Scoop במערכת
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "[Scoop-Config] Scoop אינו מותקן. מתקין את Scoop..." -ForegroundColor Cyan
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    $env:SCOOP_ALLOW_ADMIN = 1
    Invoke-RestMethod -Uri "https://get.scoop.sh" | Invoke-Expression
    $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "User") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "Machine")
}

# 2. טעינת קובץ המניפסט (תמיכה ב-JSON וב-YAML, מקומית או מרחוק)
$tempFile = $null
try {
    if ($Manifest -match '^https?://') {
        $ext = [System.IO.Path]::GetExtension(($Manifest -split '\?')[0])
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scoop-manifest-" + [Guid]::NewGuid().ToString("N") + $ext)
        Invoke-RestMethod -Uri $Manifest -OutFile $tempFile
        $targetPath = $tempFile
    } elseif (Test-Path -LiteralPath $Manifest) {
        $targetPath = (Resolve-Path -LiteralPath $Manifest).Path
    } else {
        throw "מניפסט התצורה לא אותר בנתיב: $Manifest"
    }

    $rawContent = Get-Content -LiteralPath $targetPath -Raw -Encoding utf8
    $isYaml = $targetPath -match '\.(ya?ml)$'

    $config = if ($isYaml) {
        # וידוא קיום כלי yq לפענוח YAML
        if (-not (Get-Command yq -ErrorAction SilentlyContinue)) {
            Write-Host "[Scoop-Config] מתקין yq לפענוח קובצי YAML..." -ForegroundColor Cyan
            scoop install yq 2>$null
        }
        if (Get-Command yq -ErrorAction SilentlyContinue) {
            (yq eval -o=json $targetPath) | ConvertFrom-Json
        } else {
            throw "לא ניתן לפענח קובץ YAML ללא yq. אנא ודא התקנת yq או העבר מניפסט בפורמט JSON."
        }
    } else {
        $rawContent | ConvertFrom-Json
    }
}
finally {
    if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# 3. סנכרון באקטים (Buckets)
$installedBuckets = @(scoop bucket list | ForEach-Object { ($_ -split '\s+')[0] })
if ($config.PSObject.Properties['buckets'] -and $config.buckets) {
    foreach ($b in $config.buckets) {
        $bName = if ($b -is [string]) { $b } else { $b.name }
        $bSource = if ($b -is [string]) { $null } elseif ($b.PSObject.Properties['source']) { $b.source } else { $null }

        if ($bName -notin $installedBuckets) {
            Write-Host "[Scoop-Config] מוסיף באקט: $bName..." -ForegroundColor Cyan
            if ($bSource) { scoop bucket add $bName $bSource 2>$null } else { scoop bucket add $bName 2>$null }
        }
    }
}

if ($UpdateBuckets) {
    Write-Host "[Scoop-Config] מעדכן את מאגרי הבאקטים..." -ForegroundColor Cyan
    scoop update
}

# 4. החלת הגדרות תצורה (scoop config)
if ($config.PSObject.Properties['config'] -and $config.config) {
    foreach ($prop in $config.config.PSObject.Properties) {
        Write-Host "[Scoop-Config] מגדיר תצורה: $($prop.Name) = $($prop.Value)..." -ForegroundColor DarkCyan
        scoop config $prop.Name $prop.Value | Out-Null
    }
}

# 5. זיהוי חבילות והתקנת החסרות בלבד (תמיכה במחרוזות או באובייקטים עם תיאור)
$installedApps = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
@(scoop list | ForEach-Object { ($_ -split '\s+')[0] }) | ForEach-Object { $null = $installedApps.Add($_) }

$missingApps = [System.Collections.Generic.List[string]]::new()
$appDescriptions = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)

if ($config.PSObject.Properties['apps'] -and $config.apps) {
    foreach ($app in $config.apps) {
        $appId = if ($app -is [string]) { $app } elseif ($app.PSObject.Properties['id']) { $app.id } else { $app.name }
        $appDesc = if ($app -is [string]) { "" } elseif ($app.PSObject.Properties['description']) { $app.description } else { "" }

        $cleanName = ($appId -split '/')[-1]
        if (-not $installedApps.Contains($cleanName)) {
            $missingApps.Add($appId)
            if ($appDesc) { $appDescriptions[$appId] = $appDesc }
        }
    }
}

if ($missingApps.Count -gt 0) {
    Write-Host "[Scoop-Config] נמצאו $($missingApps.Count) חבילות להתקנה:" -ForegroundColor Yellow
    foreach ($appId in $missingApps) {
        $desc = if ($appDescriptions.ContainsKey($appId)) { " ($($appDescriptions[$appId]))" } else { "" }
        Write-Host "  * $appId$desc" -ForegroundColor Yellow
    }

    scoop install @($missingApps)
    scoop cache rm *
    Write-Host "[Scoop-Config] כל החבילות הותקנו בהצלחה." -ForegroundColor Green
} else {
    Write-Host "[Scoop-Config] המערכת מעודכנת. כל החבילות המוגדרות במניפסט כבר מותקנות." -ForegroundColor Green
}
