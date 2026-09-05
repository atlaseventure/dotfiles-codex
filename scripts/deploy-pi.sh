#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "${SCRIPT_DIR}")
SOURCE_DIR="${REPO_ROOT}/pi"
GLOBAL_AGENTS_SOURCE="${REPO_ROOT}/agents/AGENTS.md"
HOME_DIR="${HOME:?HOME 未设置}"
PI_CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME_DIR}/.pi/agent}"
CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}"
MAGIC_CONTEXT_TARGET="${CONFIG_HOME}/cortexkit/magic-context.jsonc"
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
MODE=install
STAGED_DIR=$(mktemp -d)
trap 'rm -rf "${STAGED_DIR}"' EXIT

fail() {
  printf 'Pi 配置部署失败：%s\n' "$1" >&2
  exit 1
}

usage() {
  printf '用法：%s [--check]\n' "$0"
  printf '\n'
  printf '默认将仓库中的 Pi 配置部署到当前用户主机。\n'
  printf '%s\n' '--check 只检查目标状态，不创建目录、备份或文件。'
}

if (($# > 1)); then
  usage >&2
  exit 2
fi

if (($# == 1)); then
  case "$1" in
    --check) MODE=check ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf '未知参数：%s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

command -v node >/dev/null 2>&1 || fail '缺少 Node.js（用于安全合并 JSON 配置）'

SOURCE_SETTINGS="${SOURCE_DIR}/settings.json"
SOURCE_MODELS="${SOURCE_DIR}/models.json"
SOURCE_MCP="${SOURCE_DIR}/mcp.json"
SOURCE_MAGIC_CONTEXT="${SOURCE_DIR}/cortexkit/magic-context.jsonc"
SOURCE_GPT_RESPONSES_FIX="${SOURCE_DIR}/extensions/gpt-responses-fix.ts"

for source in "${SOURCE_SETTINGS}" "${SOURCE_MODELS}" "${SOURCE_MCP}" "${SOURCE_MAGIC_CONTEXT}"; do
  [[ -f "${source}" ]] || fail "仓库配置文件不存在：${source}"
done
[[ -f "${GLOBAL_AGENTS_SOURCE}" ]] || fail "共享全局提示词源文件不存在：${GLOBAL_AGENTS_SOURCE}"
[[ -f "${SOURCE_GPT_RESPONSES_FIX}" ]] || fail "仓库 Pi 扩展不存在：${SOURCE_GPT_RESPONSES_FIX}"

# 仓库源文件禁止出现会随主机变化或包含凭据的字段。
node - "${SOURCE_SETTINGS}" "${SOURCE_MODELS}" "${SOURCE_MCP}" <<'NODE'
const fs = require("node:fs");

const paths = process.argv.slice(2);
const forbidden = /^(baseUrl|apiKey|api_key|headers|bearerToken|bearerTokenEnv|clientSecret|password|secret|token)$/i;

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`${file}: ${error.message}`);
  }
}

function validate(value, file, path = "$") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => validate(item, file, `${path}[${index}]`));
    return;
  }
  if (value === null || typeof value !== "object") return;

  for (const [key, child] of Object.entries(value)) {
    if (forbidden.test(key)) {
      throw new Error(`${file}: ${path}.${key} 属于主机本地或敏感字段，不能提交到仓库`);
    }
    validate(child, file, `${path}.${key}`);
  }
}

for (const file of paths) validate(readJson(file), file);
NODE

stage_json() {
  local kind=$1
  local source=$2
  local target=$3
  local staged=$4

  node - "${kind}" "${source}" "${target}" >"${staged}" <<'NODE'
const fs = require("node:fs");

const [kind, sourcePath, targetPath] = process.argv.slice(2);
const localModelKeys = ["baseUrl", "apiKey", "headers"];
const localMcpKeys = ["env", "headers", "bearerToken", "bearerTokenEnv", "url"];

function readJson(file) {
  if (!fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`${file}: ${error.message}`);
  }
}

function has(object, key) {
  return object !== null && typeof object === "object" &&
    Object.prototype.hasOwnProperty.call(object, key);
}

function preserveKeys(source, existing, keys) {
  const result = { ...source };
  if (existing === null || typeof existing !== "object" || Array.isArray(existing)) {
    return result;
  }
  for (const key of keys) {
    if (has(existing, key)) result[key] = existing[key];
  }
  return result;
}

function mergeModels(source, existing) {
  const sourceProviders = source.providers ?? {};
  const existingProviders = existing.providers ?? {};
  const providers = {};

  for (const [name, provider] of Object.entries(sourceProviders)) {
    providers[name] = preserveKeys(provider, existingProviders[name], localModelKeys);
  }
  for (const [name, provider] of Object.entries(existingProviders)) {
    if (!has(sourceProviders, name)) providers[name] = provider;
  }

  return { ...source, providers };
}

function mergeMcpServer(source, existing) {
  const result = preserveKeys(source, existing, localMcpKeys);
  if (existing && typeof existing.oauth === "object" && existing.oauth !== null) {
    result.oauth = preserveKeys(source.oauth ?? {}, existing.oauth, ["clientSecret"]);
  }
  return result;
}

function mergeMcp(source, existing) {
  const sourceServers = source.mcpServers ?? {};
  const existingServers = existing.mcpServers ?? {};
  const mcpServers = {};

  for (const [name, server] of Object.entries(sourceServers)) {
    mcpServers[name] = mergeMcpServer(server, existingServers[name]);
  }
  for (const [name, server] of Object.entries(existingServers)) {
    if (!has(sourceServers, name)) mcpServers[name] = server;
  }

  return { ...source, mcpServers };
}

const source = readJson(sourcePath);
const existing = readJson(targetPath);
let result;

switch (kind) {
  case "settings":
    result = preserveKeys(source, existing, ["lastChangelogVersion"]);
    break;
  case "models":
    result = mergeModels(source, existing);
    break;
  case "mcp":
    result = mergeMcp(source, existing);
    break;
  default:
    throw new Error(`未知配置类型：${kind}`);
}

process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
NODE
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

json_files_equal() {
  local left=$1
  local right=$2

  [[ -f "${right}" ]] || return 1
  node - "${left}" "${right}" <<'NODE'
const fs = require("node:fs");

function read(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}

const [left, right] = process.argv.slice(2);
process.exit(JSON.stringify(stable(read(left))) === JSON.stringify(stable(read(right))) ? 0 : 1);
NODE
}

unique_backup_path() {
  local path=$1
  local candidate="${path}.bak.${TIMESTAMP}"
  local suffix=1

  while [[ -e "${candidate}" || -L "${candidate}" ]]; do
    candidate="${path}.bak.${TIMESTAMP}.${suffix}"
    ((suffix += 1))
  done

  printf '%s\n' "${candidate}"
}

backup_item() {
  local path=$1
  local backup
  backup=$(unique_backup_path "${path}")
  mv -- "${path}" "${backup}"
  printf '已备份 %s -> %s\n' "${path}" "${backup}"
}

STAGED_SETTINGS="${STAGED_DIR}/settings.json"
STAGED_MODELS="${STAGED_DIR}/models.json"
STAGED_MCP="${STAGED_DIR}/mcp.json"
STAGED_MAGIC_CONTEXT="${STAGED_DIR}/magic-context.jsonc"
STAGED_GLOBAL_AGENTS="${STAGED_DIR}/AGENTS.md"
STAGED_GPT_RESPONSES_FIX="${STAGED_DIR}/gpt-responses-fix.ts"

stage_json settings "${SOURCE_SETTINGS}" "${PI_CONFIG_DIR}/settings.json" "${STAGED_SETTINGS}"
stage_json models "${SOURCE_MODELS}" "${PI_CONFIG_DIR}/models.json" "${STAGED_MODELS}"
stage_json mcp "${SOURCE_MCP}" "${PI_CONFIG_DIR}/mcp.json" "${STAGED_MCP}"
cp -- "${SOURCE_MAGIC_CONTEXT}" "${STAGED_MAGIC_CONTEXT}"
cp -- "${GLOBAL_AGENTS_SOURCE}" "${STAGED_GLOBAL_AGENTS}"
cp -- "${SOURCE_GPT_RESPONSES_FIX}" "${STAGED_GPT_RESPONSES_FIX}"

check_file() {
  local staged=$1
  local target=$2
  local description=$3
  local mode=$4
  local comparison=${5:-json}
  local actual_mode

  if [[ -L "${target}" || ! -f "${target}" ]]; then
    printf '存在漂移：%s（目标不是普通文件）\n' "${description}" >&2
    return 1
  fi
  if [[ "${comparison}" == 'bytes' ]]; then
    if ! cmp -s "${staged}" "${target}"; then
      printf '存在漂移：%s\n' "${description}" >&2
      return 1
    fi
  elif ! json_files_equal "${staged}" "${target}"; then
    printf '存在漂移：%s\n' "${description}" >&2
    return 1
  fi
  actual_mode=$(file_mode "${target}")
  if [[ "${actual_mode}" != "${mode}" ]]; then
    printf '权限不正确：%s 应为 %s，当前为 %s\n' "${description}" "${mode}" "${actual_mode}" >&2
    return 1
  fi
  printf '状态一致：%s\n' "${description}"
}

install_file() {
  local staged=$1
  local target=$2
  local description=$3
  local mode=$4
  local comparison=${5:-json}
  local actual_mode

  mkdir -p -- "$(dirname "${target}")"
  if [[ -f "${target}" && ! -L "${target}" ]]; then
    if [[ "${comparison}" == 'bytes' ]]; then
      if cmp -s "${staged}" "${target}"; then
        printf '已是最新状态：%s\n' "${description}"
        return
      fi
    elif json_files_equal "${staged}" "${target}"; then
      actual_mode=$(file_mode "${target}")
      if [[ "${actual_mode}" == "${mode}" ]]; then
        printf '已是最新状态：%s\n' "${description}"
        return
      fi
      chmod "${mode}" "${target}"
      printf '已修正权限：%s -> %s\n' "${description}" "${mode}"
      return
    fi
    backup_item "${target}"
  elif [[ -e "${target}" || -L "${target}" ]]; then
    backup_item "${target}"
  fi

  chmod "${mode}" "${staged}"
  mv -- "${staged}" "${target}"
  printf '已部署 %s <- %s\n' "${description}" "${target}"
}

if [[ "${MODE}" == "check" ]]; then
  status=0
  check_file "${STAGED_SETTINGS}" "${PI_CONFIG_DIR}/settings.json" 'Pi settings.json' 644 || status=1
  check_file "${STAGED_MODELS}" "${PI_CONFIG_DIR}/models.json" 'Pi models.json' 600 || status=1
  check_file "${STAGED_MCP}" "${PI_CONFIG_DIR}/mcp.json" 'Pi MCP 配置' 600 || status=1
  check_file "${STAGED_MAGIC_CONTEXT}" "${MAGIC_CONTEXT_TARGET}" 'Magic Context 配置' 644 bytes || status=1
  check_file "${STAGED_GLOBAL_AGENTS}" "${PI_CONFIG_DIR}/AGENTS.md" 'Pi 全局提示词' 644 bytes || status=1
  check_file "${STAGED_GPT_RESPONSES_FIX}" "${PI_CONFIG_DIR}/extensions/gpt-responses-fix.ts" 'Pi gpt-responses-fix 扩展' 644 bytes || status=1
  if ((status == 0)); then
    printf 'Pi 配置状态一致\n'
    exit 0
  fi
  printf 'Pi 配置状态不一致，请运行 %s 完成部署\n' "$0" >&2
  exit 1
fi

mkdir -p -- "${PI_CONFIG_DIR}"
install_file "${STAGED_SETTINGS}" "${PI_CONFIG_DIR}/settings.json" 'Pi settings.json' 644
install_file "${STAGED_MODELS}" "${PI_CONFIG_DIR}/models.json" 'Pi models.json' 600
install_file "${STAGED_MCP}" "${PI_CONFIG_DIR}/mcp.json" 'Pi MCP 配置' 600
install_file "${STAGED_MAGIC_CONTEXT}" "${MAGIC_CONTEXT_TARGET}" 'Magic Context 配置' 644 bytes
install_file "${STAGED_GLOBAL_AGENTS}" "${PI_CONFIG_DIR}/AGENTS.md" 'Pi 全局提示词' 644 bytes
install_file "${STAGED_GPT_RESPONSES_FIX}" "${PI_CONFIG_DIR}/extensions/gpt-responses-fix.ts" 'Pi gpt-responses-fix 扩展' 644 bytes
