#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
SOURCE_DIR="${REPO_ROOT}/skills"
CODEX_AGENTS_SOURCE="${REPO_ROOT}/codex/AGENTS.md"
TARGET_DIR="${HOME:?HOME 未设置}/.agents/skills"
CODEX_TARGET_DIR="${HOME}/.codex"
CODEX_AGENTS_TARGET="${CODEX_TARGET_DIR}/AGENTS.md"
TIMESTAMP=$(date +"%Y%m%d%H%M%S")

if [[ ! -d "${SOURCE_DIR}" ]]; then
  printf 'Skill 源目录不存在：%s\n' "${SOURCE_DIR}" >&2
  exit 1
fi

if [[ ! -f "${CODEX_AGENTS_SOURCE}" ]]; then
  printf 'Codex AGENTS.md 源文件不存在：%s\n' "${CODEX_AGENTS_SOURCE}" >&2
  exit 1
fi

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

remove_stale_managed_links() {
  local destination
  local link_target

  shopt -s nullglob
  for destination in "${TARGET_DIR}"/*; do
    [[ -L "${destination}" ]] || continue
    link_target=$(readlink "${destination}")
    if [[ "${link_target}" == "${SOURCE_DIR}/"* && ! -e "${link_target}" ]]; then
      rm "${destination}"
      printf '已移除陈旧 Skill 链接：%s\n' "${destination}"
    fi
  done
  shopt -u nullglob
}

install_codex_agents() {
  if [[ -L "${CODEX_AGENTS_TARGET}" || -e "${CODEX_AGENTS_TARGET}" ]]; then
    if [[ ! -L "${CODEX_AGENTS_TARGET}" && -f "${CODEX_AGENTS_TARGET}" ]] &&
      cmp -s "${CODEX_AGENTS_SOURCE}" "${CODEX_AGENTS_TARGET}"; then
      printf 'Codex AGENTS.md 已是最新状态：%s\n' "${CODEX_AGENTS_TARGET}"
      return
    fi
    backup_item "${CODEX_AGENTS_TARGET}"
  fi

  cp "${CODEX_AGENTS_SOURCE}" "${CODEX_AGENTS_TARGET}"
  printf '已复制 %s <- %s\n' "${CODEX_AGENTS_TARGET}" "${CODEX_AGENTS_SOURCE}"
}

mkdir -p "${TARGET_DIR}" "${CODEX_TARGET_DIR}"

shopt -s nullglob
for source in "${SOURCE_DIR}"/*; do
  [[ -d "${source}" ]] || continue
  install_skill "${source}" "${TARGET_DIR}/$(basename "${source}")"
done
shopt -u nullglob

remove_stale_managed_links
install_codex_agents
