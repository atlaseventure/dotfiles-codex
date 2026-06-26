#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h}
SOURCE_DIR="${REPO_ROOT}/skills"
CODEX_AGENTS_SOURCE="${REPO_ROOT}/codex/AGENTS.md"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "skills source directory not found: ${SOURCE_DIR}" >&2
  exit 1
fi

if [[ ! -f "${CODEX_AGENTS_SOURCE}" ]]; then
  echo "Codex AGENTS.md source file not found: ${CODEX_AGENTS_SOURCE}" >&2
  exit 1
fi

TARGET="${HOME}/.agents/skills"
CODEX_TARGET_DIR="${HOME}/.codex"
CODEX_AGENTS_TARGET="${CODEX_TARGET_DIR}/AGENTS.md"

timestamp=$(date +"%Y%m%d%H%M%S")

mkdir -p "${TARGET}"
mkdir -p "${CODEX_TARGET_DIR}"

unique_backup_path() {
  local base=$1
  local candidate="${base}.bak.${timestamp}"
  local suffix=1

  while [[ -e "${candidate}" || -L "${candidate}" ]]; do
    candidate="${base}.bak.${timestamp}.${suffix}"
    (( suffix++ ))
  done

  print -r -- "${candidate}"
}

for src in "${SOURCE_DIR}"/*; do
  [[ -d "${src}" ]] || continue

  name=${src:t}
  dest="${TARGET}/${name}"

  if [[ -e "${dest}" && ! -L "${dest}" ]]; then
    backup="${dest}.bak.${timestamp}"
    mv "${dest}" "${backup}"
    echo "backed up ${dest} -> ${backup}"
  fi

  ln -sfn "${src}" "${dest}"
  echo "linked ${dest} -> ${src}"
done

if [[ -e "${CODEX_AGENTS_TARGET}" || -L "${CODEX_AGENTS_TARGET}" ]]; then
  backup=$(unique_backup_path "${CODEX_AGENTS_TARGET}")
  mv "${CODEX_AGENTS_TARGET}" "${backup}"
  echo "backed up ${CODEX_AGENTS_TARGET} -> ${backup}"
fi

cp "${CODEX_AGENTS_SOURCE}" "${CODEX_AGENTS_TARGET}"
echo "copied ${CODEX_AGENTS_TARGET} <- ${CODEX_AGENTS_SOURCE}"
