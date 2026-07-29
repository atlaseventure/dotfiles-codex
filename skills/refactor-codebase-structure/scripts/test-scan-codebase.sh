#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scanner="${script_dir}/scan-codebase.sh"
temp_root=$(mktemp -d)
trap 'rm -r "${temp_root}"' EXIT
repo="${temp_root}/repo"

fail() {
  printf '测试失败：%s\n' "$1" >&2
  exit 1
}

write_lines() {
  local count=$1
  local target=$2
  local index

  : >"${target}"
  for ((index = 1; index <= count; index += 1)); do
    printf 'line %d\n' "${index}" >>"${target}"
  done
}

mkdir -p \
  "${repo}/src/generated" \
  "${repo}/tools" \
  "${repo}/vendor"
write_lines 3 "${repo}/src/keep.c"
write_lines 30 "${repo}/src/generated/skip.c"
write_lines 20 "${repo}/tools/tool.c"
write_lines 40 "${repo}/vendor/vendor.c"

default_output=$("${scanner}" "${repo}" 40)
[[ "${default_output}" == *"src/keep.c"* ]] || fail '默认扫描遗漏源码'
[[ "${default_output}" == *"tools/tool.c"* ]] || fail '默认扫描遗漏其他目录'
[[ "${default_output}" != *"vendor/vendor.c"* ]] || fail '默认扫描未排除 vendor'

scoped_output=$(
  "${scanner}" "${repo}" 40 \
    --include src \
    --include tools \
    --exclude src/generated
)
[[ "${scoped_output}" == *"src/keep.c"* ]] || fail '指定目录扫描遗漏源码'
[[ "${scoped_output}" == *"tools/tool.c"* ]] || fail '重复 include 未生效'
[[ "${scoped_output}" != *"src/generated/skip.c"* ]] || fail 'exclude 未生效'

excluded_output=$("${scanner}" "${repo}" 40 --exclude tools)
[[ "${excluded_output}" == *"src/keep.c"* ]] || fail '仅使用 exclude 时遗漏其他源码'
[[ "${excluded_output}" != *"tools/tool.c"* ]] || fail '仅使用 exclude 时未排除目录'

if missing_output=$("${scanner}" "${repo}" 40 --include missing 2>&1); then
  fail '不存在的 include 目录未快速失败'
fi
[[ "${missing_output}" == "error: include directory does not exist: missing" ]] ||
  fail '不存在的 include 目录诊断不准确'

if outside_output=$("${scanner}" "${repo}" 40 --exclude ../outside 2>&1); then
  fail '越界的 exclude 目录未快速失败'
fi
[[ "${outside_output}" == "error: exclude directory must stay within the repository: ../outside" ]] ||
  fail '越界的 exclude 目录诊断不准确'

if argument_output=$("${scanner}" "${repo}" 40 --include 2>&1); then
  fail '缺少 include 参数时未快速失败'
fi
[[ "${argument_output}" == "error: --include requires a directory" ]] ||
  fail '缺少 include 参数时诊断不准确'

printf '扫描范围行为测试通过\n'
