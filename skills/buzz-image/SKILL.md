---
name: buzz-image
description: "Generate or edit images with GPT Image through BUZZ and save them into the project. Use whenever the user wants any image or visual asset (icons, favicons, logos, OG/social cards, banners, illustrations, UI mockups, photos, transparent stickers/cutouts, posters) or wants to change an existing image file (restyle, recolor, remove/replace background, add or fix elements)."
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/gen.sh *)
  - PowerShell(${CLAUDE_SKILL_DIR}/scripts/gen.ps1 *)
---

# buzz-image

Generates and edits images with GPT Image through the BUZZ gateway that this Claude Code is connected to. It reuses Claude Code's own BUZZ key (from its env, settings or `apiKeyHelper`); nothing else needs to be installed or configured. If Claude Code reaches BUZZ through a local relay or proxy, the user can set `BUZZ_BASE_URL` to their BUZZ API address to send image requests there directly. Always use the bundled script — never write your own API calls for images, and never look for or print API keys.

Reply to the user in the language they use.

## Running the script

Always pass `timeout: 600000` (an image usually takes 30–90 s; large or high-quality ones take longer).

**If you have a Bash tool, use it.** This exact command shape is pre-approved:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/gen.sh -p "PROMPT" -o PATH [options]
```

**Otherwise use the PowerShell tool** (typical on Windows). Call the script path directly as the first word — no `&`, no quotes around the path, no nested `powershell` process, nothing chained before or after — so it matches the pre-approved shape:

```powershell
${CLAUDE_SKILL_DIR}/scripts/gen.ps1 -Prompt "PROMPT" -Out PATH [-Size ..] [-Quality ..] [-Background ..] [-Format ..] [-N ..] [-Ref a.png,b.png] [-Mask m.png] [-Model ..]
```

If Claude Code still asks the user to approve the command, that is fine — wait for the approval; never look for workarounds.

| Option | Values |
|---|---|
| `-p` | Image description (required). Write it yourself from the user's request. |
| `-o` | Output path. Pick one that fits the use (e.g. `public/favicon.png`, `assets/og.png`); otherwise put it under `generated/`. Existing files are never overwritten (`-2`, `-3`… is appended). |
| `-s` | Exact `WxH` (any size, e.g. `32x32`, `1200x630`) or `square` / `landscape` / `portrait` / `wide` / `tall` / `2k` / `4k`. The saved file always ends up at the requested size: sizes the model can't produce are generated close by and cropped/scaled locally, and some models return fewer pixels than asked (same aspect ratio), which is then scaled up locally. Omit to let the model decide. |
| `-b` | `transparent` for cutouts/stickers/icons without background (png or webp only); `opaque`; `auto`. |
| `-q` | `low` / `medium` / `high` / `xhigh` / `max`. Omit unless the user asks or the asset needs fine detail. |
| `-f` | `png` (default) / `jpeg` / `webp`. |
| `-n` | Number of images, default 1. |
| `-r` | Source/reference image; repeat for several. Any `-r` switches to edit mode, where the result is built **on top of** the reference images' content (see step 2). |
| `--mask` | PNG mask for local edits (transparent = repaint); needs `-r`. |
| `-m` | Model. Omit to auto-pick the best one available to the user's key. |
| `--models` | List the image models available to this key, without generating. |

The script prints one JSON line. Success: `{"ok":true,"model":..,"files":[..],"size":..,"generated_size":..,"requested_size":..,"resized":..,"seconds":..}`, where `size` is the measured pixel size of the saved file and `generated_size` is what the model actually returned. Failure: `{"ok":false,"code":..,"message":..}`.

## Workflow

1. **Understand the request**: what the image is for, where it goes, exact text to render, size, transparency. If something essential is missing, ask one short question; otherwise go ahead.
2. **Use real references, never invent brand assets.**
   - If the user names or attaches images whose **content** should appear or be changed ("edit this screenshot", "use our logo", "put this character in a new scene"), pass every one of them with `-r`.
   - Edit mode builds on the reference images' content, so a reference meant **only for style** ("draw it in the style of this picture") tends to come back as a copy of that picture. For style-only references, Read the image yourself and describe its style in the prompt (medium, palette, lighting, line work, mood) instead of passing it with `-r`. Pass a style image with `-r` only together with the content references it should restyle, and say in the prompt which image is style only.
   - If the image should show or match the user's brand/product (logo, OG/social card, banner, favicon, app icon, anything with the product name), look for the project's existing assets first — e.g. files named `logo*`, `icon*`, `favicon*`, `brand*`, `og*` under `public/`, `assets/`, `static/`, `src/assets/`, `images/`, and the logo referenced in the HTML/manifest — and pass the best match(es) with `-r`, describing in the prompt how to use them ("use the logo from the reference image exactly as is, do not redraw it").
   - If nothing suitable is found, ask the user for their logo/reference instead of making one up. Only design a new logo when the user explicitly asks for one.
   - Reference images must be png, jpeg or webp; if a logo exists only as SVG, tell the user and ask for a PNG export (or proceed without it only if they agree).
3. **Write the prompt** from the user's description (and project context such as brand colours). Keep the user's intent and exact text; don't add things they didn't ask for. Unless the user asks for them, tell the model not to include third-party logos, trademarks or brand marks (models like to decorate tech images with well-known company logos).
4. **Count**: generate 1 image unless the user asks for more. Before generating more than 4 in one go, ask the user to confirm.
5. **Model**: let the script pick unless the user names one. Tell the user which model was used. Suggest `gpt-image-2.5-sunburst` for edits, reference-heavy work or dense/precise text when it is available; switch models whenever the user asks.
6. **Run** the script.
7. **Check the result**: Read each output image once. Report to the user: file path(s), model, final size (if `generated_size` is noticeably smaller than `requested_size`, say the model returned fewer pixels and the file was scaled up, so fine detail may be softer), which reference images were used, and anything that doesn't match the request (misspelled text, logo altered, wrong layout, background not transparent…), with a concrete suggestion. Do **not** regenerate on your own — the user decides.
8. **Show**: if the user wants to see it, open it with the system viewer (`open` on macOS, `start "" <file>` on Windows, `xdg-open` on Linux).
9. **Changes**: apply what the user asks — regenerate with an adjusted prompt, or edit the previous result with `-r <previous file>`. When editing, pass `-s` with the source image's size so the result keeps its dimensions (unless the user wants a different size). Never overwrite the original; write a new file.
10. Don't `git add` generated images unless the user asks.

## Errors (`code` in the JSON)

| code | What to tell the user / do |
|---|---|
| `not_buzz` | The address didn't identify itself as BUZZ, so buzz-image can't run. Relay the message. If the user reaches BUZZ through a local relay or proxy, they can set `BUZZ_BASE_URL` to their BUZZ API address (env var, or the `env` block of Claude Code's settings.json). Stop. |
| `no_key` | No API key in Claude Code's configuration. Stop. |
| `no_image_model` | Their key's group has no GPT Image model; change the key's group in the BUZZ console (API keys page) to one that includes gpt-image models. Stop. |
| `model_unavailable` | That model isn't available for their key; show `available_models` and let them choose. |
| `insufficient_balance` | Balance too low; top up in the BUZZ console. Stop. |
| `content_policy` | Relay the message; let the user decide how to rephrase. Don't rephrase and retry on your own. |
| `timeout` | Tell the user it timed out. Do not retry automatically (the image may already have been billed); offer to retry. |
| `http_error` / `bad_args` | Report the message. Fix your own argument mistakes; don't loop. |

Never switch models or keep retrying on your own after an error.
