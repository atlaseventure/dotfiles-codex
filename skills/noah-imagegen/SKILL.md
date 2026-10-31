---
name: noah-imagegen
description: 通过 CLI/API 生成或编辑位图，支持参考图、多图合成、蒙版和批量生成，在需要生成或编辑位图的场合优先调用此技能。适用于照片、插画、产品图和透明素材；已有 SVG、矢量图标或适合用代码实现的图形优先直接编辑。
---

# 图片生成与编辑

使用随附的 `scripts/image_gen.py` 调用 API，支持 `generate`、`edit` 和 `generate-batch`。直接执行此路径，无需另行确认 CLI 模式，也无需创建临时 SDK 调用脚本。

## 环境与参数

- 在本地设置 `CPA_BASE_URL`（包含 API 版本路径的基础地址）和 `CPA_API_KEY`（API 密钥）。不要在聊天、命令参数或仓库中写入密钥。
- 安装 `openai`；检查透明度或缩放时安装 `pillow`。uv 环境使用 `uv pip install openai pillow`。
- 默认模型为 `gpt-image-2.5-sunburst`；默认尺寸为 `auto`、质量为 `medium`。用户指定模型时使用 `--model`，不自动更换模型。
- 尺寸接受 `auto` 或正整数 `WIDTHxHEIGHT`，不使用旧尺寸枚举限制。服务端决定模型实际支持的尺寸；显式选择 `gpt-image-2` 时保留其专用尺寸校验。
- 草稿使用 `low`；最终素材、密集文字和精细编辑按需求使用 `medium`、`high` 或 `auto`。
- 参数不受服务端支持时报告具体错误，不推断其他模型的能力适用于默认模型。

## 工作流程

1. 判断意图：从零创作或仅借用参考图属于生成；修改现有图片并保留部分内容属于编辑。
2. 收集用途、提示词、准确文字、必须保留与避免的内容，以及输入图片。为每张图片标明参考图、编辑目标或合成素材的角色。
3. 按需查看输入图片。无输入图使用 `generate`；有参考图或编辑目标时通过 `edit --image` 传入图片，在提示词中明确是参考创作还是局部修改。
4. 详细需求只整理结构；笼统需求仅补充有助于结果的构图、场景或用途细节，不擅自添加角色、品牌、口号或配色。仅在缺失信息阻碍完成时提问。
5. 单图使用单次调用；同一提示词的变体使用 `--n`；不同素材使用 `generate-batch`，每个素材对应独立提示词和输出文件名。
6. 检查主体、风格、构图、文字和保留项；每轮集中调整一个问题，编辑时重复不变项。
7. 透明素材使用 `--background transparent` 和 PNG 或 WebP，检查真实 alpha。需要本地色键抠图时使用 `scripts/remove_chroma_key.py --help`，检查边缘后交付。
8. 临时文件放在 `tmp/imagegen/`，完成后删除。最终文件默认放在 `output/imagegen/`；用户指定路径时使用该路径。项目素材保存到工作区并更新引用；默认另存版本，明确要求覆盖时才使用 `--force`。
9. 交付图片、最终路径和提示词或提示词集合，说明使用了 CLI/API。

## 参考资料

- 命令、批量输入和输出操作：[references/cli.md](references/cli.md)。
- 请求参数与编辑约束：[references/image-api.md](references/image-api.md)。
- 提示词原则：[references/prompting.md](references/prompting.md)。
- 各类素材示例：[references/sample-prompts.md](references/sample-prompts.md)。
- 网络错误处理：[references/codex-network.md](references/codex-network.md)。

## Use-case taxonomy (exact slugs)

Classify each request into one of these buckets and keep the slug consistent across prompts and references.

Generate:
- photorealistic-natural — candid/editorial lifestyle scenes with real texture and natural lighting.
- product-mockup — product/packaging shots, catalog imagery, merch concepts.
- ui-mockup — app/web interface mockups and wireframes; specify the desired fidelity.
- infographic-diagram — diagrams/infographics with structured layout and text.
- scientific-educational — classroom explainers, scientific diagrams, and learning visuals with required labels and accuracy constraints.
- ads-marketing — campaign concepts and ad creatives with audience, brand position, scene, and exact tagline/copy.
- productivity-visual — slide, chart, workflow, and data-heavy business visuals.
- logo-brand — logo/mark exploration, vector-friendly.
- illustration-story — comics, children’s book art, narrative scenes.
- stylized-concept — style-driven concept art, 3D/stylized renders.
- historical-scene — period-accurate/world-knowledge scenes.

Edit:
- text-localization — translate/replace in-image text, preserve layout.
- identity-preserve — try-on, person-in-scene; lock face/body/pose.
- precise-object-edit — remove/replace a specific element (including interior swaps).
- lighting-weather — time-of-day/season/atmosphere changes only.
- background-extraction — transparent background / clean cutout. Request transparency through the API and inspect the saved alpha channel.
- style-transfer — apply reference style while changing subject/scene.
- compositing — multi-image insert/merge with matched lighting/perspective.
- sketch-to-render — drawing/line art to photoreal render.

## Shared prompt schema

Use the following labeled spec as shared prompt scaffolding for CLI/API requests:

```text
Use case: <taxonomy slug>
Asset type: <where the asset will be used>
Primary request: <user's main prompt>
Input images: <Image 1: role; Image 2: role> (optional)
Scene/backdrop: <environment>
Subject: <main subject>
Style/medium: <photo/illustration/3D/etc>
Composition/framing: <wide/close/top-down; placement>
Lighting/mood: <lighting + mood>
Color palette: <palette notes>
Materials/textures: <surface details>
Text (verbatim): "<exact text>"
Constraints: <must keep/must avoid>
Avoid: <negative constraints>
```

Notes:
- `Asset type` and `Input images` are prompt scaffolding, not dedicated CLI flags.
- `Scene/backdrop` refers to the visual setting. It is not the same as the CLI `background` parameter, which controls output transparency behavior.
- Execution notes such as `Quality:`, `Input fidelity:`, masks, output format, and output paths belong in CLI arguments, not in the prompt.

Augmentation rules:
- Keep it short.
- Add only the details needed to improve the prompt materially.
- For edits, explicitly list invariants (`change only X; keep Y unchanged`).
- If any critical detail is missing and blocks success, ask a question; otherwise proceed.
