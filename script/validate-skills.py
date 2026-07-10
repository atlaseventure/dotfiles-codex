#!/usr/bin/env python3
"""验证本仓库所有 Skill 的结构、元数据和调用策略。"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
HAN_PATTERN = re.compile(r"[\u3400-\u9fff]")
MAX_NAME_LENGTH = 64
MAX_DESCRIPTION_LENGTH = 1024
MIN_SHORT_DESCRIPTION_LENGTH = 25
MAX_SHORT_DESCRIPTION_LENGTH = 64


class ValidationError(Exception):
    """表示 Skill 契约不成立。"""


def parse_quoted_string(value: str, path: Path, line_number: int) -> str:
    if not value.startswith('"'):
        raise ValidationError(f"{path}:{line_number} 字符串值必须使用双引号")

    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValidationError(
            f"{path}:{line_number} 字符串格式无效：{error.msg}"
        ) from error

    if not isinstance(parsed, str):
        raise ValidationError(f"{path}:{line_number} 预期字符串值")
    return parsed


def parse_frontmatter(path: Path) -> tuple[dict[str, str], str]:
    content = path.read_text(encoding="utf-8")
    lines = content.splitlines()
    if not lines or lines[0] != "---":
        raise ValidationError(f"{path}:1 缺少 YAML frontmatter 起始标记")

    try:
        closing_index = lines.index("---", 1)
    except ValueError as error:
        raise ValidationError(f"{path}: 缺少 YAML frontmatter 结束标记") from error

    values: dict[str, str] = {}
    for index, line in enumerate(lines[1:closing_index], start=2):
        if not line.strip():
            continue
        if line.startswith((" ", "\t")) or ":" not in line:
            raise ValidationError(f"{path}:{index} frontmatter 只允许简单键值")

        key, raw_value = line.split(":", 1)
        if key in values:
            raise ValidationError(f"{path}:{index} 重复字段：{key}")
        values[key] = raw_value.strip().strip('"')

    unexpected = set(values) - {"name", "description"}
    if unexpected:
        fields = "、".join(sorted(unexpected))
        raise ValidationError(f"{path}: frontmatter 包含未允许字段：{fields}")

    body = "\n".join(lines[closing_index + 1 :]).strip()
    return values, body


def parse_openai_yaml(path: Path) -> dict[str, dict[str, object]]:
    sections: dict[str, dict[str, object]] = {}
    current_section: str | None = None

    for line_number, line in enumerate(
        path.read_text(encoding="utf-8-sig").splitlines(), start=1
    ):
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        section_match = re.fullmatch(r"([a-z_]+):", line)
        if section_match:
            current_section = section_match.group(1)
            if current_section in sections:
                raise ValidationError(
                    f"{path}:{line_number} 重复区段：{current_section}"
                )
            sections[current_section] = {}
            continue

        field_match = re.fullmatch(r"  ([a-z_]+): (.+)", line)
        if not field_match or current_section is None:
            raise ValidationError(f"{path}:{line_number} 不支持的 YAML 结构")

        key, raw_value = field_match.groups()
        if key in sections[current_section]:
            raise ValidationError(f"{path}:{line_number} 重复字段：{key}")

        if raw_value in {"true", "false"}:
            value: object = raw_value == "true"
        else:
            value = parse_quoted_string(raw_value, path, line_number)
        sections[current_section][key] = value

    return sections


def require_chinese(value: str, label: str, path: Path) -> None:
    if not HAN_PATTERN.search(value):
        raise ValidationError(f"{path}: {label} 必须使用中文")


def validate_skill(skill_dir: Path) -> None:
    skill_path = skill_dir / "SKILL.md"
    metadata_path = skill_dir / "agents" / "openai.yaml"

    if not skill_path.is_file():
        raise ValidationError(f"{skill_path}: 文件不存在")
    if not metadata_path.is_file():
        raise ValidationError(f"{metadata_path}: 文件不存在")

    frontmatter, body = parse_frontmatter(skill_path)
    name = frontmatter.get("name", "").strip()
    description = frontmatter.get("description", "").strip()

    if not name:
        raise ValidationError(f"{skill_path}: 缺少 name")
    if not NAME_PATTERN.fullmatch(name) or len(name) > MAX_NAME_LENGTH:
        raise ValidationError(f"{skill_path}: name 不是有效的 hyphen-case 名称")
    if name != skill_dir.name:
        raise ValidationError(
            f"{skill_path}: name {name} 与目录名 {skill_dir.name} 不一致"
        )
    if not description or len(description) > MAX_DESCRIPTION_LENGTH:
        raise ValidationError(f"{skill_path}: description 为空或过长")
    if "<" in description or ">" in description:
        raise ValidationError(f"{skill_path}: description 不能包含尖括号")
    require_chinese(description, "description", skill_path)
    if not body:
        raise ValidationError(f"{skill_path}: Skill 正文不能为空")

    metadata = parse_openai_yaml(metadata_path)
    if set(metadata) != {"interface", "policy"}:
        raise ValidationError(
            f"{metadata_path}: 只允许且必须包含 interface 与 policy 区段"
        )

    interface = metadata["interface"]
    if set(interface) != {"display_name", "short_description", "default_prompt"}:
        raise ValidationError(
            f"{metadata_path}: interface 字段必须为 display_name、short_description、default_prompt"
        )

    for field in ("display_name", "short_description", "default_prompt"):
        value = interface[field]
        if not isinstance(value, str) or not value.strip():
            raise ValidationError(f"{metadata_path}: {field} 必须是非空字符串")
        require_chinese(value, field, metadata_path)

    short_description = interface["short_description"]
    assert isinstance(short_description, str)
    if not MIN_SHORT_DESCRIPTION_LENGTH <= len(short_description) <= MAX_SHORT_DESCRIPTION_LENGTH:
        raise ValidationError(
            f"{metadata_path}: short_description 长度必须为 "
            f"{MIN_SHORT_DESCRIPTION_LENGTH}-{MAX_SHORT_DESCRIPTION_LENGTH} 个字符"
        )

    default_prompt = interface["default_prompt"]
    assert isinstance(default_prompt, str)
    if f"${name}" not in default_prompt:
        raise ValidationError(
            f"{metadata_path}: default_prompt 必须显式引用 ${name}"
        )

    policy = metadata["policy"]
    if set(policy) != {"allow_implicit_invocation"}:
        raise ValidationError(
            f"{metadata_path}: policy 必须显式声明 allow_implicit_invocation"
        )
    allow_implicit = policy["allow_implicit_invocation"]
    if not isinstance(allow_implicit, bool):
        raise ValidationError(
            f"{metadata_path}: allow_implicit_invocation 必须是布尔值"
        )
    if not allow_implicit and "显式" not in description:
        raise ValidationError(
            f"{skill_path}: 禁止隐式调用时 description 必须说明显式触发条件"
        )


def main() -> int:
    if len(sys.argv) != 2:
        print("用法：python3 script/validate-skills.py <skills目录>", file=sys.stderr)
        return 2

    skills_root = Path(sys.argv[1]).resolve()
    if not skills_root.is_dir():
        print(f"检查失败：Skill 目录不存在：{skills_root}", file=sys.stderr)
        return 1

    skill_dirs = sorted(path for path in skills_root.iterdir() if path.is_dir())
    if not skill_dirs:
        print(f"检查失败：Skill 目录为空：{skills_root}", file=sys.stderr)
        return 1

    try:
        for skill_dir in skill_dirs:
            validate_skill(skill_dir)
            print(f"Skill 契约通过：{skill_dir.name}")
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"检查失败：{error}", file=sys.stderr)
        return 1

    print("全部 Skill 契约通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
