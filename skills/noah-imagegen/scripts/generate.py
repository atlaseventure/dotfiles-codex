#!/usr/bin/env python3
"""通过提示词字符串或 @文件路径生成图像，尺寸、画质和背景选项仅作为提示词建议。"""

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

ENDPOINT = "https://noah.atlasmeta.one:8700/v1/images/generations"
TIMEOUT = 300
REQUEST_OPTIONS = {
    "model": "gpt-image-2", "n": 1, "size": "1024x1024", "quality": "high",
    "background": "auto", "output_format": "png", "moderation": "low", "stream": False,
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """生图请求不跟随重定向，防止凭据被转发到其他地址。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def parse_size(value):
    if not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("尺寸格式必须为正整数宽x高，例如 1024x1024")
    return value


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--prompt", required=True, help="提示词字符串，或 @文件路径（UTF-8）")
    parser.add_argument("--output", required=True, type=Path, help="完整图像输出路径，不允许覆盖已有路径")
    parser.add_argument("--size", type=parse_size, default="1024x1024", help="提示词中的建议尺寸，不能保证精确像素")
    parser.add_argument("--quality", choices=["low", "medium", "high", "auto"], default="high", help="提示词中的建议画质")
    parser.add_argument("--background", choices=["opaque", "transparent", "auto"], default="auto", help="提示词中的建议背景，不能保证透明度")
    return parser.parse_args()


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
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                 "Accept": "application/json"}, method="POST",
    )
    opener = urllib.request.build_opener(NoRedirect())
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


def main():
    args = arguments()
    key = os.environ.get("CPA_KEY", "")
    try:
        if os.path.lexists(args.output):
            raise ValueError(f"输出路径已存在，不允许覆盖：{args.output}")
        try:
            from PIL import Image
        except ImportError as error:
            raise ValueError("缺少 Pillow，请在当前 Python 环境安装：python3 -m pip install Pillow") from error
        if not key.strip():
            raise ValueError("请在运行环境中设置 CPA_KEY，不要将密钥写入命令参数或仓库")
        payload = payload_for(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        raw = generate(payload, key, TIMEOUT)
        blob, item = extract(raw, TIMEOUT, Image)
        # 排他创建，防止请求期间出现的同名文件被覆盖。
        with args.output.open("xb") as destination:
            destination.write(blob)
        print("图片生成成功！")
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
        return 0
    except (OSError, ValueError, TypeError, urllib.error.URLError) as error:
        message = str(error)
        if key:
            message = message.replace(key, "[REDACTED]")
        print(f"失败：{message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
