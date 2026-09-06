#!/usr/bin/env python3
"""Noah 图像生成和编辑共用的请求、校验及保存逻辑。"""

import argparse
import base64
import binascii
import io
import json
import math
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

CPA_BASE_URL = os.environ.get("CPA_BASE_URL", "").strip().rstrip("/")
TIMEOUT = 300
DEFAULT_SIZE = "1254x1254"
REQUEST_OPTIONS = {
    "model": "gpt-image-2", "n": 1, "size": DEFAULT_SIZE, "quality": "high",
    "background": "auto", "output_format": "png", "moderation": "low", "stream": False,
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """图像请求不跟随重定向，防止凭据被转发到其他地址。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def parse_size(value):
    if not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("尺寸格式必须为正整数宽x高，例如 1024x1024")
    return value


def image_paths(values):
    paths = []
    for value in values:
        if value.lstrip().startswith("["):
            try:
                items = json.loads(value)
            except json.JSONDecodeError as error:
                raise ValueError("--image 的 JSON 数组格式无效，请使用双引号包围数组内的路径") from error
            if not isinstance(items, list) or not items or any(
                not isinstance(item, str) or not item.strip() for item in items
            ):
                raise ValueError("--image 必须是由非空路径字符串组成的非空数组")
            paths.extend(Path(item) for item in items)
        else:
            paths.append(Path(value))
    if not 1 <= len(paths) <= 16:
        raise ValueError("编辑需要 1 至 16 张输入图像")
    return paths


def arguments(operation):
    action = "编辑" if operation == "edit" else "生成"
    parser = argparse.ArgumentParser(
        description=f"通过提示词字符串或 @文件路径{action}图像，尺寸、画质和背景选项仅作为提示词建议。",
        allow_abbrev=False,
    )
    parser.add_argument("--prompt", required=True, help="提示词字符串，或 @文件路径（UTF-8）")
    parser.add_argument("--output", required=True, type=Path, help="完整图像输出路径，不允许覆盖已有路径")
    parser.add_argument("--size", type=parse_size, default=DEFAULT_SIZE, help="提示词中的建议尺寸，不能保证精确像素（默认：%(default)s）")
    parser.add_argument("--quality", choices=["low", "medium", "high", "auto"], default="high", help="提示词中的建议画质（默认：%(default)s）")
    parser.add_argument("--background", choices=["opaque", "transparent", "auto"], default="auto", help="提示词中的建议背景，不能保证透明度（默认：%(default)s）")
    if operation == "edit":
        parser.add_argument("--image", required=True, action="extend", nargs="+",
                            help='输入图像的 JSON 路径数组，如 \'["a.png","b.png"]\'；也支持路径列表及重复此选项，最多 16 张')
        parser.add_argument("--mask", type=Path,
                            help="可选 PNG 蒙版；使用后保留接口返回图，并另存 <输出名>.composed.png 本地合成图")
    args = parser.parse_args()
    if operation == "edit":
        try:
            args.image = image_paths(args.image)
        except ValueError as error:
            parser.error(str(error))
    return args


def payload_for(args):
    prompt = args.prompt
    if prompt.startswith("@"):
        if len(prompt) == 1:
            raise ValueError("@ 后必须提供提示词文件路径")
        prompt = Path(prompt[1:]).read_text(encoding="utf-8-sig")
    if not prompt or not prompt.strip():
        raise ValueError("提示词不能为空")
    width, height = map(int, args.size.split("x"))
    divisor = math.gcd(width, height)
    orientation = "正方形" if width == height else "横向" if width > height else "纵向"
    quality = {
        "high": "高画质，细节充分且符合指定画风，边缘干净，无非预期模糊和压缩伪影。",
        "medium": "中等细节密度，主体与轮廓清晰，画面干净，保持指定画风。",
        "low": "基础画质，简化细节，优先保证主体、构图和指定画风清楚。",
        "auto": "依据画面用途选择合适的细节密度，保持指定画风与清晰度。",
    }[args.quality]
    prompt = (f"{prompt.strip()}\n\n输出要求：{orientation}构图，宽高比 "
              f"{width // divisor}:{height // divisor}，目标尺寸宽 {width} 像素、高 {height} 像素。{quality}")
    prompt += {
        "transparent": "输出真实透明背景，仅保留主体和明确要求的前景；其余区域完全透明，使用 Alpha 透明通道。不要用白色、黑色或棋盘格图案模拟透明。",
        "opaque": "背景完全不透明，不保留透明或半透明区域；背景内容遵循主体描述。",
        "auto": "根据主体、场景和用途选择合适的背景。",
    }[args.background]
    return {**REQUEST_OPTIONS, "prompt": prompt}


def generate(payload, key, timeout):
    return send_request("images/generations", json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                        "application/json", key, timeout)


def read_image(path, image_module, *, mask=False):
    limit = 50 * 1024 * 1024
    # 限量读取，在构造请求前拒绝超大文件。
    with path.open("rb") as source:
        blob = source.read(limit)
    if len(blob) >= limit:
        raise ValueError(f"{'蒙版' if mask else '输入图像'}必须小于 {limit // (1024 * 1024)} MiB：{path}")
    with image_module.open(io.BytesIO(blob)) as picture:
        formats = {"PNG": ("png", "image/png"), "JPEG": ("jpg", "image/jpeg"), "WEBP": ("webp", "image/webp")}
        if picture.format not in formats or (mask and picture.format != "PNG"):
            raise ValueError(f"{'蒙版必须为 PNG' if mask else '输入图像必须为 PNG、JPEG 或 WebP'}：{path}")
        if getattr(picture, "n_frames", 1) != 1:
            raise ValueError(f"请使用静态图像：{path}")
        picture.load()
        size = picture.size
        extension, content_type = formats[picture.format]
        if mask:
            if "A" not in picture.getbands() and "transparency" not in picture.info:
                raise ValueError(f"蒙版必须包含 Alpha 透明通道：{path}；请将待编辑区域设为透明，保留区域设为不透明，再保存为 PNG")
            if picture.convert("RGBA").getchannel("A").getextrema()[0] != 0:
                raise ValueError(f"蒙版必须包含 Alpha 为 0 的可编辑区域：{path}；请将待编辑区域的 Alpha 设为 0")
    return blob, size, extension, content_type


def edit(payload, paths, mask, key, timeout, image_module):
    if not 1 <= len(paths) <= 16:
        raise ValueError("编辑需要 1 至 16 张输入图像")
    files = []
    first_size = None
    for index, path in enumerate(paths):
        blob, size, extension, content_type = read_image(path, image_module)
        if first_size is None:
            first_size = size
        # 使用固定 ASCII 文件名，避免本地路径或特殊字符进入 multipart 请求头。
        files.append(("image[]", f"image-{index + 1}.{extension}", content_type, blob))
    if mask is not None:
        blob, size, _, content_type = read_image(mask, image_module, mask=True)
        if size != first_size:
            raise ValueError(f"蒙版尺寸 {size} 必须与第一张输入图像 {first_size} 一致；请按第一张图的像素坐标重新制作蒙版")
        files.append(("mask", "mask.png", content_type, blob))

    next_step = "蒙版作用于第一张图，返回后自动本地合成并保留两张结果图" if mask is not None else "保存接口返回图"
    print(f"输入校验通过：{len(paths)} 张图片；{next_step}。", file=sys.stderr, flush=True)
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in payload.items():
        value = str(value).lower() if isinstance(value, bool) else str(value)
        parts.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n'
                      f'\r\n{value}\r\n').encode("utf-8"))
    for name, filename, content_type, blob in files:
        parts.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
                      f'filename="{filename}"\r\nContent-Type: {content_type}\r\n\r\n').encode("ascii"))
        parts.extend((blob, b"\r\n"))
    parts.append(f"--{boundary}--\r\n".encode("ascii"))
    return send_request("images/edits", b"".join(parts),
                        f"multipart/form-data; boundary={boundary}", key, timeout)


def send_request(endpoint, data, content_type, key, timeout):
    request = urllib.request.Request(
        f"{CPA_BASE_URL}/{endpoint}", data=data,
        headers={"Authorization": f"Bearer {key}", "Content-Type": content_type,
                 "Accept": "application/json"}, method="POST",
    )
    opener = urllib.request.build_opener(NoRedirect())
    print(f"正在请求图像接口，超时 {timeout} 秒，不自动重试。", file=sys.stderr, flush=True)
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raw = error.read()
        detail = raw.decode("utf-8", errors="replace").replace(key, "[REDACTED]")[:800]
        raise ValueError(f"HTTP {error.code}：{detail}") from error
    return raw


def extract(raw, timeout, image_module):
    body = json.loads(raw)
    if not isinstance(body, dict):
        raise ValueError("响应顶层必须是 JSON 对象")
    if body.get("error"):
        raise ValueError(f"接口返回错误：{str(body['error'])[:800]}")
    data = body.get("data")
    if not isinstance(data, list) or not data:
        raise ValueError("响应缺少非空 data 数组")
    if len(data) != 1:
        raise ValueError(f"请求 1 张，实际返回 {len(data)} 张，未保存图片")
    item = data[0]
    if not isinstance(item, dict):
        raise ValueError("返回项不是图片对象")
    if item.get("b64_json"):
        try:
            blob = base64.b64decode(item["b64_json"], validate=True)
        except (ValueError, TypeError, binascii.Error) as error:
            raise ValueError("图片的 base64 无效") from error
    elif item.get("url"):
        url = item["url"]
        if not isinstance(url, str) or urllib.parse.urlsplit(url).scheme not in {"https", "http"}:
            raise ValueError("图片的 URL 必须为 HTTP(S)")
        # 签名下载链接自行携带权限，不转发生图接口的 Bearer 密钥。
        with urllib.request.urlopen(url, timeout=timeout) as response:
            blob = response.read()
    else:
        raise ValueError("图片缺少 b64_json 或 url")
    with image_module.open(io.BytesIO(blob)) as picture:
        width, height = picture.size
        picture.load()
        alpha_min, _ = picture.convert("RGBA").getchannel("A").getextrema()
    return blob, {
        "width": width, "height": height, "has_transparency": alpha_min < 255,
        "quality": body.get("quality"),
    }


def main(operation):
    args = arguments(operation)
    key = os.environ.get("CPA_KEY", "")
    try:
        if os.path.lexists(args.output):
            raise ValueError(f"输出路径已存在，不允许覆盖：{args.output}；请通过 --output 指定新路径")
        composed_output = None
        if operation == "edit" and args.mask is not None:
            from compose import check_output_path
            composed_output = args.output.with_name(f"{args.output.stem}.composed.png")
            check_output_path(composed_output)
        try:
            from PIL import Image
        except ImportError as error:
            raise ValueError("缺少 Pillow，请执行以下命令安装：\nsudo apt update && sudo apt install python3-pil -y") from error
        if not key.strip():
            raise ValueError("请在运行环境中设置 CPA_KEY，不要将密钥写入命令参数或仓库")
        if not CPA_BASE_URL:
            raise ValueError("请在运行环境中设置 CPA_BASE_URL，填写包含 API 版本路径的基础地址（如 https://example.com/v1）")
        payload = payload_for(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if operation == "edit":
            raw = edit(payload, args.image, args.mask, key, TIMEOUT, Image)
        else:
            raw = generate(payload, key, TIMEOUT)
        blob, item = extract(raw, TIMEOUT, Image)
        # 排他创建，防止请求期间出现的同名文件被覆盖。
        with args.output.open("xb") as destination:
            destination.write(blob)
        print(f"图片{'编辑' if operation == 'edit' else '生成'}成功：{args.output}")
        if args.background == "transparent" and not item["has_transparency"]:
            print("背景差异：提示词建议 transparent，实际图片所有像素均不透明。", file=sys.stderr)
        elif args.background == "opaque" and item["has_transparency"]:
            print("背景差异：提示词建议 opaque，实际图片含透明或半透明像素。", file=sys.stderr)
        actual = f"{item['width']}x{item['height']}"
        if actual != args.size:
            print(f"尺寸差异：提示词建议 {args.size}，实际 {actual}。", file=sys.stderr)
        reported_quality = item["quality"]
        if args.quality != "auto" and reported_quality is not None and reported_quality != args.quality:
            print(f"画质元数据差异：提示词建议 {args.quality}，响应 {reported_quality}；请检查实际图片。", file=sys.stderr)
        if composed_output is not None:
            from compose import compose_files
            try:
                compose_files(args.image[0], args.output, args.mask, composed_output)
            except (OSError, ValueError, TypeError) as error:
                raise ValueError(f"本地合成失败，接口返回图已保留在 {args.output}：{error}") from error
        else:
            print("请查看实际图片，确认主体、构图和细节符合要求。")
        return 0
    except (OSError, ValueError, TypeError, urllib.error.URLError) as error:
        message = str(error)
        if key:
            message = message.replace(key, "[REDACTED]")
        print(f"失败：{message}", file=sys.stderr)
        return 1
