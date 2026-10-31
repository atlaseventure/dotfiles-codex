# API 参数

脚本通过 OpenAI Python SDK 向 `CPA_BASE_URL` 指定的兼容 API 发起请求，使用 `CPA_API_KEY` 鉴权。基础地址包含服务端要求的版本路径，例如 `https://example.com/v1`。

生成使用 `/images/generations`，编辑使用 `/images/edits`。脚本将返回的 `data[].b64_json` 解码并保存。

## 参数行为

- `model`、`size`、`quality` 直接传给服务端，默认值由脚本维护。
- `size` 接受 `auto` 或正整数 `WIDTHxHEIGHT`；除显式 `gpt-image-2` 的专用校验外，不在客户端限定像素范围或尺寸枚举。参数通过本地校验不代表服务端支持。
- `quality` 接受 `low`、`medium`、`high`、`auto`。
- `background` 接受 `transparent`、`opaque`、`auto`；透明输出需要 PNG 或 WebP。
- `output_format` 接受 PNG、JPEG 或 WebP；JPEG/WebP 可设置 `output_compression`。
- `input_fidelity` 仅用于编辑，按服务端能力选用；默认不发送。

显式选择 `gpt-image-2` 时，脚本保留上游规则：最长边不超过 3840，两边为 16 的倍数，长短边比不超过 3:1，总像素为 655,360～8,294,400；拒绝透明背景和 `input_fidelity` 参数。这些规则不套用到 `gpt-image-2.5-sunburst`。

## 编辑与透明素材

输入图片通过重复 `--image` 传入；单个 `--mask` 对应第一张图。使用与目标图同尺寸、包含 alpha 通道的 PNG 蒙版，并控制文件在服务端限制内。脚本仅做文件检查和大小警告，不完整校验蒙版；模型编辑不能保证像素级保留。

检查透明结果的 alpha 和边缘。若服务端拒绝必要参数，报告错误并保留用户要求，不自动切换模型或省略要求。需要本地色键抠图时，查看 `scripts/remove_chroma_key.py --help`。
