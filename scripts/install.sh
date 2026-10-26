#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
SOURCE_DIR="${REPO_ROOT}/skills"
GLOBAL_AGENTS_SOURCE="${REPO_ROOT}/agents/AGENTS.md"
GLOBAL_CLAUDE_SOURCE="${REPO_ROOT}/agents/CLAUDE.md"
SKILL_TARGET_DIRS=("${HOME:?HOME 未设置}/.agents/skills" "${HOME}/.claude/skills")
CODEX_TARGET_DIR="${HOME}/.codex"
CODEX_AGENTS_TARGET="${CODEX_TARGET_DIR}/AGENTS.md"
CLAUDE_TARGET_DIR="${HOME}/.claude"
CLAUDE_AGENTS_TARGET="${CLAUDE_TARGET_DIR}/CLAUDE.md"
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
MODE=install
PLATFORM=unix

if (($# > 1)); then
  printf '用法：%s [--check]\n' "$0" >&2
  exit 2
fi

if (($# == 1)); then
  if [[ "$1" != "--check" ]]; then
    printf '未知参数：%s\n' "$1" >&2
    printf '用法：%s [--check]\n' "$0" >&2
    exit 2
  fi
  MODE=check
fi

if [[ ! -d "${SOURCE_DIR}" ]]; then
  printf 'Skill 源目录不存在：%s\n' "${SOURCE_DIR}" >&2
  exit 1
fi

for source in "${GLOBAL_AGENTS_SOURCE}" "${GLOBAL_CLAUDE_SOURCE}"; do
  if [[ ! -f "${source}" ]]; then
    printf '全局提示词源文件不存在：%s\n' "${source}" >&2
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
