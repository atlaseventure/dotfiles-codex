[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $repoRoot 'skills'

if ([string]::IsNullOrWhiteSpace($HOME)) {
    throw 'HOME 未设置'
}

if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw "Skill 源目录不存在：$sourceDir"
}

$sourceDir = (Resolve-Path -LiteralPath $sourceDir).Path
$skillTargetDirs = @(
    (Join-Path $HOME '.agents\skills')
    (Join-Path $HOME '.claude\skills')
)
$globalAgentsFiles = @(
    @{
        Source = Join-Path $repoRoot 'codex\AGENTS.md'
        Destination = Join-Path $HOME '.codex\AGENTS.md'
    }
    @{
        Source = Join-Path $repoRoot 'claude\CLAUDE.md'
        Destination = Join-Path $HOME '.claude\CLAUDE.md'
    }
)
$settingsSource = Join-Path $repoRoot 'claude\settings.json'
$settingsDestination = Join-Path $HOME '.claude\settings.json'

foreach ($file in $globalAgentsFiles) {
    if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
        throw "全局提示词源文件不存在：$($file.Source)"
    }
    $file.Source = (Resolve-Path -LiteralPath $file.Source).Path
}

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

    if ($NoBackup) {
        Remove-Item -LiteralPath $Path
        Write-Output "已直接移除冲突项：$Path"
        return
    }

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
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )

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
                Remove-Item -LiteralPath $item.FullName
                Write-Output "已移除陈旧 Skill 链接：$($item.FullName)"
            }
        }
    }
}

function Install-GlobalAgentsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $unchanged = -not (Test-IsLinkLike -Item $existing) -and
            -not $existing.PSIsContainer -and
            (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash

        if ($unchanged) {
            Write-Output "全局提示词已是最新状态：$Destination"
            return
        }

        Backup-Item -Path $Destination
    }

    Copy-Item -LiteralPath $Source -Destination $Destination
    Write-Output "已复制 $Destination <- $Source"
}

function Read-JsonObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    }
    catch {
        throw "JSON 配置无效：$Path。$($_.Exception.Message)"
    }

    if ($value -isnot [System.Collections.IDictionary]) {
        throw "JSON 配置根节点必须是对象：$Path"
    }

    return $value
}

function Merge-JsonObject {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Target,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ref]$Changed
    )

    foreach ($key in $Source.Keys) {
        $propertyPath = "$Path.$key"
        if (-not $Target.Contains($key)) {
            $Target[$key] = $Source[$key]
            $Changed.Value = $true
            continue
        }

        $sourceValue = $Source[$key]
        $targetValue = $Target[$key]
        if ($sourceValue -is [System.Collections.IDictionary] -and
            $targetValue -is [System.Collections.IDictionary]) {
            Merge-JsonObject -Target $targetValue -Source $sourceValue -Path $propertyPath -Changed $Changed
        }
        elseif (-not (Test-JsonValueEqual -Left $targetValue -Right $sourceValue)) {
            $Target[$key] = $sourceValue
            $Changed.Value = $true
        }
    }
}

function Test-JsonValueEqual {
    param(
        [Parameter(Mandatory = $false)]
        $Left,

        [Parameter(Mandatory = $false)]
        $Right
    )

    $leftJson = ConvertTo-Json -InputObject $Left -Compress -Depth 100
    $rightJson = ConvertTo-Json -InputObject $Right -Compress -Depth 100
    return $leftJson -eq $rightJson
}

function Test-JsonObjectContains {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Target,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Source
    )

    foreach ($key in $Source.Keys) {
        if (-not $Target.Contains($key)) {
            return $false
        }

        $sourceValue = $Source[$key]
        $targetValue = $Target[$key]
        if ($sourceValue -is [System.Collections.IDictionary]) {
            if ($targetValue -isnot [System.Collections.IDictionary] -or
                -not (Test-JsonObjectContains -Target $targetValue -Source $sourceValue)) {
                return $false
            }
        }
        elseif (-not (Test-JsonValueEqual -Left $targetValue -Right $sourceValue)) {
            return $false
        }
    }

    return $true
}

function Install-ClaudeSettings {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Source
    )

    $existing = Get-Item -LiteralPath $settingsDestination -Force -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Copy-Item -LiteralPath $settingsSource -Destination $settingsDestination
        Write-Output "已创建 Claude 设置：$settingsDestination"
        return
    }

    if ((Test-IsLinkLike -Item $existing) -or $existing.PSIsContainer) {
        Backup-Item -Path $settingsDestination
        Copy-Item -LiteralPath $settingsSource -Destination $settingsDestination
        Write-Output "已重建 Claude 设置：$settingsDestination"
        return
    }

    $target = Read-JsonObject -Path $settingsDestination
    $changed = $false
    Merge-JsonObject -Target $target -Source $Source -Path '$' -Changed ([ref]$changed)
    if (-not $changed) {
        Write-Output "Claude 设置已包含仓库配置：$settingsDestination"
        return
    }

    Backup-Item -Path $settingsDestination
    $target | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsDestination -Encoding utf8NoBOM
    Write-Output "已合并 Claude 设置：$settingsDestination"
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
    $sources = Get-InstallableSkill

    foreach ($targetDir in $skillTargetDirs) {
        foreach ($source in $sources) {
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
    }

    foreach ($file in $globalAgentsFiles) {
        $agentsExisting = Get-Item -LiteralPath $file.Destination -Force -ErrorAction SilentlyContinue
        $agentsCurrent = $null -ne $agentsExisting -and
            -not (Test-IsLinkLike -Item $agentsExisting) -and
            -not $agentsExisting.PSIsContainer -and
            (Get-FileHash -LiteralPath $file.Source -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $file.Destination -Algorithm SHA256).Hash

        if ($agentsCurrent) {
            Write-Information "全局提示词状态一致：$($file.Destination)" -InformationAction Continue
        }
        else {
            Write-Warning "全局提示词状态不一致：$($file.Destination)"
            $consistent = $false
        }
    }

    $settingsExisting = Get-Item -LiteralPath $settingsDestination -Force -ErrorAction SilentlyContinue
    $settingsCurrent = $false
    if ($null -ne $settingsExisting -and
        -not (Test-IsLinkLike -Item $settingsExisting) -and
        -not $settingsExisting.PSIsContainer) {
        try {
            $settingsTarget = Read-JsonObject -Path $settingsDestination
            $settingsCurrent = Test-JsonObjectContains -Target $settingsTarget -Source $settingsSourceObject
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }

    if ($settingsCurrent) {
        Write-Information "Claude 设置状态一致：$settingsDestination" -InformationAction Continue
    }
    else {
        Write-Warning "Claude 设置状态不一致：$settingsDestination 缺少仓库配置"
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

if (-not (Test-Path -LiteralPath $settingsSource -PathType Leaf)) {
    throw "Claude 设置源文件不存在：$settingsSource"
}
$settingsSource = (Resolve-Path -LiteralPath $settingsSource).Path
$settingsSourceObject = Read-JsonObject -Path $settingsSource

if ($Check) {
    if (Test-Installation) {
        exit 0
    }
    exit 1
}

$sources = Get-InstallableSkill
foreach ($targetDir in $skillTargetDirs) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    foreach ($source in $sources) {
        Install-Skill -Source $source -Destination (Join-Path $targetDir $source.Name)
    }

    Remove-StaleManagedLink -TargetDir $targetDir
}

foreach ($file in $globalAgentsFiles) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $file.Destination) -Force | Out-Null
    Install-GlobalAgentsFile -Source $file.Source -Destination $file.Destination
}

New-Item -ItemType Directory -Path (Split-Path -Parent $settingsDestination) -Force | Out-Null
Install-ClaudeSettings -Source $settingsSourceObject
