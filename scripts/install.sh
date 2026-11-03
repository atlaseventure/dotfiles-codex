#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
SOURCE_DIR="${REPO_ROOT}/skills"
GLOBAL_AGENTS_SOURCE="${REPO_ROOT}/codex/AGENTS.md"
GLOBAL_CLAUDE_SOURCE="${REPO_ROOT}/claude/CLAUDE.md"
CLAUDE_SETTINGS_SOURCE="${REPO_ROOT}/claude/settings.json"
SKILL_TARGET_DIRS=("${HOME:?HOME 未设置}/.agents/skills" "${HOME}/.claude/skills")
CODEX_TARGET_DIR="${HOME}/.codex"
CODEX_AGENTS_TARGET="${CODEX_TARGET_DIR}/AGENTS.md"
CLAUDE_TARGET_DIR="${HOME}/.claude"
CLAUDE_AGENTS_TARGET="${CLAUDE_TARGET_DIR}/CLAUDE.md"
CLAUDE_SETTINGS_TARGET="${CLAUDE_TARGET_DIR}/settings.json"
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
MODE=install
NO_BACKUP=false
PLATFORM=unix

while (($# > 0)); do
  case "$1" in
    --check)
      MODE=check
      ;;
    --no-backup)
      NO_BACKUP=true
      ;;
    *)
      printf '未知参数：%s\n' "$1" >&2
      printf '用法：%s [--check] [--no-backup]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -d "${SOURCE_DIR}" ]]; then
  printf 'Skill 源目录不存在：%s\n' "${SOURCE_DIR}" >&2
  exit 1
fi

for source in "${GLOBAL_AGENTS_SOURCE}" "${GLOBAL_CLAUDE_SOURCE}" "${CLAUDE_SETTINGS_SOURCE}"; do
  if [[ ! -f "${source}" ]]; then
    printf '源文件不存在：%s\n' "${source}" >&2
    exit 1
  fi
done

unique_backup_path() {
  local base=$1
  local candidate="${base}.bak.${TIMESTAMP}"
  local suffix=1

  while [[ -e "${candidate}" || -L "${candidate}" ]]; do
    candidate="${base}.bak.${TIMESTAMP}.${suffix}"
    ((suffix += 1))
  done

  printf '%s\n' "${candidate}"
}

backup_item() {
  local path=$1
  local backup

  if [[ "${NO_BACKUP}" == true ]]; then
    rm -r "${path}"
    printf '已直接移除冲突项：%s\n' "${path}"
    return
  fi

  backup=$(unique_backup_path "${path}")
  mv "${path}" "${backup}"
  printf '已备份 %s -> %s\n' "${path}" "${backup}"
}

install_skill() {
  local source=$1
  local destination=$2
  local current_target

  if [[ -L "${destination}" ]]; then
    current_target=$(readlink "${destination}")
    if [[ "${current_target}" == "${source}" ]]; then
      printf 'Skill 已是最新状态：%s\n' "${destination}"
      return
    fi
    backup_item "${destination}"
  elif [[ -e "${destination}" ]]; then
    backup_item "${destination}"
  fi

  ln -s "${source}" "${destination}"
  printf '已链接 %s -> %s\n' "${destination}" "${source}"
}

skill_supports_platform() {
  local source=$1
  local platform=$2
  local metadata_path="${source}/agents/openai.yaml"
  local supported

  supported=$(awk -v platform="${platform}" '
    $0 == "platform:" { in_platform=1; next }
    in_platform && $0 !~ /^[[:space:]]/ { exit }
    in_platform && $1 == platform ":" { print $2; exit }
  ' "${metadata_path}")

  if [[ -z "${supported}" ]]; then
    printf 'Skill 平台元数据缺失：%s\n' "${metadata_path}" >&2
    exit 1
  fi

  case "${supported}" in
    true) return 0 ;;
    false) return 1 ;;
    *)
      printf 'Skill 平台元数据无效：%s\n' "${metadata_path}" >&2
      exit 1
      ;;
  esac
}

remove_stale_managed_links() {
  local target_dir=$1
  local destination
  local link_target

  shopt -s nullglob
  for destination in "${target_dir}"/*; do
    [[ -L "${destination}" ]] || continue
    link_target=$(readlink "${destination}")
    if [[ "${link_target}" == "${SOURCE_DIR}/"* && ! -e "${link_target}" ]]; then
      rm "${destination}"
      printf '已移除陈旧 Skill 链接：%s\n' "${destination}"
    fi
  done
  shopt -u nullglob
}

install_global_agents() {
  local source=$1
  local destination=$2

  if [[ -L "${destination}" || -e "${destination}" ]]; then
    if [[ ! -L "${destination}" && -f "${destination}" ]] &&
      cmp -s "${source}" "${destination}"; then
      printf '全局提示词已是最新状态：%s\n' "${destination}"
      return
    fi
    backup_item "${destination}"
  fi

  cp "${source}" "${destination}"
  printf '已复制 %s <- %s\n' "${destination}" "${source}"
}

run_settings_json_tool() {
  local mode=$1
  local source=$2
  local destination=${3:-}
  local temporary=${4:-}

  python3 - "${mode}" "${source}" "${destination}" "${temporary}" <<'PY'
import json
import sys
from pathlib import Path

mode, source_name, destination_name, temporary_name = sys.argv[1:]
source_path = Path(source_name)

try:
    source = json.loads(source_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"JSON 配置无效：{source_path}。{error}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(source, dict):
    print(f"JSON 配置根节点必须是对象：{source_path}", file=sys.stderr)
    raise SystemExit(1)

if mode == "validate":
    raise SystemExit(0)

destination_path = Path(destination_name)
try:
    target = json.loads(destination_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"JSON 配置无效：{destination_path}。{error}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(target, dict):
    print(f"JSON 配置根节点必须是对象：{destination_path}", file=sys.stderr)
    raise SystemExit(1)

def contains(target_object, source_object):
    for key, value in source_object.items():
        if key not in target_object:
            return False
        if isinstance(value, dict):
            if not isinstance(target_object[key], dict) or not contains(target_object[key], value):
                return False
        elif target_object[key] != value:
            return False
    return True

if mode == "check":
    if contains(target, source):
        raise SystemExit(0)
    print("目标配置缺少仓库配置", file=sys.stderr)
    raise SystemExit(1)

if mode != "merge":
    print(f"未知设置操作：{mode}", file=sys.stderr)
    raise SystemExit(2)

changed = False

def merge(target_object, source_object, path):
    global changed
    for key, value in source_object.items():
        property_path = f"{path}.{key}"
        if key not in target_object:
            target_object[key] = value
            changed = True
            continue
        if isinstance(value, dict) and isinstance(target_object[key], dict):
            merge(target_object[key], value, property_path)
        elif target_object[key] != value:
            target_object[key] = value
            changed = True

merge(target, source, "$")
if not changed:
    print("unchanged")
    raise SystemExit(0)

temporary_path = Path(temporary_name)
temporary_path.write_text(json.dumps(target, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("changed")
PY
}

install_claude_settings() {
  local source=$1
  local destination=$2
  local temporary="${destination}.tmp.$$"
  local result

  if [[ ! -e "${destination}" && ! -L "${destination}" ]]; then
    cp "${source}" "${destination}"
    printf '已创建 Claude 设置：%s\n' "${destination}"
    return
  fi

  if [[ -L "${destination}" || -d "${destination}" ]]; then
    backup_item "${destination}"
    cp "${source}" "${destination}"
    printf '已重建 Claude 设置：%s\n' "${destination}"
    return
  fi

  result=$(run_settings_json_tool merge "${source}" "${destination}" "${temporary}")
  case "${result}" in
    unchanged)
      printf 'Claude 设置已包含仓库配置：%s\n' "${destination}"
      ;;
    changed)
      backup_item "${destination}"
      mv "${temporary}" "${destination}"
      printf '已合并 Claude 设置：%s\n' "${destination}"
      ;;
    *)
      rm -f "${temporary}"
      printf '设置合并返回未知状态：%s\n' "${result}" >&2
      return 1
      ;;
  esac
}

check_skill() {
  local source=$1
  local destination=$2

  if [[ -L "${destination}" && "$(readlink "${destination}")" == "${source}" ]]; then
    printf 'Skill 状态一致：%s\n' "${destination}"
    return 0
  fi

  printf 'Skill 状态不一致：%s 应链接到 %s\n' "${destination}" "${source}" >&2
  return 1
}

check_stale_managed_links() {
  local target_dir=$1
  local destination
  local link_target
  local status=0

  [[ -d "${target_dir}" ]] || return 0

  shopt -s nullglob
  for destination in "${target_dir}"/*; do
    [[ -L "${destination}" ]] || continue
    link_target=$(readlink "${destination}")
    if [[ "${link_target}" == "${SOURCE_DIR}/"* && ! -e "${link_target}" ]]; then
      printf '存在陈旧 Skill 链接：%s -> %s\n' "${destination}" "${link_target}" >&2
      status=1
    fi
  done
  shopt -u nullglob

  return "${status}"
}

check_global_agents() {
  local source=$1
  local destination=$2

  if [[ ! -L "${destination}" && -f "${destination}" ]] &&
    cmp -s "${source}" "${destination}"; then
    printf '全局提示词状态一致：%s\n' "${destination}"
    return 0
  fi

  printf '全局提示词状态不一致：%s\n' "${destination}" >&2
  return 1
}

check_claude_settings() {
  local source=$1
  local destination=$2

  if [[ -f "${destination}" ]] && run_settings_json_tool check "${source}" "${destination}"; then
    printf 'Claude 设置状态一致：%s\n' "${destination}"
    return 0
  fi

  printf 'Claude 设置状态不一致：%s 缺少仓库配置\n' "${destination}" >&2
  return 1
}

check_installation() {
  local source
  local target_dir
  local status=0

  shopt -s nullglob
  for source in "${SOURCE_DIR}"/*; do
    [[ -d "${source}" ]] || continue
    if ! skill_supports_platform "${source}" "${PLATFORM}"; then
      continue
    fi
    for target_dir in "${SKILL_TARGET_DIRS[@]}"; do
      if ! check_skill "${source}" "${target_dir}/$(basename "${source}")"; then
        status=1
      fi
    done
  done
  shopt -u nullglob

  for target_dir in "${SKILL_TARGET_DIRS[@]}"; do
    if ! check_stale_managed_links "${target_dir}"; then
      status=1
    fi
  done
  if ! check_global_agents "${GLOBAL_AGENTS_SOURCE}" "${CODEX_AGENTS_TARGET}"; then
    status=1
  fi
  if ! check_global_agents "${GLOBAL_CLAUDE_SOURCE}" "${CLAUDE_AGENTS_TARGET}"; then
    status=1
  fi
  if ! check_claude_settings "${CLAUDE_SETTINGS_SOURCE}" "${CLAUDE_SETTINGS_TARGET}"; then
    status=1
  fi

  if ((status == 0)); then
    printf '安装状态一致\n'
    return 0
  fi

  printf '安装状态不一致，请运行 %s 完成收敛\n' "$0" >&2
  return 1
}

if [[ "${MODE}" == "check" ]]; then
  if check_installation; then
    exit 0
  fi
  exit 1
fi

run_settings_json_tool validate "${CLAUDE_SETTINGS_SOURCE}"

mkdir -p "${SKILL_TARGET_DIRS[@]}" "${CODEX_TARGET_DIR}" "${CLAUDE_TARGET_DIR}"

shopt -s nullglob
for source in "${SOURCE_DIR}"/*; do
  [[ -d "${source}" ]] || continue
  if ! skill_supports_platform "${source}" "${PLATFORM}"; then
    continue
  fi
  for target_dir in "${SKILL_TARGET_DIRS[@]}"; do
    install_skill "${source}" "${target_dir}/$(basename "${source}")"
  done
done
shopt -u nullglob

for target_dir in "${SKILL_TARGET_DIRS[@]}"; do
  remove_stale_managed_links "${target_dir}"
done
install_global_agents "${GLOBAL_AGENTS_SOURCE}" "${CODEX_AGENTS_TARGET}"
install_global_agents "${GLOBAL_CLAUDE_SOURCE}" "${CLAUDE_AGENTS_TARGET}"
install_claude_settings "${CLAUDE_SETTINGS_SOURCE}" "${CLAUDE_SETTINGS_TARGET}"
