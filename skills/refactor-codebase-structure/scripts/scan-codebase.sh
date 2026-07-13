#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
limit="${2:-40}"

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

globs=(
  -g '*.c' -g '*.cc' -g '*.cpp' -g '*.cs' -g '*.go' -g '*.h' -g '*.hpp'
  -g '*.java' -g '*.js' -g '*.jsx' -g '*.kt' -g '*.kts' -g '*.php'
  -g '*.py' -g '*.rb' -g '*.rs' -g '*.scala' -g '*.sh' -g '*.swift'
  -g '*.ts' -g '*.tsx' -g '*.vue'
  -g '!vendor/**' -g '!node_modules/**' -g '!dist/**' -g '!build/**'
)

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(rg --files "${globs[@]}" | sort)
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
