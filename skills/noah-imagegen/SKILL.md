---
name: noah-imagegen
description: "通过 GPT-Image2 模型生成或编辑图片，支持参考图、多图合成和蒙版局部修改，在需要生成或编辑位图的场合优先调用此技能。"
---

```text
python <skill-dir>/scripts/generate.py --help
usage: generate.py [-h] --prompt PROMPT --output OUTPUT [--size SIZE]
                   [--quality {low,medium,high,auto}]
                   [--background {opaque,transparent,auto}]

通过提示词字符串或 @文件路径生成图像，尺寸、画质和背景选项仅作为提示词建议。

options:
  -h, --help            show this help message and exit
  --prompt PROMPT       提示词字符串，或 @文件路径（UTF-8）
  --output OUTPUT       完整图像输出路径，不允许覆盖已有路径
  --size SIZE           提示词中的建议尺寸，不能保证精确像素（默认：1254x1254）
  --quality {low,medium,high,auto}
                        提示词中的建议画质（默认：high）
  --background {opaque,transparent,auto}
                        提示词中的建议背景，不能保证透明度（默认：auto）
```

```text
python <skill-dir>/scripts/edit.py --help
usage: edit.py [-h] --prompt PROMPT --output OUTPUT [--size SIZE]
               [--quality {low,medium,high,auto}]
               [--background {opaque,transparent,auto}] --image IMAGE [IMAGE ...]
               [--mask MASK]

通过提示词字符串或 @文件路径编辑图像，尺寸、画质和背景选项仅作为提示词建议。

options:
  -h, --help            show this help message and exit
  --prompt PROMPT       提示词字符串，或 @文件路径（UTF-8）
  --output OUTPUT       完整图像输出路径，不允许覆盖已有路径
  --size SIZE           提示词中的建议尺寸，不能保证精确像素（默认：1254x1254）
  --quality {low,medium,high,auto}
                        提示词中的建议画质（默认：high）
  --background {opaque,transparent,auto}
                        提示词中的建议背景，不能保证透明度（默认：auto）
  --image IMAGE [IMAGE ...]
                        输入图像的 JSON 路径数组，如 '["a.png","b.png"]'；也支持路径列表及重复此选项，最多 16 张
  --mask MASK           可选 PNG 蒙版；使用后保留接口返回图，并另存 <输出名>.composed.png 本地合成图
```

```text
python <skill-dir>/scripts/compose.py --help
usage: compose.py [-h] --original ORIGINAL --edited EDITED --mask MASK --output OUTPUT

本地合成蒙版编辑结果，仅替换 Alpha 为 0 的区域，其余 RGBA 像素保持原样。

options:
  -h, --help           show this help message and exit
  --original ORIGINAL  原图路径；多图编辑时使用第一张输入图像
  --edited EDITED      接口返回的编辑结果路径
  --mask MASK          与编辑请求相同的 PNG 蒙版，仅 Alpha=0 的像素被替换
  --output OUTPUT      新的 .png 输出路径，不允许覆盖已有路径
```
