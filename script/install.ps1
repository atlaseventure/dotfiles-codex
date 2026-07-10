[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $repoRoot 'skills'
$codexAgentsSource = Join-Path $repoRoot 'codex\AGENTS.md'

if ([string]::IsNullOrWhiteSpace($HOME)) {
    throw 'HOME 未设置'
}

if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw "Skill 源目录不存在：$sourceDir"
}

if (-not (Test-Path -LiteralPath $codexAgentsSource -PathType Leaf)) {
    throw "Codex AGENTS.md 源文件不存在：$codexAgentsSource"
}

$sourceDir = (Resolve-Path -LiteralPath $sourceDir).Path
$codexAgentsSource = (Resolve-Path -LiteralPath $codexAgentsSource).Path
$targetDir = Join-Path $HOME '.agents\skills'
$codexTargetDir = Join-Path $HOME '.codex'
$codexAgentsTarget = Join-Path $codexTargetDir 'AGENTS.md'
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$isWindowsPlatform = $env:OS -eq 'Windows_NT'
$pathComparison = if ($isWindowsPlatform) {
    [System.StringComparison]::OrdinalIgnoreCase
}
else {
    [System.StringComparison]::Ordinal
}

function Test-IsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-NormalizedLinkTarget {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item,

        [Parameter(Mandatory = $true)]
        [string]$LinkPath
    )

    $target = @($Item.Target)[0]
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $LinkPath) $target
    }

    return [System.IO.Path]::GetFullPath($target)
}

function Get-UniqueBackupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $candidate = "$Path.bak.$timestamp"
    $suffix = 1

    while ($null -ne (Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue)) {
        $candidate = "$Path.bak.$timestamp.$suffix"
        $suffix += 1
    }

    return $candidate
}

function Backup-Item {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $backup = Get-UniqueBackupPath -Path $Path
    Move-Item -LiteralPath $Path -Destination $backup
    Write-Output "已备份 $Path -> $backup"
}

function Install-Skill {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if (Test-IsLinkLike -Item $existing) {
            $currentTarget = Get-NormalizedLinkTarget -Item $existing -LinkPath $Destination
            if ($null -ne $currentTarget -and $currentTarget.Equals($Source.FullName, $pathComparison)) {
                Write-Output "Skill 已是最新状态：$Destination"
                return
            }
        }

        Backup-Item -Path $Destination
    }

    try {
        New-Item -ItemType SymbolicLink -Path $Destination -Target $Source.FullName | Out-Null
    }
    catch {
        throw "创建软链接失败：$Destination -> $($Source.FullName)。请启用开发者模式或使用管理员权限运行 PowerShell。$($_.Exception.Message)"
    }

    Write-Output "已链接 $Destination -> $($Source.FullName)"
}

function Remove-StaleManagedLink {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $sourcePrefix = $sourceDir.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    foreach ($item in Get-ChildItem -LiteralPath $targetDir -Force) {
        if (-not (Test-IsLinkLike -Item $item)) {
            continue
        }

        $linkTarget = Get-NormalizedLinkTarget -Item $item -LinkPath $item.FullName
        if (
            $null -ne $linkTarget -and
            $linkTarget.StartsWith($sourcePrefix, $pathComparison) -and
            -not (Test-Path -LiteralPath $linkTarget)
        ) {
            if ($PSCmdlet.ShouldProcess($item.FullName, '移除陈旧 Skill 链接')) {
                Remove-Item -LiteralPath $item.FullName -Force
                Write-Output "已移除陈旧 Skill 链接：$($item.FullName)"
            }
        }
    }
}

function Install-CodexAgentFile {
    $existing = Get-Item -LiteralPath $codexAgentsTarget -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $unchanged = -not (Test-IsLinkLike -Item $existing) -and
            -not $existing.PSIsContainer -and
            (Get-FileHash -LiteralPath $codexAgentsSource -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $codexAgentsTarget -Algorithm SHA256).Hash

        if ($unchanged) {
            Write-Output "Codex AGENTS.md 已是最新状态：$codexAgentsTarget"
            return
        }

        Backup-Item -Path $codexAgentsTarget
    }

    Copy-Item -LiteralPath $codexAgentsSource -Destination $codexAgentsTarget
    Write-Output "已复制 $codexAgentsTarget <- $codexAgentsSource"
}

function Test-Installation {
    $consistent = $true

    foreach ($source in Get-ChildItem -LiteralPath $sourceDir -Directory) {
        $destination = Join-Path $targetDir $source.Name
        $existing = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        $current = $false

        if ($null -ne $existing -and (Test-IsLinkLike -Item $existing)) {
            $currentTarget = Get-NormalizedLinkTarget -Item $existing -LinkPath $destination
            $current = $null -ne $currentTarget -and
                $currentTarget.Equals($source.FullName, $pathComparison)
        }

        if ($current) {
            Write-Information "Skill 状态一致：$destination" -InformationAction Continue
        }
        else {
            Write-Warning "Skill 状态不一致：$destination 应链接到 $($source.FullName)"
            $consistent = $false
        }
    }

    if (Test-Path -LiteralPath $targetDir -PathType Container) {
        $sourcePrefix = $sourceDir.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar

        foreach ($item in Get-ChildItem -LiteralPath $targetDir -Force) {
            if (-not (Test-IsLinkLike -Item $item)) {
                continue
            }

            $linkTarget = Get-NormalizedLinkTarget -Item $item -LinkPath $item.FullName
            if (
                $null -ne $linkTarget -and
                $linkTarget.StartsWith($sourcePrefix, $pathComparison) -and
                -not (Test-Path -LiteralPath $linkTarget)
            ) {
                Write-Warning "存在陈旧 Skill 链接：$($item.FullName) -> $linkTarget"
                $consistent = $false
            }
        }
    }

    $agentsExisting = Get-Item -LiteralPath $codexAgentsTarget -Force -ErrorAction SilentlyContinue
    $agentsCurrent = $null -ne $agentsExisting -and
        -not (Test-IsLinkLike -Item $agentsExisting) -and
        -not $agentsExisting.PSIsContainer -and
        (Get-FileHash -LiteralPath $codexAgentsSource -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $codexAgentsTarget -Algorithm SHA256).Hash

    if ($agentsCurrent) {
        Write-Information "Codex AGENTS.md 状态一致：$codexAgentsTarget" -InformationAction Continue
    }
    else {
        Write-Warning "Codex AGENTS.md 状态不一致：$codexAgentsTarget"
        $consistent = $false
    }

    if ($consistent) {
        Write-Information '安装状态一致' -InformationAction Continue
    }
    else {
        Write-Warning "安装状态不一致，请运行 $PSCommandPath 完成收敛"
    }

    return $consistent
}

if ($Check) {
    if (Test-Installation) {
        exit 0
    }
    exit 1
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
New-Item -ItemType Directory -Path $codexTargetDir -Force | Out-Null

foreach ($source in Get-ChildItem -LiteralPath $sourceDir -Directory) {
    Install-Skill -Source $source -Destination (Join-Path $targetDir $source.Name)
}

Remove-StaleManagedLink
Install-CodexAgentFile
