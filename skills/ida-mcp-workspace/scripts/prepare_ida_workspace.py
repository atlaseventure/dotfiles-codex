#!/usr/bin/env python3
"""为 IDA MCP 准备绑定 SHA-256 的 D:\\idaworkspace 分析对象。"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PureWindowsPath
from typing import Any

SCHEMA_VERSION = 1
WORKSPACE_WSL_ROOT = Path("/mnt/d/idaworkspace")
WORKSPACE_WINDOWS_ROOT = PureWindowsPath(r"D:\idaworkspace")
REQUIRED_BINDING_FIELDS = {
    "schema_version",
    "sha256",
    "source_path",
    "source_size",
    "source_mtime",
    "windows_input_path",
    "windows_idb_path",
    "created_at",
    "updated_at",
}
WINDOWS_RESERVED_NAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}


class PreparationError(RuntimeError):
    """无法安全准备分析对象时抛出。"""


def utc_now() -> str:
    return (
        datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_source(path_text: str) -> tuple[Path, os.stat_result, str]:
    source = Path(path_text).expanduser().absolute()
    if not source.exists():
        raise PreparationError(f"源文件不存在: {source}")
    if not source.is_file():
        raise PreparationError(f"源路径不是普通文件: {source}")

    before = source.stat()
    digest = sha256_file(source)
    after = source.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise PreparationError(f"计算哈希期间源文件发生变化: {source}")
    return source, after, digest


def safe_windows_filename(name: str) -> str:
    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).rstrip(" .")
    if not safe:
        safe = "input.bin"
    if safe.split(".", 1)[0].upper() in WINDOWS_RESERVED_NAMES:
        safe = f"_{safe}"
    return safe[:120]


def safe_session_name(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._-")
    return (safe or "binary")[:80]


def windows_path_for(
    path: Path, workspace_wsl_root: Path, windows_root: PureWindowsPath
) -> str:
    try:
        relative = path.absolute().relative_to(workspace_wsl_root.absolute())
    except ValueError as error:
        raise PreparationError(f"工作区路径越界: {path}") from error
    return str(windows_root.joinpath(*relative.parts))


def wsl_path_for(
    value: str, workspace_wsl_root: Path, windows_root: PureWindowsPath
) -> Path:
    if not isinstance(value, str) or not value:
        raise PreparationError("绑定中的 Windows 路径为空或类型错误")
    candidate = PureWindowsPath(value)
    if not candidate.is_absolute():
        raise PreparationError(f"绑定路径不是 Windows 绝对路径: {value}")
    try:
        relative = candidate.relative_to(windows_root)
    except ValueError as error:
        raise PreparationError(f"绑定路径不在 {windows_root} 下: {value}") from error
    return workspace_wsl_root.joinpath(*relative.parts)


def ensure_inside(path: Path, directory: Path, label: str) -> None:
    try:
        path.absolute().relative_to(directory.absolute())
    except ValueError as error:
        raise PreparationError(f"{label} 越过当前 SHA-256 分析目录: {path}") from error


def source_mtime(stat_result: os.stat_result) -> str:
    return (
        datetime.fromtimestamp(stat_result.st_mtime, timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def atomic_copy(source: Path, target: Path, expected_sha256: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_stream:
            shutil.copyfileobj(input_stream, output, length=1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
        if sha256_file(temporary) != expected_sha256:
            raise PreparationError("临时副本 SHA-256 与源文件不一致")
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def read_binding(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            binding = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise PreparationError(f"binding.json 无法解析: {error}") from error
    if not isinstance(binding, dict):
        raise PreparationError("binding.json 顶层必须是 JSON 对象")
    missing = sorted(REQUIRED_BINDING_FIELDS - binding.keys())
    if missing:
        raise PreparationError(f"binding.json 缺少字段: {', '.join(missing)}")
    if binding["schema_version"] != SCHEMA_VERSION:
        raise PreparationError(
            f"不支持的 binding schema_version: {binding['schema_version']!r}"
        )
    if not isinstance(binding["source_size"], int) or binding["source_size"] < 0:
        raise PreparationError("binding.json 的 source_size 无效")
    for field in REQUIRED_BINDING_FIELDS - {"schema_version", "source_size"}:
        if not isinstance(binding[field], str) or not binding[field]:
            raise PreparationError(f"binding.json 的 {field} 无效")
    return binding


def validate_binding(
    binding: dict[str, Any],
    digest: str,
    object_dir: Path,
    workspace_wsl_root: Path,
    windows_root: PureWindowsPath,
) -> tuple[Path, Path]:
    if binding["sha256"] != digest:
        raise PreparationError(
            f"binding.json SHA-256 不匹配: {binding['sha256']} != {digest}"
        )

    input_path = wsl_path_for(
        binding["windows_input_path"], workspace_wsl_root, windows_root
    )
    idb_path = wsl_path_for(
        binding["windows_idb_path"], workspace_wsl_root, windows_root
    )
    ensure_inside(input_path, object_dir / "input", "输入副本")
    ensure_inside(idb_path, object_dir / "database", "IDA 数据库")
    if input_path.is_symlink():
        raise PreparationError(f"绑定的工作区副本不能是符号链接: {input_path}")
    expected_idb = object_dir / "database" / f"{input_path.name}.i64"
    if idb_path != expected_idb:
        raise PreparationError(
            f"windows_idb_path 不符合固定位置: {binding['windows_idb_path']}"
        )
    if not input_path.is_file():
        raise PreparationError(f"绑定的工作区副本不存在: {input_path}")
    actual_digest = sha256_file(input_path)
    if actual_digest != digest:
        raise PreparationError(
            f"工作区副本 SHA-256 不匹配: {actual_digest} != {digest}"
        )
    return input_path, idb_path


def matching_input(input_dir: Path, expected_path: Path, digest: str) -> Path | None:
    if expected_path.is_file() and sha256_file(expected_path) == digest:
        return expected_path
    matches = [
        path
        for path in input_dir.iterdir()
        if path.is_file() and sha256_file(path) == digest
    ]
    if len(matches) > 1:
        raise PreparationError("输入目录存在多个同哈希副本，无法确定唯一绑定")
    return matches[0] if matches else None


def invalid_backup_path(path: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate = path.with_name(f"{path.name}.invalid-{stamp}")
    sequence = 1
    while candidate.exists():
        candidate = path.with_name(f"{path.name}.invalid-{stamp}-{sequence}")
        sequence += 1
    return candidate


def recover_input(source: Path, input_path: Path, digest: str, repair: bool) -> Path:
    input_path.parent.mkdir(parents=True, exist_ok=True)
    existing_match = matching_input(input_path.parent, input_path, digest)
    if existing_match is not None:
        return existing_match
    if input_path.exists():
        if not repair:
            raise PreparationError(
                f"目标输入路径已被不同内容占用: {input_path}; 确认后使用 --repair"
            )
        os.replace(input_path, invalid_backup_path(input_path))
    atomic_copy(source, input_path, digest)
    return input_path


def prepare(
    source_text: str,
    repair: bool = False,
    workspace_wsl_root: Path = WORKSPACE_WSL_ROOT,
    windows_root: PureWindowsPath = WORKSPACE_WINDOWS_ROOT,
) -> dict[str, Any]:
    source, stat_result, digest = stable_source(source_text)
    object_dir = workspace_wsl_root / "objects" / digest
    binding_path = object_dir / "binding.json"
    input_dir = object_dir / "input"
    database_dir = object_dir / "database"
    output_dir = object_dir / "output"
    safe_name = safe_windows_filename(source.name)
    default_input_path = input_dir / safe_name

    object_dir.mkdir(parents=True, exist_ok=True)
    lock_path = object_dir / ".prepare.lock"
    with lock_path.open("a", encoding="utf-8") as lock_stream:
        fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX)
        had_binding = binding_path.exists()
        binding_error: PreparationError | None = None
        binding: dict[str, Any] | None = None
        input_path: Path | None = None
        idb_path: Path | None = None

        if had_binding:
            try:
                binding = read_binding(binding_path)
                input_path, idb_path = validate_binding(
                    binding, digest, object_dir, workspace_wsl_root, windows_root
                )
            except PreparationError as error:
                binding_error = error
                if not repair:
                    raise PreparationError(
                        f"绑定校验失败: {error}; 确认后使用 --repair"
                    ) from error

        if input_path is None:
            recovery_target = default_input_path
            if binding is not None:
                try:
                    recovery_target = wsl_path_for(
                        binding["windows_input_path"], workspace_wsl_root, windows_root
                    )
                    ensure_inside(recovery_target, input_dir, "输入副本")
                except PreparationError:
                    recovery_target = default_input_path
            input_path = recover_input(source, recovery_target, digest, repair)
            idb_path = object_dir / "database" / f"{input_path.name}.i64"

        assert idb_path is not None
        database_dir.mkdir(parents=True, exist_ok=True)
        output_dir.mkdir(parents=True, exist_ok=True)
        now = utc_now()
        created_at = (
            binding.get("created_at", now) if isinstance(binding, dict) else now
        )
        new_binding = {
            "schema_version": SCHEMA_VERSION,
            "sha256": digest,
            "source_path": str(source),
            "source_size": stat_result.st_size,
            "source_mtime": source_mtime(stat_result),
            "windows_input_path": windows_path_for(
                input_path, workspace_wsl_root, windows_root
            ),
            "windows_idb_path": windows_path_for(
                idb_path, workspace_wsl_root, windows_root
            ),
            "created_at": created_at,
            "updated_at": now,
        }
        atomic_write_json(binding_path, new_binding)

        opened_existing_idb = idb_path.is_file()
        idb_open_path = idb_path if opened_existing_idb else input_path
        if binding_error is not None:
            status = "repaired"
        elif had_binding:
            status = "reused"
        else:
            status = "created"

        return {
            "status": status,
            "sha256": digest,
            "binding_path": str(binding_path),
            "windows_input_path": new_binding["windows_input_path"],
            "windows_idb_path": new_binding["windows_idb_path"],
            "windows_output_dir": windows_path_for(
                output_dir, workspace_wsl_root, windows_root
            ),
            "idb_open_path": windows_path_for(
                idb_open_path, workspace_wsl_root, windows_root
            ),
            "opened_existing_idb": opened_existing_idb,
            "preferred_session_id": f"{safe_session_name(input_path.name)}-{digest[:12]}",
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="为 IDA MCP 准备或复用 D:\\idaworkspace 中的 SHA-256 绑定对象"
    )
    parser.add_argument("source", help="待分析源文件的 WSL 路径")
    parser.add_argument(
        "--repair",
        action="store_true",
        help="在原 SHA-256 目录内显式修复损坏绑定或副本",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        result = prepare(arguments.source, repair=arguments.repair)
    except (OSError, PreparationError) as error:
        print(f"错误: {error}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
