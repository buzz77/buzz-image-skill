# buzz-image

Generate and edit images with GPT Image from inside **Claude Code** — through [BUZZ](https://buzzai.cc).

Ask in plain language — "make a favicon for this project", "a 1200×630 OG image titled *Ship faster*", "remove the background from logo.png" — and Claude writes the prompt, generates the image, saves it into your project, checks the result and reports back.

[中文说明](#中文说明)

## Highlights

- **Nothing extra to set up.** Uses the BUZZ key your Claude Code is already configured with. No Python, no Node, no second API key.
- **Brand-aware.** For logos, OG cards, banners and icons, Claude looks for your project's existing logo and colours and passes them as reference images instead of inventing brand assets.
- **Exact sizes.** Any `WxH` (32×32 favicons, 1200×630 OG cards…). Sizes the model can't produce directly are generated close by and cropped/scaled locally.
- **Transparent backgrounds, reference images and masked edits.**
- **Safe by default.** One image unless you ask for more; asks before more than 4; never retries on its own after a timeout (no double charges); never overwrites files; never prints your key.

## Requirements

1. [Claude Code](https://docs.claude.com/en/docs/claude-code) connected to BUZZ (`ANTHROPIC_BASE_URL` pointing at BUZZ). See the [Claude Code guide](https://buzzai.cc/docs/guides/claude-code).
2. Your key's group includes a GPT Image model (`gpt-image-*`). If not, change the key's group on the Tokens page of the BUZZ console.

## Install

macOS / Linux / Git Bash:

```bash
curl -fsSL https://buzzgw.com/sh/buzz-image.sh | bash
```

Windows PowerShell:

```powershell
irm https://buzzgw.com/sh/buzz-image.ps1 | iex
```

`buzzgw.com` and `buzzai.cc` serve the same files; use whichever connects from your network.

The skill is installed to `~/.claude/skills/buzz-image/` (respects `CLAUDE_CONFIG_DIR`). Restart Claude Code or run `/reload-skills`. Run the same command again to update.

If Claude Code reaches BUZZ through a local relay or proxy, set `BUZZ_BASE_URL` to your BUZZ API address (environment variable, or the `env` block of Claude Code's `settings.json`). The key is read from Claude Code's own configuration, including `apiKeyHelper`. To use a different key for images than for chat (for example a token in a group with `gpt-image-*` models), set `BUZZ_IMAGE_API_KEY`; it takes precedence.

Alternatively, with the [`skills`](https://github.com/vercel-labs/skills) CLI:

```bash
npx skills add buzz77/buzz-image-skill --skill buzz-image -a claude-code -g
```

## Usage

Just ask Claude Code for the image you need:

- Make a favicon for this project
- Make a 1200×630 OG image titled "Ship faster"
- Remove the background from logo.png and make it transparent
- Using our logo as a reference, make a set of 4 matching feature icons
- Turn this screenshot into a dark theme

Claude tells you the file path, the model it used and the final size. Each image is billed to your BUZZ balance at the model's price.

Full guide: <https://buzzai.cc/docs/guides/claude-code-image>

## How it works

`skills/buzz-image/scripts/gen.sh` (macOS, Linux, Git Bash) and `gen.ps1` (Windows PowerShell) call the OpenAI-compatible Images API of the gateway Claude Code is connected to. Before any key is sent, the script checks that the gateway identifies itself as BUZZ; otherwise it stops. It only depends on tools that ship with the operating system.

## Uninstall

```bash
curl -fsSL https://buzzgw.com/sh/buzz-image.sh | bash -s -- --uninstall
```

```powershell
$env:BUZZ_IMAGE_UNINSTALL=1; irm https://buzzgw.com/sh/buzz-image.ps1 | iex
```

---

## 中文说明

在 **Claude Code** 里，通过 [BUZZ](https://buzzai.cc) 用 GPT Image 生成和修改图片。

直接用自然语言提需求，比如"给这个项目做一个 favicon""做一张 1200×630 的 OG 分享图，标题写 Ship faster""把 logo.png 的背景去掉"。Claude 会自己写提示词、生成图片、存进项目、检查结果，然后告诉你。

- **无需额外配置**：直接使用 Claude Code 已配置的 BUZZ 密钥，不需要 Python、Node，也不用另外创建密钥。
- **参考品牌素材**：做 logo、OG 图、横幅、图标时，Claude 会先找项目里已有的 logo 和配色作为参考图，不凭空编造。
- **任意尺寸**：32×32 的 favicon、1200×630 的 OG 图都可以。模型不能直接出的尺寸，会先就近生成，再在本地精确裁切缩放。
- **支持透明背景、参考图和局部修改。**
- **默认安全**：默认只出 1 张，超过 4 张先询问；超时不自动重试，避免重复扣费；不覆盖已有文件；不打印密钥。

**使用要求**：Claude Code 已接入 BUZZ；密钥所在分组包含 GPT Image 模型（`gpt-image-*`），否则请在 BUZZ 控制台的令牌管理里修改分组。

**安装**：macOS / Linux / Git Bash 运行 `curl -fsSL https://buzzgw.com/sh/buzz-image.sh | bash`，Windows PowerShell 运行 `irm https://buzzgw.com/sh/buzz-image.ps1 | iex`。`buzzgw.com` 和 `buzzai.cc` 内容相同，哪个能连上用哪个。装好后重启 Claude Code，或执行 `/reload-skills`。重新运行同一条命令即可更新。

如果 Claude Code 经本地中继或代理接入 BUZZ，把 `BUZZ_BASE_URL` 设为你的 BUZZ API 地址（环境变量，或 Claude Code `settings.json` 的 `env` 块）。密钥从 Claude Code 自己的配置读取，支持 `apiKeyHelper`。对话和生图想用不同的令牌（比如另建一个含 `gpt-image-*` 的分组令牌），设置 `BUZZ_IMAGE_API_KEY` 即可，会优先使用。

完整教程：<https://buzzai.cc/docs/zh/guides/claude-code-image>

## License

Copyright (c) 2026 CyanWave Technology Limited. Licensed under the [PolyForm Strict License 1.0.0](LICENSE).

For permissions beyond that license, contact support@buzzai.cc.
