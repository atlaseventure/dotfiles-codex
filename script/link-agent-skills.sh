#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h}
SOURCE_DIR="${REPO_ROOT}/skills"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "skills source directory not found: ${SOURCE_DIR}" >&2
  exit 1
fi

TARGET="${HOME}/.agents/skills"

timestamp=$(date +"%Y%m%d%H%M%S")

mkdir -p "${TARGET}"

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
