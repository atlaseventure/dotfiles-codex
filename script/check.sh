#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
SKILL_VALIDATOR="${CODEX_HOME:-${HOME}/.codex}/skills/.system/skill-creator/scripts/quick_validate.py"
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TEMP_ROOT}"' EXIT

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
  [[ -L "${path}" ]] || fail "预期为软链接：${path}"
  [[ "$(readlink "${path}")" == "${expected}" ]] ||
    fail "软链接目标不正确：${path}"
}

test_installer() {
  local name=$1
  shift
  local test_home="${TEMP_ROOT}/${name}"
  local external_skill="${test_home}/external-skill"
  local backup_count_before
  local backup_count_after

  mkdir -p "${test_home}/.codex" "${test_home}/.agents/skills/commit-worktree" "${external_skill}"
  printf '旧指令\n' >"${test_home}/.codex/AGENTS.md"
  printf '用户目录\n' >"${test_home}/.agents/skills/commit-worktree/marker.txt"
  ln -s "${external_skill}" "${test_home}/.agents/skills/root-cause-review"
  ln -s "${REPO_ROOT}/skills/removed-skill" "${test_home}/.agents/skills/removed-skill"
  ln -s "${test_home}/missing-other" "${test_home}/.agents/skills/other-skill"

  HOME="${test_home}" "$@"

  cmp -s "${REPO_ROOT}/codex/AGENTS.md" "${test_home}/.codex/AGENTS.md" ||
    fail "${name} 未正确安装 Codex AGENTS.md"
  assert_link \
    "${test_home}/.agents/skills/commit-worktree" \
    "${REPO_ROOT}/skills/commit-worktree"
  assert_link \
    "${test_home}/.agents/skills/root-cause-review" \
    "${REPO_ROOT}/skills/root-cause-review"
  [[ ! -e "${test_home}/.agents/skills/removed-skill" &&
    ! -L "${test_home}/.agents/skills/removed-skill" ]] ||
    fail "${name} 未清理由本仓库管理的陈旧链接"
  [[ -L "${test_home}/.agents/skills/other-skill" ]] ||
    fail "${name} 错误删除了其他来源的链接"

  backup_count_before=$(find "${test_home}" -name '*.bak.*' -print | wc -l | tr -d ' ')
  [[ "${backup_count_before}" == "3" ]] ||
    fail "${name} 首次安装的备份数量不正确：${backup_count_before}"

  HOME="${test_home}" "$@"
  backup_count_after=$(find "${test_home}" -name '*.bak.*' -print | wc -l | tr -d ' ')
  [[ "${backup_count_after}" == "${backup_count_before}" ]] ||
    fail "${name} 重复安装时创建了额外备份"

  printf '%s 安装契约通过\n' "${name}"
}

cd -- "${REPO_ROOT}"

for command_name in bash python3 shellcheck pwsh rg; do
  require_command "${command_name}"
done

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

for skill_dir in skills/*; do
  [[ -d "${skill_dir}" ]] || continue
  python3 "${SKILL_VALIDATOR}" "${skill_dir}"
done

rg -q 'default_prompt: ".*\$commit-worktree' skills/commit-worktree/agents/openai.yaml ||
  fail 'commit-worktree 默认提示词未显式引用 Skill'
rg -q 'default_prompt: ".*\$root-cause-review' skills/root-cause-review/agents/openai.yaml ||
  fail 'root-cause-review 默认提示词未显式引用 Skill'
rg -q 'allow_implicit_invocation: false' skills/root-cause-review/agents/openai.yaml ||
  fail 'root-cause-review 未保持显式调用策略'

test_installer shell ./script/install.sh
test_installer powershell pwsh -NoProfile -File ./script/install.ps1

git diff --check
printf '全部检查通过\n'
