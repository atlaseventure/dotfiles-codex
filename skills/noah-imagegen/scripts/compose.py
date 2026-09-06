#!/usr/bin/env python3
"""本地合成蒙版编辑结果，仅替换 Alpha 为 0 的区域，其余 RGBA 像素保持原样。"""

import argparse
import io
import os
from pathlib import Path
import sys

from image_api import read_image


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--original", required=True, type=Path, help="原图路径；多图编辑时使用第一张输入图像")
    parser.add_argument("--edited", required=True, type=Path, help="接口返回的编辑结果路径")
    parser.add_argument("--mask", required=True, type=Path, help="与编辑请求相同的 PNG 蒙版，仅 Alpha=0 的像素被替换")
    parser.add_argument("--output", required=True, type=Path, help="新的 .png 输出路径，不允许覆盖已有路径")
    return parser.parse_args()


def load_picture(path, image_module, *, mask=False):
    blob, _, _, _ = read_image(path, image_module, mask=mask)
    with image_module.open(io.BytesIO(blob)) as picture:
        if picture.mode not in {"1", "L", "LA", "P", "RGB", "RGBA"}:
            raise ValueError(f"本地合成支持 8 位灰度、调色板或 RGB/RGBA 图像，请先转换位深或色彩模式：{path}")
        if picture.getexif().get(274, 1) != 1:
            raise ValueError(f"请先将 EXIF 方向应用到像素，并使用方向一致的原图、编辑图和蒙版：{path}")
        return picture.convert("RGBA"), picture.info.get("icc_profile")


def check_output_path(path):
    if os.path.lexists(path):
        raise ValueError(f"输出路径已存在，不允许覆盖：{path}；请通过 --output 指定新路径")
    if path.suffix.lower() != ".png":
        raise ValueError("输出路径必须使用 .png 扩展名，以无损保存像素")


def compose_files(original_path, edited_path, mask_path, output_path):
    """合成并保存新 PNG，供独立命令及蒙版编辑流程调用。"""
    check_output_path(output_path)
    try:
        from PIL import Image, ImageChops
    except ImportError as error:
        install_command = (
            "python -m pip install Pillow"
            if os.name == "nt"
            else "sudo apt update\nsudo apt install python3-pil"
        )
        raise ValueError(f"缺少 Pillow，请执行以下命令安装：\n{install_command}") from error

    original, profile = load_picture(original_path, Image)
    edited, _ = load_picture(edited_path, Image)
    mask, _ = load_picture(mask_path, Image, mask=True)
    if original.size != edited.size or original.size != mask.size:
        raise ValueError(
            f"三张图像尺寸必须一致：原图 {original.size}，编辑图 {edited.size}，蒙版 {mask.size}；"
            "请先将编辑图与蒙版对齐到原图的像素坐标，再单独运行 compose.py 合成，无需重新请求接口"
        )

    # 硬边界替换，半透明蒙版像素也从原图保留，避免边缘混合改变保留区域。
    replace = mask.getchannel("A").point(lambda alpha: 255 if alpha == 0 else 0)
    keep = ImageChops.invert(replace)
    composed = Image.composite(edited, original, replace)
    encoded = io.BytesIO()
    composed.save(encoded, format="PNG", icc_profile=profile)
    blob = encoded.getvalue()

    # 对最终 PNG 解码后的全部 RGBA 通道做检查，包含透明像素下的 RGB 值。
    with Image.open(io.BytesIO(blob)) as saved:
        difference = ImageChops.difference(original, saved.convert("RGBA"))
        for channel in difference.split():
            if ImageChops.multiply(channel, keep).getbbox() is not None:
                raise ValueError("合成后保留区域像素校验失败，未保存图片")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("xb") as destination:
        destination.write(blob)
    replaced = replace.histogram()[255]
    preserved = original.width * original.height - replaced
    print(f"本地合成成功：{output_path}")
    print(f"尺寸：{original.width}x{original.height}；替换 {replaced} 像素；保留 {preserved} 像素。")
    print("校验通过：保留区域 RGBA 像素完全一致。")
    print("请检查编辑区域及硬边界的衔接效果；半透明蒙版区域保留原图，不进行羽化或混合。")


def main():
    args = arguments()
    try:
        compose_files(args.original, args.edited, args.mask, args.output)
        return 0
    except (OSError, ValueError, TypeError) as error:
        print(f"失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
