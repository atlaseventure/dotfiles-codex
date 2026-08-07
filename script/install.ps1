[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $repoRoot 'skills'
$globalAgentsSource = Join-Path $repoRoot 'agents\AGENTS.md'
$codexDefaultAgentSource = Join-Path $repoRoot 'codex\agents\default.toml'

if ([string]::IsNullOrWhiteSpace($HOME)) {
    throw 'HOME 未设置'
}

if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw "Skill 源目录不存在：$sourceDir"
}

if (-not (Test-Path -LiteralPath $globalAgentsSource -PathType Leaf)) {
    throw "共享全局提示词源文件不存在：$globalAgentsSource"
}

if (-not (Test-Path -LiteralPath $codexDefaultAgentSource -PathType Leaf)) {
    throw "Codex 默认子代理源文件不存在：$codexDefaultAgentSource"
}

$sourceDir = (Resolve-Path -LiteralPath $sourceDir).Path
$globalAgentsSource = (Resolve-Path -LiteralPath $globalAgentsSource).Path
$targetDir = Join-Path $HOME '.agents\skills'
$codexTargetDir = Join-Path $HOME '.codex'
$codexAgentsTarget = Join-Path $codexTargetDir 'AGENTS.md'
$codexDefaultAgentTarget = Join-Path $codexTargetDir 'agents\default.toml'
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$isWindowsPlatform = $env:OS -eq 'Windows_NT'
$platform = if ($isWindowsPlatform) { 'windows' } else { 'unix' }
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

function Install-GlobalAgentsFile {
    $existing = Get-Item -LiteralPath $codexAgentsTarget -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $unchanged = -not (Test-IsLinkLike -Item $existing) -and
            -not $existing.PSIsContainer -and
            (Get-FileHash -LiteralPath $globalAgentsSource -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $codexAgentsTarget -Algorithm SHA256).Hash

        if ($unchanged) {
            Write-Output "共享全局提示词已是最新状态：$codexAgentsTarget"
            return
        }

        Backup-Item -Path $codexAgentsTarget
    }

    Copy-Item -LiteralPath $globalAgentsSource -Destination $codexAgentsTarget
    Write-Output "已复制 $codexAgentsTarget <- $globalAgentsSource"
}

function Install-CodexDefaultAgent {
    $targetParent = Split-Path -Parent $codexDefaultAgentTarget
    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null

    $existing = Get-Item -LiteralPath $codexDefaultAgentTarget -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $unchanged = -not (Test-IsLinkLike -Item $existing) -and
            -not $existing.PSIsContainer -and
            (Get-FileHash -LiteralPath $codexDefaultAgentSource -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $codexDefaultAgentTarget -Algorithm SHA256).Hash

        if ($unchanged) {
            Write-Output "Codex 默认子代理已是最新状态：$codexDefaultAgentTarget"
            return
        }

        Backup-Item -Path $codexDefaultAgentTarget
    }

    Copy-Item -LiteralPath $codexDefaultAgentSource -Destination $codexDefaultAgentTarget
    Write-Output "已复制 $codexDefaultAgentTarget <- $codexDefaultAgentSource"
}

function Test-SkillSupportsPlatform {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Platform
    )

    $metadataPath = Join-Path $Source.FullName 'agents\openai.yaml'
    $pattern = '^\s+' + [regex]::Escape($Platform) + ':\s+(true|false)\s*$'
    $inPlatform = $false

    foreach ($line in Get-Content -LiteralPath $metadataPath) {
        if ($line -eq 'platform:') {
            $inPlatform = $true
            continue
        }
        if ($inPlatform -and $line -notmatch '^\s') {
            break
        }
        if ($inPlatform -and $line -match $pattern) {
            return $Matches[1] -eq 'true'
        }
    }

    throw "Skill 平台元数据缺失：$metadataPath"
}

function Get-InstallableSkill {
    return @(
        Get-ChildItem -LiteralPath $sourceDir -Directory |
            Where-Object { Test-SkillSupportsPlatform -Source $_ -Platform $platform }
    )
}

function Test-Installation {
    $consistent = $true

    foreach ($source in Get-InstallableSkill) {
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
        (Get-FileHash -LiteralPath $globalAgentsSource -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $codexAgentsTarget -Algorithm SHA256).Hash

    if ($agentsCurrent) {
        Write-Information "共享全局提示词状态一致：$codexAgentsTarget" -InformationAction Continue
    }
    else {
        Write-Warning "共享全局提示词状态不一致：$codexAgentsTarget"
        $consistent = $false
    }

    $defaultAgentExisting = Get-Item -LiteralPath $codexDefaultAgentTarget -Force -ErrorAction SilentlyContinue
    $defaultAgentCurrent = $null -ne $defaultAgentExisting -and
        -not (Test-IsLinkLike -Item $defaultAgentExisting) -and
        -not $defaultAgentExisting.PSIsContainer -and
        (Get-FileHash -LiteralPath $codexDefaultAgentSource -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $codexDefaultAgentTarget -Algorithm SHA256).Hash

    if ($defaultAgentCurrent) {
        Write-Information "Codex 默认子代理状态一致：$codexDefaultAgentTarget" -InformationAction Continue
    }
    else {
        Write-Warning "Codex 默认子代理状态不一致：$codexDefaultAgentTarget"
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

foreach ($source in Get-InstallableSkill) {
    Install-Skill -Source $source -Destination (Join-Path $targetDir $source.Name)
}

Remove-StaleManagedLink
Install-GlobalAgentsFile
Install-CodexDefaultAgent
