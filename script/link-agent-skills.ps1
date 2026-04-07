Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$sourceDir = Join-Path $repoRoot 'skills'

if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    Write-Error "skills source directory not found: $sourceDir"
}

$sourceDir = (Resolve-Path -LiteralPath $sourceDir).Path
$targetDir = Join-Path $HOME '.agents\skills'
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'

if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

function Test-IsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
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
