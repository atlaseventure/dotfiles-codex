#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <repo-root> [limit] [--include <dir>]... [--exclude <dir>]..."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

root="${1:-.}"
if (( $# > 0 )); then
  shift
fi

limit=40
if (( $# > 0 )) && [[ "$1" != --* ]]; then
  limit="$1"
  shift
fi

include_dirs=()
exclude_dirs=()
while (( $# > 0 )); do
  case "$1" in
    --include|--exclude)
      option="$1"
      if (( $# < 2 )) || [[ "$2" == --* ]]; then
        echo "error: $option requires a directory" >&2
        exit 1
      fi
      if [[ "$option" == "--include" ]]; then
        include_dirs+=("$2")
      else
        exclude_dirs+=("$2")
      fi
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required" >&2
  exit 1
fi
if [[ ! -d "$root" ]]; then
  echo "error: repository root does not exist: $root" >&2
  exit 1
fi
if [[ ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: limit must be a positive integer" >&2
  exit 1
fi

cd "$root"
root_path="$(pwd -P)"

normalize_dir() {
  local directory="$1"

  while [[ "$directory" == ./* ]]; do
    directory="${directory#./}"
  done
  while [[ "$directory" == */ && "$directory" != "/" ]]; do
    directory="${directory%/}"
  done
  [[ -n "$directory" ]] || directory="."

  case "$directory" in
    /*|..|../*|*/..|*/../*) return 1 ;;
  esac
  printf '%s\n' "$directory"
}

validate_dir() {
  local kind="$1"
  local directory="$2"
  local normalized
  local resolved

  if ! normalized="$(normalize_dir "$directory")"; then
    echo "error: $kind directory must stay within the repository: $directory" >&2
    return 1
  fi
  if [[ ! -d "$normalized" ]]; then
    echo "error: $kind directory does not exist: $directory" >&2
    return 1
  fi
  resolved="$(cd "$normalized" && pwd -P)"
  case "$resolved/" in
    "$root_path/"*) ;;
    *)
      echo "error: $kind directory must stay within the repository: $directory" >&2
      return 1
      ;;
  esac
  if [[ "$resolved" == "$root_path" ]]; then
    normalized="."
  else
    normalized="${resolved#"$root_path"/}"
  fi
  printf '%s\n' "$normalized"
}

normalized_include_dirs=()
for include_dir in "${include_dirs[@]}"; do
  normalized="$(validate_dir "include" "$include_dir")" || exit 1
  normalized_include_dirs+=("$normalized")
done
include_dirs=("${normalized_include_dirs[@]}")

normalized_exclude_dirs=()
for exclude_dir in "${exclude_dirs[@]}"; do
  normalized="$(validate_dir "exclude" "$exclude_dir")" || exit 1
  normalized_exclude_dirs+=("$normalized")
done
exclude_dirs=("${normalized_exclude_dirs[@]}")

globs=(
  -g '*.c' -g '*.cc' -g '*.cpp' -g '*.cs' -g '*.go' -g '*.h' -g '*.hpp'
  -g '*.java' -g '*.js' -g '*.jsx' -g '*.kt' -g '*.kts' -g '*.php'
  -g '*.py' -g '*.rb' -g '*.rs' -g '*.scala' -g '*.sh' -g '*.swift'
  -g '*.ts' -g '*.tsx' -g '*.vue'
  -g '!**/vendor/**' -g '!**/Vendor/**' -g '!**/Pods/**'
  -g '!**/node_modules/**' -g '!**/dist/**' -g '!**/build/**'
)

files=()
while IFS= read -r file; do
  file="${file#./}"
  excluded=false
  for exclude_dir in "${exclude_dirs[@]}"; do
    if [[ "$exclude_dir" == "." || "$file" == "$exclude_dir/"* ]]; then
      excluded=true
      break
    fi
  done
  "$excluded" && continue
  files+=("$file")
done < <(
  if (( ${#include_dirs[@]} > 0 )); then
    rg --files "${globs[@]}" -- "${include_dirs[@]}"
  else
    rg --files "${globs[@]}"
  fi | sort -u
)
if (( ${#files[@]} == 0 )); then
  echo "No source files found under $(pwd)"
  exit 0
fi

classify() {
  local file="$1"
  case "$file" in
    *_test.go|*.test.*|*.spec.*|*/test/*|*/tests/*|*/__tests__/*) echo "test" ;;
    *.gen.*|*_generated.go|*/generated/*|*/gen/*) echo "generated?" ;;
    *) echo "source" ;;
  esac
}

echo "Largest source files by line count"
for file in "${files[@]}"; do
  lines=$(wc -l < "$file")
  printf '%09d\t%s\t%s\n' "$lines" "$(classify "$file")" "$file"
done | sort -nr | awk -F '\t' -v limit="$limit" 'NR <= limit { sub(/^0+/, "", $1); printf "%7s  %-10s %s\n", $1, $2, $3 }'

echo
echo "Directories by source-file count"
for file in "${files[@]}"; do
  if [[ "$file" == */* ]]; then
    printf '%s\n' "${file%/*}"
  else
    printf '.\n'
  fi
done | sort | uniq -c | sort -nr | awk -v limit="$limit" 'NR <= limit { count = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0); printf "%7d  %s\n", count, $0 }'

echo
echo "Treat these as signals only: inspect responsibilities, consumers, generation rules, and dependency direction before refactoring."
