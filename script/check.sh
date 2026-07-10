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

  if HOME="${command_home}" "$@" "${check_argument}" >/dev/null 2>&1; then
    fail "${name} 检查模式未报告安装漂移"
  fi
  [[ "$(backup_count "${test_home}")" == "0" ]] ||
    fail "${name} 检查模式修改了目标目录"

  HOME="${command_home}" "$@"

  cmp -s "${REPO_ROOT}/codex/AGENTS.md" "${test_home}/.codex/AGENTS.md" ||
    fail "${name} 未正确安装 Codex AGENTS.md"
  for skill_name in "${skill_names[@]}"; do
    assert_link \
      "${test_home}/.agents/skills/${skill_name}" \
      "${REPO_ROOT}/skills/${skill_name}"
  done
  [[ ! -e "${test_home}/.agents/skills/removed-skill" &&
    ! -L "${test_home}/.agents/skills/removed-skill" ]] ||
    fail "${name} 未清理由本仓库管理的陈旧链接"
  [[ -L "${test_home}/.agents/skills/other-skill" ]] ||
    fail "${name} 错误删除了其他来源的链接"

  expected_backups=$((${#skill_names[@]} + 1))
  backup_count_before=$(backup_count "${test_home}")
  [[ "${backup_count_before}" == "${expected_backups}" ]] ||
    fail "${name} 首次安装的备份数量不正确：${backup_count_before}"

  HOME="${command_home}" "$@" "${check_argument}"
  HOME="${command_home}" "$@"
  backup_count_after=$(backup_count "${test_home}")
  [[ "${backup_count_after}" == "${backup_count_before}" ]] ||
    fail "${name} 重复安装时创建了额外备份"

  printf '%s 安装契约通过\n' "${name}"
}

cd -- "${REPO_ROOT}"

for command_name in bash shellcheck pwsh rg; do
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

bash -n script/install.sh script/check.sh
shellcheck -s bash script/install.sh script/check.sh

# 这段代码中的变量必须由 PowerShell 展开。
# shellcheck disable=SC2016
pwsh -NoProfile -Command '
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path "script/install.ps1"),
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error $_ }
        exit 1
    }
'

# 这段代码中的变量必须由 PowerShell 展开。
# shellcheck disable=SC2016
pwsh -NoProfile -Command '
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        throw "缺少 PowerShell 模块 PSScriptAnalyzer"
    }
    Import-Module PSScriptAnalyzer
    $results = Invoke-ScriptAnalyzer -Path script/install.ps1 -Severity Warning,Error
    if ($results) {
        $results | Format-Table -AutoSize
        exit 1
    }
'

test_skill_validator
test_installer shell --check ./script/install.sh
test_installer powershell -Check pwsh -NoProfile -File ./script/install.ps1

git diff --check
printf '全部检查通过\n'
