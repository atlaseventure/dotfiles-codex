# CLI 使用

将 `IMAGE_GEN` 设置为本技能目录内 `scripts/image_gen.py` 的实际路径。真实请求需要 `CPA_BASE_URL`、`CPA_API_KEY` 和 `openai` 包；`--dry-run` 不需要网络、密钥或 SDK，只输出请求及保存路径。

## 生成与编辑

```bash
python "$IMAGE_GEN" generate \
  --prompt "柔和棚拍灯光下的陶瓷咖啡杯" \
  --size 2048x1152 --quality high \
  --out output/imagegen/mug.png

python "$IMAGE_GEN" edit \
  --image input.png \
  --prompt "仅将背景替换为暖色日落，保持产品和边缘不变" \
  --out output/imagegen/mug-edited.png
```

多张输入图重复传入 `--image`，并在提示词中按顺序说明角色。蒙版使用 `--mask`，应用于第一张输入图。`--prompt-file` 可读取 UTF-8 提示词文件。

同一提示词的变体用 `--n`。透明输出使用 `--background transparent --output-format png`，服务端须支持该选项。

## 批量生成

每行一个 JSON 对象：

```jsonl
{"prompt":"陶瓷咖啡杯产品照片","size":"2048x1152","out":"mug.png"}
{"prompt":"森林中的灰狼侧面照片","quality":"high","out":"wolf.png"}
```

```bash
python "$IMAGE_GEN" generate-batch \
  --input tmp/imagegen/prompts.jsonl \
  --out-dir output/imagegen/batch \
  --concurrency 5 --fail-fast
```

每个任务可覆盖模型、尺寸、质量、输出格式及提示词字段；任务字段优先于命令行参数。任务的 `out` 作为 `--out-dir` 下的文件名。验收后删除临时 JSONL。

## 输出与检查

- 添加 `--dry-run` 可检查请求，不调用服务端。
- 已有目标文件默认报错；仅在明确要求替换时使用 `--force`。
- `--downscale-max-dim` 另存缩小副本，默认文件名后缀为 `-web`，需要 Pillow。
- 质量、模型、尺寸和格式使用显式参数控制；具体选项运行相应子命令的 `--help`。
