#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
SKILL_VALIDATOR="${REPO_ROOT}/script/validate-skills.py"
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TEMP_ROOT}"' EXIT
PYTHON_COMMAND=

fail() {
  printf '检查失败：%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令 $1"
}

assert_link() {
  local path=$1
  local expected=$2
  local resolved_path
  local resolved_expected
  [[ -L "${path}" ]] || fail "预期为软链接：${path}"
  resolved_path=$(resolve_path "${path}")
  resolved_expected=$(resolve_path "${expected}")
  [[ "${resolved_path}" == "${resolved_expected}" ]] ||
    fail "软链接目标不正确：${path}"
}

resolve_path() {
  "${PYTHON_COMMAND}" - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve())
PY
}

installer_home() {
  local name=$1
  local path=$2

  if [[ "${name}" == "powershell" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${path}"
    return
  fi

  printf '%s\n' "${path}"
}

backup_count() {
  find "$1" -name '*.bak.*' -print | wc -l | tr -d ' '
}

skill_supports_platform() {
  local source=$1
  local platform=$2
  local supported

  supported=$(awk -v platform="${platform}" '
    $0 == "platform:" { in_platform=1; next }
    in_platform && $0 !~ /^[[:space:]]/ { exit }
    in_platform && $1 == platform ":" { print $2; exit }
  ' "${source}/agents/openai.yaml")

  [[ "${supported}" == "true" ]]
}

run_installer() {
  local name=$1
  local command_home=$2
  shift 2

  if [[ "${name}" == "powershell" ]]; then
    OS=Windows_NT HOME="${command_home}" "$@"
  else
    HOME="${command_home}" "$@"
  fi
}

test_skill_validator() {
  local invalid_root="${TEMP_ROOT}/invalid-skills"
  local first_skill

  "${PYTHON_COMMAND}" "${SKILL_VALIDATOR}" skills

  cp -R skills "${invalid_root}"
  first_skill=$(find "${invalid_root}" -mindepth 1 -maxdepth 1 -type d -print | sort | head -n 1)
  sed -i.bak '/^policy:/,$d' "${first_skill}/agents/openai.yaml"
  rm "${first_skill}/agents/openai.yaml.bak"

  if "${PYTHON_COMMAND}" "${SKILL_VALIDATOR}" "${invalid_root}" >/dev/null 2>&1; then
    fail 'Skill 校验器未拒绝缺少调用策略的元数据'
  fi

  printf 'Skill 负向契约通过\n'
}

test_installer() {
  local name=$1
  local check_argument=$2
  shift 2
  local test_home="${TEMP_ROOT}/${name}"
  local external_root="${test_home}/external-skills"
  local command_home
  local source
  local skill_name
  local index=0
  local expected_backups
  local backup_count_before
  local backup_count_after
  local -a skill_names=()

  mkdir -p "${test_home}/.codex" "${test_home}/.agents/skills" "${external_root}"
  printf '旧指令\n' >"${test_home}/.codex/AGENTS.md"

  shopt -s nullglob
  for source in "${REPO_ROOT}/skills"/*; do
    [[ -d "${source}" ]] || continue
    skill_name=$(basename "${source}")

    if [[ "${name}" == "powershell" ]] &&
      ! skill_supports_platform "${source}" windows; then
      continue
    fi

    skill_names+=("${skill_name}")

    case $((index % 3)) in
      0)
        mkdir -p "${test_home}/.agents/skills/${skill_name}"
        printf '用户目录\n' >"${test_home}/.agents/skills/${skill_name}/marker.txt"
        ;;
      1)
        mkdir -p "${external_root}/${skill_name}"
        ln -s "${external_root}/${skill_name}" "${test_home}/.agents/skills/${skill_name}"
        ;;
      2)
        printf '用户文件\n' >"${test_home}/.agents/skills/${skill_name}"
        ;;
    esac
    ((index += 1))
  done
  shopt -u nullglob

  ((${#skill_names[@]} > 0)) || fail '没有可测试的 Skill'

  ln -s "${REPO_ROOT}/skills/removed-skill" "${test_home}/.agents/skills/removed-skill"
  ln -s "${test_home}/missing-other" "${test_home}/.agents/skills/other-skill"
  command_home=$(installer_home "${name}" "${test_home}")

  if run_installer "${name}" "${command_home}" "$@" "${check_argument}" >/dev/null 2>&1; then
    fail "${name} 检查模式未报告安装漂移"
  fi
  [[ "$(backup_count "${test_home}")" == "0" ]] ||
    fail "${name} 检查模式修改了目标目录"

  run_installer "${name}" "${command_home}" "$@"

  cmp -s "${REPO_ROOT}/codex/AGENTS.md" "${test_home}/.codex/AGENTS.md" ||
    fail "${name} 未正确安装 Codex AGENTS.md"
  for skill_name in "${skill_names[@]}"; do
    assert_link \
      "${test_home}/.agents/skills/${skill_name}" \
      "${REPO_ROOT}/skills/${skill_name}"
  done
  if [[ "${name}" == "powershell" ]]; then
    for source in "${REPO_ROOT}/skills"/*; do
      [[ -d "${source}" ]] || continue
      if ! skill_supports_platform "${source}" windows; then
        skill_name=$(basename "${source}")
        [[ ! -e "${test_home}/.agents/skills/${skill_name}" &&
          ! -L "${test_home}/.agents/skills/${skill_name}" ]] ||
          fail "Windows 安装器错误安装了不支持 Windows 的 Skill：${skill_name}"
      fi
    done
  fi
  [[ ! -e "${test_home}/.agents/skills/removed-skill" &&
    ! -L "${test_home}/.agents/skills/removed-skill" ]] ||
    fail "${name} 未清理由本仓库管理的陈旧链接"
  [[ -L "${test_home}/.agents/skills/other-skill" ]] ||
    fail "${name} 错误删除了其他来源的链接"

  expected_backups=$((${#skill_names[@]} + 1))
  backup_count_before=$(backup_count "${test_home}")
  [[ "${backup_count_before}" == "${expected_backups}" ]] ||
    fail "${name} 首次安装的备份数量不正确：${backup_count_before}"

  run_installer "${name}" "${command_home}" "$@" "${check_argument}"
  run_installer "${name}" "${command_home}" "$@"
  backup_count_after=$(backup_count "${test_home}")
  [[ "${backup_count_after}" == "${backup_count_before}" ]] ||
    fail "${name} 重复安装时创建了额外备份"

  printf '%s 安装契约通过\n' "${name}"
}

test_pi_deployer() {
  local test_home="${TEMP_ROOT}/pi"
  local settings_target="${test_home}/.pi/agent/settings.json"
  local models_target="${test_home}/.pi/agent/models.json"
  local mcp_target="${test_home}/.pi/agent/mcp.json"

  mkdir -p "${test_home}/.pi/agent"
  cp "${REPO_ROOT}/pi/settings.json" "${settings_target}"
  cp "${REPO_ROOT}/pi/models.json" "${models_target}"
  cp "${REPO_ROOT}/pi/mcp.json" "${mcp_target}"

  node - "${settings_target}" "${models_target}" "${mcp_target}" <<'NODE'
const fs = require("node:fs");

const [settingsPath, modelsPath, mcpPath] = process.argv.slice(2);
const read = (path) => JSON.parse(fs.readFileSync(path, "utf8"));
const write = (path, value) => fs.writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);

const settings = read(settingsPath);
settings.lastChangelogVersion = "fixture-version";
write(settingsPath, settings);

const models = read(modelsPath);
models.providers.atlas.baseUrl = "http://fixture.invalid/v1";
models.providers.atlas.apiKey = "fixture-secret";
models.providers.atlas.headers = { Authorization: "Bearer fixture-secret" };
write(modelsPath, models);

const mcp = read(mcpPath);
mcp.mcpServers["ida-windows"].env = { IDA_TOKEN: "fixture-secret" };
mcp.mcpServers["ida-windows"].headers = { Authorization: "Bearer fixture-secret" };
mcp.mcpServers["ida-windows"].bearerToken = "fixture-secret";
write(mcpPath, mcp);
NODE

  HOME="${test_home}" \
    PI_CODING_AGENT_DIR="${test_home}/.pi/agent" \
    XDG_CONFIG_HOME="${test_home}/.config" \
    "${REPO_ROOT}/script/deploy-pi.sh"
  HOME="${test_home}" \
    PI_CODING_AGENT_DIR="${test_home}/.pi/agent" \
    XDG_CONFIG_HOME="${test_home}/.config" \
    "${REPO_ROOT}/script/deploy-pi.sh" --check

  node - "${settings_target}" "${models_target}" "${mcp_target}" <<'NODE'
const fs = require("node:fs");

const [settingsPath, modelsPath, mcpPath] = process.argv.slice(2);
const read = (path) => JSON.parse(fs.readFileSync(path, "utf8"));
const settings = read(settingsPath);
const models = read(modelsPath);
const mcp = read(mcpPath);

if (settings.lastChangelogVersion !== "fixture-version") throw new Error("lastChangelogVersion 未保留");
if (models.providers.atlas.baseUrl !== "http://fixture.invalid/v1") throw new Error("模型 baseUrl 未保留");
if (models.providers.atlas.apiKey !== "fixture-secret") throw new Error("模型 apiKey 未保留");
if (models.providers.atlas.headers.Authorization !== "Bearer fixture-secret") throw new Error("模型请求头未保留");
const server = mcp.mcpServers["ida-windows"];
if (server.env.IDA_TOKEN !== "fixture-secret") throw new Error("MCP 环境变量未保留");
if (server.headers.Authorization !== "Bearer fixture-secret") throw new Error("MCP 请求头未保留");
if (server.bearerToken !== "fixture-secret") throw new Error("MCP token 未保留");
NODE

  [[ "$(backup_count "${test_home}")" == "0" ]] ||
    fail 'Pi 配置重复部署创建了不必要的备份'
  printf 'Pi 配置部署契约通过\n'
}

test_pi_deployer_powershell() {
  local test_home="${TEMP_ROOT}/pi-powershell"
  local settings_target="${test_home}/.pi/agent/settings.json"
  local models_target="${test_home}/.pi/agent/models.json"
  local mcp_target="${test_home}/.pi/agent/mcp.json"
  local command_home
  local pi_config_dir
  local config_home

  mkdir -p "${test_home}/.pi/agent"
  cp "${REPO_ROOT}/pi/settings.json" "${settings_target}"
  cp "${REPO_ROOT}/pi/models.json" "${models_target}"
  cp "${REPO_ROOT}/pi/mcp.json" "${mcp_target}"

  node - "${settings_target}" "${models_target}" "${mcp_target}" <<'NODE'
const fs = require("node:fs");

const [settingsPath, modelsPath, mcpPath] = process.argv.slice(2);
const read = (path) => JSON.parse(fs.readFileSync(path, "utf8"));
const write = (path, value) => fs.writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);

const settings = read(settingsPath);
settings.lastChangelogVersion = "fixture-version";
write(settingsPath, settings);

const models = read(modelsPath);
models.providers.atlas.baseUrl = "http://fixture.invalid/v1";
models.providers.atlas.apiKey = "fixture-secret";
models.providers.atlas.headers = { Authorization: "Bearer fixture-secret" };
write(modelsPath, models);

const mcp = read(mcpPath);
mcp.mcpServers["ida-windows"].env = { IDA_TOKEN: "fixture-secret" };
mcp.mcpServers["ida-windows"].headers = { Authorization: "Bearer fixture-secret" };
mcp.mcpServers["ida-windows"].bearerToken = "fixture-secret";
write(mcpPath, mcp);
NODE

  command_home=$(installer_home powershell "${test_home}")
  pi_config_dir=$(installer_home powershell "${test_home}/.pi/agent")
  config_home=$(installer_home powershell "${test_home}/.config")

  if OS=Windows_NT HOME="${command_home}" \
    PI_CODING_AGENT_DIR="${pi_config_dir}" \
    XDG_CONFIG_HOME="${config_home}" \
    pwsh -NoProfile -File ./script/deploy-pi.ps1 -Check >/dev/null 2>&1; then
    fail 'PowerShell Pi 检查模式未报告漂移'
  fi
  [[ "$(backup_count "${test_home}")" == "0" ]] ||
    fail 'PowerShell Pi 检查模式修改了目标目录'

  OS=Windows_NT HOME="${command_home}" \
    PI_CODING_AGENT_DIR="${pi_config_dir}" \
    XDG_CONFIG_HOME="${config_home}" \
    pwsh -NoProfile -File ./script/deploy-pi.ps1 >/dev/null
  OS=Windows_NT HOME="${command_home}" \
    PI_CODING_AGENT_DIR="${pi_config_dir}" \
    XDG_CONFIG_HOME="${config_home}" \
    pwsh -NoProfile -File ./script/deploy-pi.ps1 -Check >/dev/null

  node - "${settings_target}" "${models_target}" "${mcp_target}" <<'NODE'
const fs = require("node:fs");

const [settingsPath, modelsPath, mcpPath] = process.argv.slice(2);
const read = (path) => JSON.parse(fs.readFileSync(path, "utf8"));
const settings = read(settingsPath);
const models = read(modelsPath);
const mcp = read(mcpPath);

if (settings.lastChangelogVersion !== "fixture-version") throw new Error("lastChangelogVersion 未保留");
if (models.providers.atlas.baseUrl !== "http://fixture.invalid/v1") throw new Error("模型 baseUrl 未保留");
if (models.providers.atlas.apiKey !== "fixture-secret") throw new Error("模型 apiKey 未保留");
if (models.providers.atlas.headers.Authorization !== "Bearer fixture-secret") throw new Error("模型请求头未保留");
const server = mcp.mcpServers["ida-windows"];
if (server.env.IDA_TOKEN !== "fixture-secret") throw new Error("MCP 环境变量未保留");
if (server.headers.Authorization !== "Bearer fixture-secret") throw new Error("MCP 请求头未保留");
if (server.bearerToken !== "fixture-secret") throw new Error("MCP token 未保留");
if (server.command !== "C:\\Users\\zzyi\\.local\\bin\\uv.exe") throw new Error(`MCP Windows 路径错误: ${server.command}`);
NODE

  [[ "$(backup_count "${test_home}")" == "1" ]] ||
    fail 'PowerShell Pi 首次部署的备份数量不正确'

  OS=Windows_NT HOME="${command_home}" \
    PI_CODING_AGENT_DIR="${pi_config_dir}" \
    XDG_CONFIG_HOME="${config_home}" \
    pwsh -NoProfile -File ./script/deploy-pi.ps1 >/dev/null
  [[ "$(backup_count "${test_home}")" == "1" ]] ||
    fail 'PowerShell Pi 重复部署创建了额外备份'
  printf 'PowerShell Pi 配置部署契约通过\n'
}

cd -- "${REPO_ROOT}"

for command_name in bash node shellcheck pwsh rg; do
  require_command "${command_name}"
done

if command -v python3 >/dev/null 2>&1; then
  PYTHON_COMMAND=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_COMMAND=python
else
  fail '缺少 Python 3'
fi

[[ -f "${SKILL_VALIDATOR}" ]] || fail "找不到 Skill 校验器：${SKILL_VALIDATOR}"

bash -n script/install.sh script/check.sh script/deploy-pi.sh
shellcheck -s bash script/install.sh script/check.sh script/deploy-pi.sh

# 这段代码中的变量必须由 PowerShell 展开。
# shellcheck disable=SC2016
pwsh -NoProfile -Command '
    $paths = @("script/install.ps1", "script/deploy-pi.ps1")
    foreach ($path in $paths) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $path),
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            $errors | ForEach-Object { Write-Error $_ }
            exit 1
        }
    }
'

# 这段代码中的变量必须由 PowerShell 展开。
# shellcheck disable=SC2016
pwsh -NoProfile -Command '
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        throw "缺少 PowerShell 模块 PSScriptAnalyzer"
    }
    Import-Module PSScriptAnalyzer
    $results = @()
    foreach ($path in @("script/install.ps1", "script/deploy-pi.ps1")) {
        $results += @(Invoke-ScriptAnalyzer -Path $path -Severity Warning,Error)
    }
    if ($results) {
        $results | Format-Table -AutoSize
        exit 1
    }
'

test_skill_validator
test_pi_deployer
test_pi_deployer_powershell
test_installer shell --check ./script/install.sh
test_installer powershell -Check pwsh -NoProfile -File ./script/install.ps1

git diff --check
printf '全部检查通过\n'
