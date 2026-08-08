[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $repoRoot 'pi'
$globalAgentsSource = Join-Path $repoRoot 'agents\AGENTS.md'

if ([string]::IsNullOrWhiteSpace($HOME)) {
    throw 'HOME 未设置'
}

$piConfigDir = if ([string]::IsNullOrWhiteSpace($env:PI_CODING_AGENT_DIR)) {
    Join-Path $HOME '.pi\agent'
}
else {
    $env:PI_CODING_AGENT_DIR
}

$configHome = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
    Join-Path $HOME '.config'
}
else {
    $env:XDG_CONFIG_HOME
}

$magicContextTarget = Join-Path $configHome 'cortexkit\magic-context.jsonc'
$subagentConfigTarget = Join-Path $piConfigDir 'extensions\subagent\config.json'
$sourceSettings = Join-Path $sourceDir 'settings.json'
$sourceModels = Join-Path $sourceDir 'models.json'
$sourceMcp = Join-Path $sourceDir 'mcp.json'
$sourceMagicContext = Join-Path $sourceDir 'cortexkit\magic-context.jsonc'
$sourceSubagentConfig = Join-Path $sourceDir 'extensions\subagent\config.json'
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$forbiddenKeyPattern = [regex]::new(
    '^(baseUrl|apiKey|api_key|headers|bearerToken|bearerTokenEnv|clientSecret|password|secret|token)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

function Test-IsMap {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    return $null -ne $Value -and $Value -is [System.Collections.IDictionary]
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$MissingAsEmpty
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($MissingAsEmpty) {
            return [ordered]@{}
        }

        throw "配置文件不存在：$Path"
    }

    try {
        $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw ('{0}: {1}' -f $Path, $_.Exception.Message)
    }

    if ($null -eq $value) {
        throw "配置文件为空：$Path"
    }

    return $value
}

function Assert-NoForbiddenKey {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$File,

        [string]$Path = '$'
    )

    if (Test-IsMap -Value $Value) {
        foreach ($key in $Value.Keys) {
            $keyText = [string]$key
            if ($forbiddenKeyPattern.IsMatch($keyText)) {
                throw ('{0}: {1}.{2} 属于主机本地或敏感字段，不能提交到仓库' -f $File, $Path, $keyText)
            }

            Assert-NoForbiddenKey -Value $Value[$key] -File $File -Path ('{0}.{1}' -f $Path, $keyText)
        }
        return
    }

    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index += 1) {
            Assert-NoForbiddenKey -Value $Value[$index] -File $File -Path ('{0}[{1}]' -f $Path, $index)
        }
    }
}

function Copy-Map {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    $result = [ordered]@{}
    if (Test-IsMap -Value $Value) {
        foreach ($key in $Value.Keys) {
            $result[$key] = $Value[$key]
        }
    }

    return $result
}

function Get-MapChild {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Map,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ((Test-IsMap -Value $Map) -and $Map.Contains($Key) -and (Test-IsMap -Value $Map[$Key])) {
        return $Map[$Key]
    }

    return [ordered]@{}
}

function Get-PreservedMap {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Existing,

        [Parameter(Mandatory = $true)]
        [string[]]$Keys
    )

    $result = Copy-Map -Value $Source
    if (Test-IsMap -Value $Existing) {
        foreach ($key in $Keys) {
            if ($Existing.Contains($key)) {
                $result[$key] = $Existing[$key]
            }
        }
    }

    return $result
}

function Merge-ModelConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [object]$Existing
    )

    $sourceProviders = Get-MapChild -Map $Source -Key 'providers'
    $existingProviders = Get-MapChild -Map $Existing -Key 'providers'
    $providers = [ordered]@{}
    $localKeys = @('baseUrl', 'apiKey', 'headers')

    foreach ($name in $sourceProviders.Keys) {
        $existingProvider = $null
        if ($existingProviders.Contains($name)) {
            $existingProvider = $existingProviders[$name]
        }
        $providers[$name] = Get-PreservedMap -Source $sourceProviders[$name] -Existing $existingProvider -Keys $localKeys
    }

    foreach ($name in $existingProviders.Keys) {
        if (-not $sourceProviders.Contains($name)) {
            $providers[$name] = $existingProviders[$name]
        }
    }

    $result = Copy-Map -Value $Source
    $result['providers'] = $providers
    return $result
}

function Merge-McpServer {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Existing
    )

    $localKeys = @('env', 'headers', 'bearerToken', 'bearerTokenEnv', 'url')
    $result = Get-PreservedMap -Source $Source -Existing $Existing -Keys $localKeys

    if (
        (Test-IsMap -Value $Existing) -and
        $Existing.Contains('oauth') -and
        (Test-IsMap -Value $Existing['oauth'])
    ) {
        $sourceOauth = [ordered]@{}
        if (
            (Test-IsMap -Value $Source) -and
            $Source.Contains('oauth') -and
            (Test-IsMap -Value $Source['oauth'])
        ) {
            $sourceOauth = $Source['oauth']
        }
        $result['oauth'] = Get-PreservedMap -Source $sourceOauth -Existing $Existing['oauth'] -Keys @('clientSecret')
    }

    return $result
}

function Merge-McpConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [object]$Existing
    )

    $sourceServers = Get-MapChild -Map $Source -Key 'mcpServers'
    $existingServers = Get-MapChild -Map $Existing -Key 'mcpServers'
    $servers = [ordered]@{}

    foreach ($name in $sourceServers.Keys) {
        $existingServer = $null
        if ($existingServers.Contains($name)) {
            $existingServer = $existingServers[$name]
        }
        $servers[$name] = Merge-McpServer -Source $sourceServers[$name] -Existing $existingServer
    }

    foreach ($name in $existingServers.Keys) {
        if (-not $sourceServers.Contains($name)) {
            $servers[$name] = $existingServers[$name]
        }
    }

    $result = Copy-Map -Value $Source
    $result['mcpServers'] = $servers
    return $result
}

function Convert-WslPathToWindows {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($Value -isnot [string]) {
        return $Value
    }

    $match = [regex]::Match($Value, '^/mnt/(?<drive>[A-Za-z])(?:/(?<path>.*))?$')
    if (-not $match.Success) {
        return $Value
    }

    $drive = $match.Groups['drive'].Value.ToUpperInvariant()
    $path = $match.Groups['path'].Value.Replace('/', '\')
    if ([string]::IsNullOrEmpty($path)) {
        return '{0}:\' -f $drive
    }

    return '{0}:\{1}' -f $drive, $path
}

function Convert-McpWindowsPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $servers = Get-MapChild -Map $Config -Key 'mcpServers'
    foreach ($name in $servers.Keys) {
        $server = $servers[$name]
        if (-not (Test-IsMap -Value $server)) {
            continue
        }

        if ($server.Contains('command')) {
            $server['command'] = Convert-WslPathToWindows -Value $server['command']
        }

        if ($server.Contains('args') -and $server['args'] -is [System.Collections.IList]) {
            for ($index = 0; $index -lt $server['args'].Count; $index += 1) {
                $server['args'][$index] = Convert-WslPathToWindows -Value $server['args'][$index]
            }
        }
    }

    return $Config
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 100
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $content = '{0}{1}' -f $json, [Environment]::NewLine
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
}

function Write-StagedJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('settings', 'models', 'mcp')]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $true)]
        [string]$StagedPath
    )

    $source = Read-JsonFile -Path $SourcePath
    $existing = Read-JsonFile -Path $TargetPath -MissingAsEmpty
    $result = switch ($Kind) {
        'settings' { Get-PreservedMap -Source $source -Existing $existing -Keys @('lastChangelogVersion') }
        'models' { Merge-ModelConfig -Source $source -Existing $existing }
        'mcp' { Merge-McpConfig -Source $source -Existing $existing }
    }

    if ($Kind -eq 'mcp') {
        $result = Convert-McpWindowsPath -Config $result
    }

    Write-JsonFile -Value $result -Path $StagedPath
}

function ConvertTo-StableValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if (Test-IsMap -Value $Value) {
        $stable = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object { [string]$_ })) {
            $stable[[string]$key] = ConvertTo-StableValue -Value $Value[$key]
        }
        return $stable
    }

    if ($Value -is [System.Collections.IList]) {
        $stableList = [System.Collections.ArrayList]::new()
        foreach ($item in $Value) {
            [void]$stableList.Add((ConvertTo-StableValue -Value $item))
        }
        return ,$stableList.ToArray()
    }

    return $Value
}

function Test-JsonFilesEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    if (-not (Test-Path -LiteralPath $Right -PathType Leaf)) {
        return $false
    }

    try {
        $leftValue = Read-JsonFile -Path $Left
        $rightValue = Read-JsonFile -Path $Right
        $leftStable = ConvertTo-StableValue -Value $leftValue
        $rightStable = ConvertTo-StableValue -Value $rightValue
        $leftJson = ConvertTo-Json -InputObject $leftStable -Depth 100 -Compress
        $rightJson = ConvertTo-Json -InputObject $rightStable -Depth 100 -Compress
        return [string]::Equals($leftJson, $rightJson, [System.StringComparison]::Ordinal)
    }
    catch {
        return $false
    }
}

function Test-FileBytesEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    if (-not (Test-Path -LiteralPath $Right -PathType Leaf)) {
        return $false
    }

    try {
        $leftHash = (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash
        $rightHash = (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
        return [string]::Equals($leftHash, $rightHash, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-IsLinkLike {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
}

function Get-UniqueBackupPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $candidate = '{0}.bak.{1}' -f $Path, $timestamp
    $suffix = 1

    while ($null -ne (Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue)) {
        $candidate = '{0}.bak.{1}.{2}' -f $Path, $timestamp, $suffix
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
    Write-Output ('已备份 {0} -> {1}' -f $Path, $backup)
}

function Test-ManagedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagedPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [switch]$ByteContent
    )

    $existing = Get-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
    if (
        $null -eq $existing -or
        $existing.PSIsContainer -or
        (Test-IsLinkLike -Item $existing)
    ) {
        Write-Warning ('存在漂移：{0}（目标不是普通文件）' -f $Description)
        return $false
    }

    $equal = if ($ByteContent) {
        Test-FileBytesEqual -Left $StagedPath -Right $TargetPath
    }
    else {
        Test-JsonFilesEqual -Left $StagedPath -Right $TargetPath
    }

    if (-not $equal) {
        Write-Warning ('存在漂移：{0}' -f $Description)
        return $false
    }

    Write-Information ('状态一致：{0}' -f $Description) -InformationAction Continue
    return $true
}

function Install-ManagedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagedPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [switch]$ByteContent
    )

    $targetParent = Split-Path -Parent $TargetPath
    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null

    $existing = Get-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -and -not $existing.PSIsContainer -and -not (Test-IsLinkLike -Item $existing)) {
        $equal = if ($ByteContent) {
            Test-FileBytesEqual -Left $StagedPath -Right $TargetPath
        }
        else {
            Test-JsonFilesEqual -Left $StagedPath -Right $TargetPath
        }

        if ($equal) {
            Write-Output ('已是最新状态：{0}' -f $Description)
            return
        }

        Backup-Item -Path $TargetPath | Out-Null
    }
    elseif ($null -ne $existing) {
        Backup-Item -Path $TargetPath | Out-Null
    }

    Move-Item -LiteralPath $StagedPath -Destination $TargetPath
    Write-Output ('已部署 {0} <- {1}' -f $Description, $TargetPath)
}

$stagedDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dotfiles-codex-pi-{0}' -f [guid]::NewGuid().ToString('N'))
$stagedReady = $false

try {
    New-Item -ItemType Directory -Path $stagedDir -Force | Out-Null
    $stagedReady = $true

    $sourceFiles = @($sourceSettings, $sourceModels, $sourceMcp, $sourceSubagentConfig)
    foreach ($sourcePath in $sourceFiles) {
        $sourceValue = Read-JsonFile -Path $sourcePath
        if (-not (Test-IsMap -Value $sourceValue)) {
            throw "配置文件根节点必须是对象：$sourcePath"
        }
        Assert-NoForbiddenKey -Value $sourceValue -File $sourcePath
    }

    if (-not (Test-Path -LiteralPath $sourceMagicContext -PathType Leaf)) {
        throw "仓库配置文件不存在：$sourceMagicContext"
    }

    if (-not (Test-Path -LiteralPath $sourceSubagentConfig -PathType Leaf)) {
        throw "仓库配置文件不存在：$sourceSubagentConfig"
    }

    if (-not (Test-Path -LiteralPath $globalAgentsSource -PathType Leaf)) {
        throw "共享全局提示词源文件不存在：$globalAgentsSource"
    }

    $stagedSettings = Join-Path $stagedDir 'settings.json'
    $stagedModels = Join-Path $stagedDir 'models.json'
    $stagedMcp = Join-Path $stagedDir 'mcp.json'
    $stagedMagicContext = Join-Path $stagedDir 'magic-context.jsonc'
    $stagedSubagentConfig = Join-Path $stagedDir 'subagent-config.json'
    $stagedGlobalAgents = Join-Path $stagedDir 'AGENTS.md'

    Write-StagedJson -Kind settings -SourcePath $sourceSettings -TargetPath (Join-Path $piConfigDir 'settings.json') -StagedPath $stagedSettings
    Write-StagedJson -Kind models -SourcePath $sourceModels -TargetPath (Join-Path $piConfigDir 'models.json') -StagedPath $stagedModels
    Write-StagedJson -Kind mcp -SourcePath $sourceMcp -TargetPath (Join-Path $piConfigDir 'mcp.json') -StagedPath $stagedMcp
    Copy-Item -LiteralPath $sourceMagicContext -Destination $stagedMagicContext
    Copy-Item -LiteralPath $sourceSubagentConfig -Destination $stagedSubagentConfig
    Copy-Item -LiteralPath $globalAgentsSource -Destination $stagedGlobalAgents

    if ($Check) {
        $status = 0
        if (-not (Test-ManagedFile -StagedPath $stagedSettings -TargetPath (Join-Path $piConfigDir 'settings.json') -Description 'Pi settings.json')) {
            $status = 1
        }
        if (-not (Test-ManagedFile -StagedPath $stagedModels -TargetPath (Join-Path $piConfigDir 'models.json') -Description 'Pi models.json')) {
            $status = 1
        }
        if (-not (Test-ManagedFile -StagedPath $stagedMcp -TargetPath (Join-Path $piConfigDir 'mcp.json') -Description 'Pi MCP 配置')) {
            $status = 1
        }
        if (-not (Test-ManagedFile -StagedPath $stagedMagicContext -TargetPath $magicContextTarget -Description 'Magic Context 配置' -ByteContent)) {
            $status = 1
        }
        if (-not (Test-ManagedFile -StagedPath $stagedSubagentConfig -TargetPath $subagentConfigTarget -Description 'Pi 子代理扩展配置')) {
            $status = 1
        }
        if (-not (Test-ManagedFile -StagedPath $stagedGlobalAgents -TargetPath (Join-Path $piConfigDir 'AGENTS.md') -Description 'Pi 全局提示词' -ByteContent)) {
            $status = 1
        }

        if ($status -eq 0) {
            Write-Information 'Pi 配置状态一致' -InformationAction Continue
            exit 0
        }

        Write-Warning "Pi 配置状态不一致，请运行 $PSCommandPath 完成部署"
        exit 1
    }

    Install-ManagedFile -StagedPath $stagedSettings -TargetPath (Join-Path $piConfigDir 'settings.json') -Description 'Pi settings.json'
    Install-ManagedFile -StagedPath $stagedModels -TargetPath (Join-Path $piConfigDir 'models.json') -Description 'Pi models.json'
    Install-ManagedFile -StagedPath $stagedMcp -TargetPath (Join-Path $piConfigDir 'mcp.json') -Description 'Pi MCP 配置'
    Install-ManagedFile -StagedPath $stagedMagicContext -TargetPath $magicContextTarget -Description 'Magic Context 配置' -ByteContent
    Install-ManagedFile -StagedPath $stagedSubagentConfig -TargetPath $subagentConfigTarget -Description 'Pi 子代理扩展配置'
    Install-ManagedFile -StagedPath $stagedGlobalAgents -TargetPath (Join-Path $piConfigDir 'AGENTS.md') -Description 'Pi 全局提示词' -ByteContent
}
finally {
    if ($stagedReady -and (Test-Path -LiteralPath $stagedDir)) {
        Remove-Item -LiteralPath $stagedDir -Recurse -Force
    }
}
