#!/usr/bin/env bash
# buzz-image: generate or edit images with GPT Image through BUZZ, from Claude Code.
# Spec: docs/BUZZ_IMAGE_SKILL_DESIGN.md. Needs only curl, awk, sed, grep, base64.
#
#   gen.sh -p "prompt" [-o out.png] [-m model] [-s size] [-q quality] [-b background]
#          [-f png|jpeg|webp] [-n 1-10] [-r ref.png ...] [--mask mask.png] [--no-upscale]
#   gen.sh --models
#
#   size: WxH or square|landscape|portrait|wide|tall|2k|4k|auto. Sizes the model
#         cannot produce (e.g. 32x32, 1200x630) are generated at the closest legal
#         size and then cropped/scaled locally to exactly WxH. --no-upscale keeps a
#         smaller image the model returned at the right aspect ratio as is.
#
# stdout: exactly one JSON line. Exit code 0 on success, non-zero on failure.
# The key is read from Claude Code's own config (env, settings.json or its
# apiKeyHelper) and is only sent to the address Claude Code already uses (or to
# BUZZ_BASE_URL when set), after that address identifies itself as BUZZ.
set -u

PROMPT="" OUT="" MODEL="" SIZE="" QUALITY="" BACKGROUND="" FORMAT="png" N=1 MASK=""
LIST_MODELS=0 NO_UPSCALE=0
REFS=()

BUZZ_IMAGE_VERSION="1.3.0"
# Every request identifies itself, so gateway logs can tell skill traffic apart.
curl() { command curl -A "buzz-image/$BUZZ_IMAGE_VERSION" "$@"; }

# ---------------------------------------------------------------- output helpers
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '; }

fail() { # fail CODE MESSAGE [extra-json-fields]
  printf '{"ok":false,"code":"%s","message":"%s"%s}\n' "$1" "$(json_escape "$2")" "${3:+,$3}"
  exit 1
}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--prompt) PROMPT="${2:-}"; shift 2 ;;
    -o|--out) OUT="${2:-}"; shift 2 ;;
    -m|--model) MODEL="${2:-}"; shift 2 ;;
    -s|--size) SIZE="${2:-}"; shift 2 ;;
    -q|--quality) QUALITY="${2:-}"; shift 2 ;;
    -b|--background) BACKGROUND="${2:-}"; shift 2 ;;
    -f|--format) FORMAT="${2:-}"; shift 2 ;;
    -n) N="${2:-}"; shift 2 ;;
    -r|--ref) REFS+=("${2:-}"); shift 2 ;;
    --mask) MASK="${2:-}"; shift 2 ;;
    --models) LIST_MODELS=1; shift ;;
    --no-upscale) NO_UPSCALE=1; shift ;;
    -h|--help) usage ;;
    *) fail bad_args "unknown argument: $1" ;;
  esac
done

if [ "$LIST_MODELS" -eq 0 ]; then
  [ -n "$PROMPT" ] || fail bad_args "missing -p prompt"
  case "$N" in [1-9]|10) ;; *) fail bad_args "-n must be 1-10" ;; esac
  case "$FORMAT" in png|jpeg|webp) ;; *) fail bad_args "-f must be png, jpeg or webp" ;; esac
  case "$QUALITY" in ""|auto|low|medium|high|xhigh|max) ;; *) fail bad_args "-q must be low|medium|high|xhigh|max|auto" ;; esac
  case "$BACKGROUND" in
    ""|auto|opaque) ;;
    transparent) [ "$FORMAT" = "jpeg" ] && fail bad_args "transparent background needs png or webp" ;;
    *) fail bad_args "-b must be auto|opaque|transparent" ;;
  esac
  for r in "${REFS[@]+"${REFS[@]}"}"; do [ -f "$r" ] || fail bad_args "reference image not found: $r"; done
  if [ -n "$MASK" ]; then
    [ -f "$MASK" ] || fail bad_args "mask not found: $MASK"
    [ ${#REFS[@]} -gt 0 ] || fail bad_args "--mask needs at least one -r reference image"
  fi
fi

# ---------------------------------------------------------------- sizes
# Legal: both edges multiples of 16, max edge 3840, ratio <= 3:1,
# 655,360 <= pixels <= 8,294,400.
TARGET_W="" TARGET_H="" GEN_SIZE=""
case "$SIZE" in
  ""|auto) ;;
  square|1k) GEN_SIZE="1024x1024" ;;
  landscape) GEN_SIZE="1536x1024" ;;
  portrait) GEN_SIZE="1024x1536" ;;
  wide) GEN_SIZE="1792x1008" ;;
  tall) GEN_SIZE="1008x1792" ;;
  2k) GEN_SIZE="2048x2048" ;;
  4k) GEN_SIZE="3840x2160" ;;
  *)
    printf '%s' "$SIZE" | grep -Eq '^[0-9]+x[0-9]+$' || fail bad_args "-s must be WxH or square|landscape|portrait|wide|tall|2k|4k|auto"
    TARGET_W="${SIZE%x*}"; TARGET_H="${SIZE#*x}"
    { [ "$TARGET_W" -ge 1 ] && [ "$TARGET_H" -ge 1 ] && [ "$TARGET_W" -le 16384 ] && [ "$TARGET_H" -le 16384 ]; } 2>/dev/null \
      || fail bad_args "size out of range: $SIZE"
    GEN_SIZE="$(awk -v w="$TARGET_W" -v h="$TARGET_H" '
      function legal(a, b) { return a%16==0 && b%16==0 && (a>b?a:b)<=3840 && (a>b?a/b:b/a)<=3 && a*b>=655360 && a*b<=8294400 }
      BEGIN {
        if (legal(w, h)) { printf "%dx%d", w, h; exit }
        r = w / h; if (r > 3) r = 3; if (r < 1/3) r = 1/3
        area = w * h; if (area < 1048576) area = 1048576; if (area > 8294400) area = 8294400
        gw = sqrt(area * r); gh = gw / r
        if (gw > 3840) { gh = gh * 3840 / gw; gw = 3840 }
        if (gh > 3840) { gw = gw * 3840 / gh; gh = 3840 }
        gw = int(gw / 16 + 0.5) * 16; gh = int(gh / 16 + 0.5) * 16
        while (gw * gh > 8294400 || gw > 3840 || gh > 3840) { if (gw >= gh) gw -= 16; else gh -= 16 }
        while (gw * gh < 655360) { if (gw <= gh) gw += 16; else gh += 16 }
        printf "%dx%d", gw, gh
      }')"
    # A legal target is generated as-is and needs no local resize.
    [ "$GEN_SIZE" = "$SIZE" ] && { TARGET_W=""; TARGET_H=""; }
    ;;
esac

# ---------------------------------------------------------------- Claude Code config
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings_val() { # read "KEY": "value" from Claude Code settings (env block or top level)
  local f v
  for f in "$CONFIG_DIR/settings.local.json" "$CONFIG_DIR/settings.json"; do
    [ -f "$f" ] || continue
    v="$(grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" "$f" 2>/dev/null | head -n 1 \
      | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"(.*)"$/\1/; s/\\"/"/g; s#\\/#/#g; s/\\\\/\\/g')"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# BUZZ_BASE_URL overrides Claude Code's address, for setups where Claude Code
# talks to BUZZ through a local relay or proxy.
BASE="${BUZZ_BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
[ -n "$BASE" ] || BASE="$(settings_val BUZZ_BASE_URL || settings_val ANTHROPIC_BASE_URL || true)"
# BUZZ_IMAGE_API_KEY: an optional key just for images (e.g. a token in a group that
# has gpt-image models), so chat and images can use different keys at the same time.
KEY="${BUZZ_IMAGE_API_KEY:-}"
[ -n "$KEY" ] || KEY="$(settings_val BUZZ_IMAGE_API_KEY || true)"
[ -n "$KEY" ] || KEY="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
[ -n "$KEY" ] || KEY="$(settings_val ANTHROPIC_AUTH_TOKEN || settings_val ANTHROPIC_API_KEY || true)"
if [ -z "$KEY" ]; then
  # Claude Code's apiKeyHelper: a command that prints the key. Run it the same way.
  HELPER="$(settings_val apiKeyHelper || true)"
  [ -n "$HELPER" ] && KEY="$(bash -c "$HELPER" 2>/dev/null | head -n 1 | tr -d '\r\n' || true)"
fi
[ -n "$BASE" ] || fail not_buzz "Claude Code is not connected to BUZZ (ANTHROPIC_BASE_URL is not set)."
BASE="${BASE%/}"; BASE="${BASE%/v1}"; BASE="${BASE%/}"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t buzzimg)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM HUP

# The key reaches curl only through a pipe (curl -K - reads its config from
# stdin): never on a command line (process list) and never written to disk.
# printf is a shell builtin, so it doesn't show up as a process either.
auth_cfg() { printf 'header = "Authorization: Bearer %s"\n' "$KEY"; }

# Identify the gateway before any key leaves this machine. A relay in front of
# BUZZ may refuse anonymous requests, so retry once with the key: it goes only to
# the address Claude Code already sends it to (or the BUZZ_BASE_URL the user set).
is_buzz() { printf '%s' "$1" | grep -Eq '"gateway"[[:space:]]*:[[:space:]]*"buzz"'; }
STATUS="$(curl -sS --max-time 20 "$BASE/api/status" 2>/dev/null || true)"
if ! is_buzz "$STATUS" && [ -n "$KEY" ]; then
  STATUS="$(auth_cfg | curl -sS --max-time 20 -K - "$BASE/api/status" 2>/dev/null || true)"
fi
is_buzz "$STATUS" || fail not_buzz "$BASE did not identify itself as BUZZ, so buzz-image will not use it. If Claude Code reaches BUZZ through a local relay or proxy, set BUZZ_BASE_URL to your BUZZ API address (as an environment variable, or in the env block of Claude Code's settings.json)."
[ -n "$KEY" ] || fail no_key "No API key found in Claude Code's configuration."

# ---------------------------------------------------------------- models
MCODE="$(auth_cfg | curl -sS --max-time 30 -o "$TMP/models.json" -w '%{http_code}' -K - "$BASE/v1/models" 2>/dev/null)" || MCODE="000"
if [ "$MCODE" != "200" ]; then
  msg="$(grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/models.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/')"
  fail http_error "Could not list models (HTTP $MCODE)${msg:+: $msg}"
fi
AVAILABLE="$(grep -o '"id"[[:space:]]*:[[:space:]]*"gpt-image[^"]*"' "$TMP/models.json" | sed -E 's/.*"(gpt-image[^"]*)"$/\1/' | sort -u)"
models_json() { local out="" m; for m in $AVAILABLE; do out="${out:+$out,}\"$m\""; done; printf '[%s]' "$out"; }

if [ -z "$AVAILABLE" ]; then
  fail no_image_model "Your key's group has no GPT Image model. Change the key's group in the BUZZ console to one that includes gpt-image models, or set BUZZ_IMAGE_API_KEY to a separate key whose group has them." '"available_models":[]'
fi
if [ "$LIST_MODELS" -eq 1 ]; then
  printf '{"ok":true,"models":%s}\n' "$(models_json)"
  exit 0
fi
if [ -n "$MODEL" ]; then
  printf '%s\n' "$AVAILABLE" | grep -qx "$MODEL" \
    || fail model_unavailable "Model $MODEL is not available for this key." "\"available_models\":$(models_json)"
else
  for m in gpt-image-2.5-flare gpt-image-2.5-sunburst gpt-image-2; do
    printf '%s\n' "$AVAILABLE" | grep -qx "$m" && { MODEL="$m"; break; }
  done
  [ -n "$MODEL" ] || MODEL="$(printf '%s\n' "$AVAILABLE" | head -1)"
fi

# ---------------------------------------------------------------- output paths
EXT="$FORMAT"; [ "$EXT" = "jpeg" ] && EXT="jpg"
[ -n "$OUT" ] || OUT="generated/image-$(date +%Y%m%d-%H%M%S).$EXT"
case "$(basename "$OUT")" in *.*) ;; *) OUT="$OUT.$EXT" ;; esac
mkdir -p "$(dirname "$OUT")" 2>/dev/null || fail bad_args "cannot create directory $(dirname "$OUT")"
STEM="${OUT%.*}"; OEXT="${OUT##*.}"
unique_path() { local p="$OUT" i=2; while [ -e "$p" ]; do p="${STEM}-${i}.${OEXT}"; i=$((i+1)); done; printf '%s' "$p"; }

# ---------------------------------------------------------------- requests
# Git Bash's curl is a native Windows program: inside "-F name=@path" the shell
# does not translate /c/... or /tmp/... paths for it, so do it here.
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

b64decode() { base64 -d 2>/dev/null || base64 -D; }

request_one() { # one image per request; runs in the background
  local i="$1" resp="$TMP/resp-$1.json" code rc
  if [ ${#REFS[@]} -gt 0 ]; then
    # --form-string: a prompt starting with "@" or "<" must never be read as a file.
    local args=(--form-string "model=$MODEL" --form-string "prompt=$PROMPT" -F "n=1" -F "output_format=$FORMAT")
    [ -n "$GEN_SIZE" ] && args+=(--form-string "size=$GEN_SIZE")
    [ -n "$QUALITY" ] && args+=(--form-string "quality=$QUALITY")
    [ -n "$BACKGROUND" ] && args+=(--form-string "background=$BACKGROUND")
    local r; for r in "${REFS[@]}"; do args+=(-F "image[]=@$(native_path "$r")"); done
    [ -n "$MASK" ] && args+=(-F "mask=@$(native_path "$MASK")")
    code="$(auth_cfg | curl -sS --max-time 540 -o "$resp" -w '%{http_code}' -K - "${args[@]}" "$BASE/v1/images/edits" 2>"$TMP/err-$i")"
    rc=$?
  else
    local body="{\"model\":\"$(json_escape "$MODEL")\",\"prompt\":\"$(json_escape "$PROMPT")\",\"n\":1,\"output_format\":\"$FORMAT\""
    [ -n "$GEN_SIZE" ] && body="$body,\"size\":\"$GEN_SIZE\""
    [ -n "$QUALITY" ] && body="$body,\"quality\":\"$QUALITY\""
    [ -n "$BACKGROUND" ] && body="$body,\"background\":\"$BACKGROUND\""
    body="$body}"
    # stdin carries the key, so the (non-secret) body goes through a file.
    printf '%s' "$body" > "$TMP/body-$i.json"
    code="$(auth_cfg | curl -sS --max-time 540 -o "$resp" -w '%{http_code}' \
      -K - -H "Content-Type: application/json" --data-binary "@$(native_path "$TMP/body-$i.json")" \
      "$BASE/v1/images/generations" 2>"$TMP/err-$i")"
    rc=$?
  fi
  [ "$rc" -eq 28 ] && code="timeout"
  [ -n "$code" ] || code="000"
  printf '%s' "$code" > "$TMP/code-$i"
}

# Map a failed response to one of the spec's error codes.
classify() { # classify HTTP_CODE RESPONSE_FILE -> "code|message"
  local http="$1" f="$2" msg ecode lower
  msg="$(grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/')"
  ecode="$(grep -o '"code"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/')"
  lower="$(printf '%s %s' "$ecode" "$msg" | tr 'A-Z' 'a-z')"
  if [ "$http" = "timeout" ]; then printf 'timeout|Request timed out after 540s. Not retried automatically: the image may still have been generated and billed.'; return; fi
  if [ "$http" = "000" ]; then printf 'http_error|Network error: %s' "$(tr '\n' ' ' < "$TMP/err-$3" 2>/dev/null)"; return; fi
  case "$lower" in
    *insufficient*quota*|*quota*insufficient*|*insufficient_user_quota*|*余额不足*|*额度不足*|*balance*) printf 'insufficient_balance|%s' "${msg:-Insufficient balance}"; return ;;
    *moderation*|*content_policy*|*safety*|*policy*|*violat*|*审核*|*违规*) printf 'content_policy|%s' "${msg:-Rejected by content policy}"; return ;;
    *model_not_found*|*暂时不可用*|*not*available*|*no*available*channel*|*无可用渠道*) printf 'model_unavailable|%s' "${msg:-Model unavailable}"; return ;;
  esac
  printf 'http_error|HTTP %s%s' "$http" "${msg:+: $msg}"
}

# ---------------------------------------------------------------- local resize
# Cover-scale then centre-crop to exactly TARGET_W x TARGET_H, keeping alpha.
resize_reason=""
resize_to_target() { # resize_to_target FILE W H -> 0 ok / 1 not done (reason in resize_reason)
  local f="$1" tw="$2" th="$3" tmp="$TMP/resize.$OEXT"
  if command -v sips >/dev/null 2>&1; then
    if [ "$FORMAT" = "webp" ]; then resize_reason="sips cannot write webp"; return 1; fi
    local w h
    w="$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    h="$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    [ -n "$w" ] && [ -n "$h" ] || { resize_reason="sips could not read the image"; return 1; }
    local dims; dims="$(awk -v w="$w" -v h="$h" -v tw="$tw" -v th="$th" 'BEGIN{s=tw/w; if (th/h>s) s=th/h; printf "%d %d", int(h*s+0.999), int(w*s+0.999)}')"
    sips -z ${dims% *} ${dims#* } "$f" --out "$tmp" >/dev/null 2>&1 \
      && sips -c "$th" "$tw" "$tmp" --out "$f" >/dev/null 2>&1 && return 0
    resize_reason="sips failed"; return 1
  fi
  if command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    if [ "$FORMAT" = "webp" ]; then resize_reason="Windows built-in imaging cannot write webp"; return 1; fi
    BUZZ_RS_IN="$(cygpath -w "$f")" BUZZ_RS_W="$tw" BUZZ_RS_H="$th" BUZZ_RS_FMT="$FORMAT" \
    powershell.exe -NoProfile -NonInteractive -Command '
      Add-Type -AssemblyName System.Drawing
      $p = $env:BUZZ_RS_IN; $tw = [int]$env:BUZZ_RS_W; $th = [int]$env:BUZZ_RS_H
      $src = [System.Drawing.Image]::FromFile($p)
      try {
        $s = [Math]::Max($tw / $src.Width, $th / $src.Height)
        $dw = [int][Math]::Ceiling($src.Width * $s); $dh = [int][Math]::Ceiling($src.Height * $s)
        $bmp = New-Object System.Drawing.Bitmap($tw, $th, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.DrawImage($src, [int](($tw - $dw) / 2), [int](($th - $dh) / 2), $dw, $dh)
        $g.Dispose()
      } finally { $src.Dispose() }
      $fmt = if ($env:BUZZ_RS_FMT -eq "jpeg") { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
      $bmp.Save($p, $fmt); $bmp.Dispose()
    ' >/dev/null 2>&1 && return 0
    resize_reason="Windows built-in imaging failed"; return 1
  fi
  local im=""
  command -v magick >/dev/null 2>&1 && im="magick"
  [ -z "$im" ] && command -v convert >/dev/null 2>&1 && im="convert"
  if [ -n "$im" ]; then
    "$im" "$f" -background none -resize "${tw}x${th}^" -gravity center -extent "${tw}x${th}" "$tmp" >/dev/null 2>&1 \
      && mv -f "$tmp" "$f" && return 0
    resize_reason="ImageMagick failed"; return 1
  fi
  resize_reason="no local image tool (install ImageMagick to get exact sizes)"
  return 1
}

# Pixel size of a saved image as "W H"; empty when it cannot be read.
image_dims() {
  local f="$1" d=""
  if [ "$(head -c 8 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
    od -An -tu1 -j16 -N8 "$f" | tr '\n' ' ' | awk 'NF>=8{printf "%d %d", (($1*256+$2)*256+$3)*256+$4, (($5*256+$6)*256+$7)*256+$8}'
    return
  fi
  if command -v sips >/dev/null 2>&1; then
    d="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{if (w && h) printf "%d %d", w, h}')"
  elif command -v magick >/dev/null 2>&1; then
    d="$(magick identify -format '%w %h' "$f[0]" 2>/dev/null)"
  elif command -v identify >/dev/null 2>&1; then
    d="$(identify -format '%w %h' "$f[0]" 2>/dev/null)"
  elif command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    d="$(BUZZ_RS_IN="$(cygpath -w "$f")" powershell.exe -NoProfile -NonInteractive -Command '
      Add-Type -AssemblyName System.Drawing
      $i = [System.Drawing.Image]::FromFile($env:BUZZ_RS_IN); "$($i.Width) $($i.Height)"; $i.Dispose()' 2>/dev/null | tr -d '\r')"
  fi
  if printf '%s' "$d" | grep -Eq '^[0-9]+ [0-9]+$'; then printf '%s' "$d"; fi
}

# The size the saved files must end up at: an exact -s WxH, or the size sent to
# the model. Models may return fewer pixels than asked (same aspect ratio), so
# every file is measured and scaled to this size when it differs.
WANT_W="$TARGET_W" WANT_H="$TARGET_H"
if [ -z "$WANT_W" ] && [ -n "$GEN_SIZE" ]; then WANT_W="${GEN_SIZE%x*}"; WANT_H="${GEN_SIZE#*x}"; fi

# ---------------------------------------------------------------- run
START=$(date +%s)
for i in $(seq 1 "$N"); do request_one "$i" & done
wait
ELAPSED=$(( $(date +%s) - START ))

FILES=() ERRORS=() FIRST_CODE="" FIRST_MSG="" RESIZED="" RESIZE_NOTE="" GOT_SIZE="" FINAL_SIZE=""
for i in $(seq 1 "$N"); do
  resp="$TMP/resp-$i.json"; code="$(cat "$TMP/code-$i" 2>/dev/null || echo 000)"
  b64="" url=""
  if [ "$code" = "200" ]; then
    b64="$(grep -o '"b64_json"[[:space:]]*:[[:space:]]*"[^"]*"' "$resp" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')"
    [ -n "$b64" ] || url="$(grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$resp" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/; s#\\/#/#g; s/\\u0026/\&/g')"
  fi
  if [ -z "$b64" ] && [ -z "$url" ]; then
    c="$(classify "$code" "$resp" "$i")"
    [ "$code" = "200" ] && c="http_error|No image in the response"
    ERRORS+=("${c#*|}")
    [ -n "$FIRST_CODE" ] || { FIRST_CODE="${c%%|*}"; FIRST_MSG="${c#*|}"; }
    continue
  fi
  target="$(unique_path)"
  if [ -n "$b64" ]; then
    printf '%s' "$b64" | b64decode > "$target" 2>/dev/null
  else
    curl -sS --max-time 120 -o "$target" "$url" 2>/dev/null
  fi
  if [ ! -s "$target" ]; then
    rm -f "$target"; ERRORS+=("could not save the image")
    [ -n "$FIRST_CODE" ] || { FIRST_CODE="http_error"; FIRST_MSG="could not save the image"; }
    continue
  fi
  dims="$(image_dims "$target")"
  [ -n "$GOT_SIZE" ] || GOT_SIZE="${dims/ /x}"
  # Scale when the measured size differs. If it can't be measured, scale only
  # sizes the model can't produce at all (it never returns those as asked).
  need=0
  if [ -n "$WANT_W" ]; then
    if [ -n "$dims" ]; then [ "$dims" != "$WANT_W $WANT_H" ] && need=1
    elif [ -n "$TARGET_W" ]; then need=1; fi
  fi
  # --no-upscale: a smaller image at the requested aspect ratio (within 1%) is kept as is.
  if [ "$need" -eq 1 ] && [ "$NO_UPSCALE" -eq 1 ] && [ -n "$dims" ] \
     && awk -v w="${dims% *}" -v h="${dims#* }" -v W="$WANT_W" -v H="$WANT_H" \
          'BEGIN { r = (w / h) / (W / H); exit !(w <= W && h <= H && r > 0.99 && r < 1.01) }'; then
    need=0; RESIZE_NOTE="kept the model's smaller image as is (--no-upscale)"
  fi
  if [ "$need" -eq 1 ]; then
    if resize_to_target "$target" "$WANT_W" "$WANT_H"; then
      RESIZED="true"; dims="$(image_dims "$target")"; [ -n "$dims" ] || dims="$WANT_W $WANT_H"
    else
      RESIZED="false"; RESIZE_NOTE="$resize_reason"
    fi
  fi
  [ -n "$FINAL_SIZE" ] || FINAL_SIZE="${dims/ /x}"
  FILES+=("$target")
done

list_json() { local out="" x; for x in "$@"; do out="${out:+$out,}\"$(json_escape "$x")\""; done; printf '[%s]' "$out"; }

if [ ${#FILES[@]} -eq 0 ]; then
  printf '{"ok":false,"code":"%s","message":"%s","model":"%s","seconds":%d,"errors":%s}\n' \
    "${FIRST_CODE:-http_error}" "$(json_escape "$FIRST_MSG")" "$MODEL" "$ELAPSED" "$(list_json "${ERRORS[@]+"${ERRORS[@]}"}")"
  exit 1
fi

# size: measured pixels of the saved file(s); generated_size: what the model returned.
[ -n "$FINAL_SIZE" ] || FINAL_SIZE="unknown"
[ -n "$GOT_SIZE" ] || GOT_SIZE="unknown"
extra=""
[ -n "$WANT_W" ] && extra=",\"requested_size\":\"${WANT_W}x${WANT_H}\",\"resized\":${RESIZED:-false}"
[ -n "$RESIZE_NOTE" ] && extra="$extra,\"resize_note\":\"$(json_escape "$RESIZE_NOTE")\""
printf '{"ok":true,"model":"%s","files":%s,"size":"%s","generated_size":"%s"%s,"seconds":%d,"errors":%s}\n' \
  "$MODEL" "$(list_json "${FILES[@]}")" "$FINAL_SIZE" "$GOT_SIZE" "$extra" "$ELAPSED" \
  "$(list_json "${ERRORS[@]+"${ERRORS[@]}"}")"
