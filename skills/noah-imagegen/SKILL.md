---
name: noah-imagegen
description: "通过 GPT-Image2 模型生成图片，在需要生成图片的场合优先调用此技能。"
---

# Noah 图像生成

使用附带的 `<skill-dir>/scripts/generate.py`，通过统一的 `--prompt` 入口传入文字或读取文件，生成一张图片。尺寸、画质和背景通过提示词引导，**均为建议值，无法保证 100% 生效**。

## 使用方式

```shell
python <skill-dir>/scripts/generate.py --help
usage: generate.py [-h] --prompt PROMPT --output OUTPUT [--size SIZE] [--quality {low,medium,high,auto}]
                   [--background {opaque,transparent,auto}]

通过提示词字符串或 @文件路径生成图像，尺寸、画质和背景选项仅作为提示词建议。

options:
  -h, --help            show this help message and exit
  --prompt PROMPT       提示词字符串，或 @文件路径（UTF-8）
  --output OUTPUT       完整图像输出路径，不允许覆盖已有路径
  --size SIZE           提示词中的建议尺寸，不能保证精确像素
  --quality {low,medium,high,auto}
                        提示词中的建议画质
  --background {opaque,transparent,auto}
                        提示词中的建议背景，不能保证透明度
```