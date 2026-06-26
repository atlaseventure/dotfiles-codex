Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$sourceDir = Join-Path $repoRoot 'skills'
$codexAgentsSource = Join-Path $repoRoot 'codex\AGENTS.md'

if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    Write-Error "skills source directory not found: $sourceDir"
}

if (-not (Test-Path -LiteralPath $codexAgentsSource -PathType Leaf)) {
    Write-Error "Codex AGENTS.md source file not found: $codexAgentsSource"
}

$sourceDir = (Resolve-Path -LiteralPath $sourceDir).Path
$codexAgentsSource = (Resolve-Path -LiteralPath $codexAgentsSource).Path
$targetDir = Join-Path $HOME '.agents\skills'
$codexTargetDir = Join-Path $HOME '.codex'
$codexAgentsTarget = Join-Path $codexTargetDir 'AGENTS.md'
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'

if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $codexTargetDir -PathType Container)) {
    New-Item -ItemType Directory -Path $codexTargetDir -Force | Out-Null
}

function Test-IsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-UniqueBackupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $candidate = "$Path.bak.$timestamp"
    $suffix = 1

    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$Path.bak.$timestamp.$suffix"
        $suffix += 1
    }

    return $candidate
}

foreach ($src in Get-ChildItem -LiteralPath $sourceDir -Directory) {
    $dest = Join-Path $targetDir $src.Name
    $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue

    if ($null -ne $existing) {
        if (Test-IsLinkLike -Item $existing) {
            Remove-Item -LiteralPath $dest -Force
        }
        else {
            $backup = "$dest.bak.$timestamp"
            Move-Item -LiteralPath $dest -Destination $backup
            Write-Host "backed up $dest -> $backup"
        }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $dest -Target $src.FullName | Out-Null
    }
    catch {
        $message = "failed to create symbolic link $dest -> $($src.FullName). Enable Developer Mode or run PowerShell as Administrator. $($_.Exception.Message)"
        throw $message
    }

    Write-Host "linked $dest -> $($src.FullName)"
}

$existingCodexAgents = Get-Item -LiteralPath $codexAgentsTarget -Force -ErrorAction SilentlyContinue

if ($null -ne $existingCodexAgents) {
    $backup = Get-UniqueBackupPath -Path $codexAgentsTarget
    Move-Item -LiteralPath $codexAgentsTarget -Destination $backup
    Write-Host "backed up $codexAgentsTarget -> $backup"
}

Copy-Item -LiteralPath $codexAgentsSource -Destination $codexAgentsTarget
Write-Host "copied $codexAgentsTarget <- $codexAgentsSource"
