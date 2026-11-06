#!/usr/bin/env bash
################################################################################
# BUZZ AI - buzz-image skill 安装器
#
# 安装 / 更新: curl -fsSL https://buzzai.cc/sh/buzz-image.sh | bash
# 卸载:        curl -fsSL https://buzzai.cc/sh/buzz-image.sh | bash -s -- --uninstall
#              (或设置环境变量 BUZZ_IMAGE_UNINSTALL=1)
# 帮助:        bash buzz-image.sh --help
#
# 只写入 $CLAUDE_CONFIG_DIR/skills/buzz-image/ (默认 ~/.claude),不修改其他任何文件。
# 不读取、不打印 API key。依赖: bash、curl 与常见的 coreutils。
################################################################################

BUZZ_SITES="https://buzzai.cc https://buzzgw.com"
SKILL_REL="sh/skills/buzz-image"
DOCS_URL="https://buzzai.cc/docs/guides/claude-code-image.html"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
GOLD='\033[38;5;220m'
NC='\033[0m'

if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
  RED="" GREEN="" YELLOW="" CYAN="" WHITE="" GRAY="" BOLD="" GOLD="" NC=""
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INSTALL_DIR="$CONFIG_DIR/skills/buzz-image"
TMP_DIR=""

# 语言: zh | en。由环境 LC_ALL / LANG 自动检测,默认 zh。
LANG_CHOICE="zh"

################################################################################
# i18n 与输出
################################################################################

# 用法: t '中文文案' 'English text'
t() {
  if [ "$LANG_CHOICE" = "en" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

detect_lang() {
  local loc="${LC_ALL:-${LANG:-}}"
  case "$loc" in
    en*|EN*) LANG_CHOICE="en" ;;
    *)       LANG_CHOICE="zh" ;;
  esac
}

print_status() {
  local type="$1"
  local message="$2"
  case "$type" in
    ok)    echo -e "  ${GREEN}[OK]${NC} $message" ;;
    info)  echo -e "  ${CYAN}[*]${NC} $message" ;;
    warn)  echo -e "  ${YELLOW}[!]${NC} $message" ;;
    error) echo -e "  ${RED}[x]${NC} $message" ;;
    *)     echo "  $message" ;;
  esac
}

# 出错即打印并退出。只在脚本自身的子进程中退出,不影响用户 shell。
die() {
  print_status error "$1"
  exit 1
}

show_help() {
  if [ "$LANG_CHOICE" = "en" ]; then
    cat << 'EOF'

  BUZZ AI - buzz-image skill installer

  Usage:
    curl -fsSL https://buzzai.cc/sh/buzz-image.sh | bash     install / update
    bash buzz-image.sh --uninstall                           uninstall
    bash buzz-image.sh --help                                show this help

  Environment:
    BUZZ_SITE=URL             download site (default: try buzzai.cc, then buzzgw.com)
    CLAUDE_CONFIG_DIR=DIR     Claude Code config dir (default: ~/.claude)
    BUZZ_IMAGE_UNINSTALL=1    same as --uninstall

EOF
  else
    cat << 'EOF'

  BUZZ AI - buzz-image skill 安装器

  用法:
    curl -fsSL https://buzzai.cc/sh/buzz-image.sh | bash     安装 / 更新
    bash buzz-image.sh --uninstall                           卸载
    bash buzz-image.sh --help                                显示帮助

  环境变量:
    BUZZ_SITE=URL             指定下载站点(默认依次尝试 buzzai.cc、buzzgw.com)
    CLAUDE_CONFIG_DIR=DIR     Claude Code 配置目录(默认 ~/.claude)
    BUZZ_IMAGE_UNINSTALL=1    等同于 --uninstall

EOF
  fi
  exit 0
}

################################################################################
# 下载与校验
################################################################################

# fetch <url> <dest>: 下载单个文件,失败返回非 0
fetch() {
  curl -fsSL --connect-timeout 10 --max-time 120 -o "$2" "$1"
}

# validate <file> <name>: 非空;SKILL.md 首行必须是 ---;任何文件都不能是 HTML 错误页
validate_file() {
  local f="$1" name="$2" first
  if [ ! -s "$f" ]; then
    print_status error "$(t "文件为空" "empty file"): $name"
    return 1
  fi
  first="$(head -n 1 "$f" | tr -d '\r')"
  first="${first#$'\xef\xbb\xbf'}"
  if [ "$name" = "SKILL.md" ] && [ "$first" != "---" ]; then
    print_status error "$(t "SKILL.md 格式不正确(首行应为 ---)" "SKILL.md is malformed (first line should be ---)")"
    return 1
  fi
  case "$first" in
    "<"*)
      print_status error "$(t "下载到的不是 skill 文件(疑似 HTML 页面)" "downloaded content is not a skill file (looks like HTML)"): $name"
      return 1 ;;
  esac
  return 0
}

# 依次尝试站点,第一个能成功下载并通过校验的 SKILL.md 决定站点;返回站点到 SITE 变量
pick_site() {
  local candidates site
  if [ -n "${BUZZ_SITE:-}" ]; then
    candidates="${BUZZ_SITE%/}"
  else
    candidates="$BUZZ_SITES"
  fi
  for site in $candidates; do
    print_status info "$(t "正在从 $site 下载 skill 文件" "Downloading skill files from $site")"
    if fetch "$site/$SKILL_REL/SKILL.md" "$TMP_DIR/SKILL.md" 2>/dev/null \
       && validate_file "$TMP_DIR/SKILL.md" "SKILL.md"; then
      SITE="$site"
      return 0
    fi
    rm -f "$TMP_DIR/SKILL.md"
    print_status warn "$site $(t "不可用,尝试下一个站点" "unavailable, trying next site")"
  done
  return 1
}

download_skill() {
  local rel
  mkdir -p "$TMP_DIR/scripts" || die "$(t "无法创建临时目录" "cannot create temp directory")"
  if ! pick_site; then
    die "$(t "所有站点都下载失败,请检查网络后重试" "all sites failed; check your network and retry")"
  fi
  for rel in scripts/gen.sh scripts/gen.ps1; do
    if ! fetch "$SITE/$SKILL_REL/$rel" "$TMP_DIR/$rel"; then
      die "$(t "下载失败" "download failed"): $rel"
    fi
    validate_file "$TMP_DIR/$rel" "$rel" || die "$(t "校验失败,已中止安装,旧版本未改动" "validation failed; install aborted, existing install untouched")"
  done
  print_status ok "$(t "文件已下载并通过校验" "files downloaded and validated")"
}

################################################################################
# 安装 / 卸载
################################################################################

# 先整体组装到临时暂存目录,再替换旧目录;替换失败时还原旧版本
install_skill() {
  local skills_dir="$CONFIG_DIR/skills"
  local stamp="$$"
  local stage="$skills_dir/.buzz-image.new.$stamp"
  local backup="$skills_dir/.buzz-image.old.$stamp"
  local had_old=0

  mkdir -p "$stage/scripts" || die "$(t "无法创建目录" "cannot create directory"): $stage"
  cp "$TMP_DIR/SKILL.md" "$stage/SKILL.md" \
    && cp "$TMP_DIR/scripts/gen.sh" "$TMP_DIR/scripts/gen.ps1" "$stage/scripts/" \
    || { rm -rf "$stage"; die "$(t "复制文件失败" "failed to copy files")"; }
  chmod +x "$stage/scripts/gen.sh"

  if [ -e "$INSTALL_DIR" ]; then
    had_old=1
    rm -rf "$backup"
    if ! mv "$INSTALL_DIR" "$backup"; then
      rm -rf "$stage"
      die "$(t "无法替换旧版本" "cannot replace the existing install"): $INSTALL_DIR"
    fi
  fi

  if mv "$stage" "$INSTALL_DIR"; then
    [ "$had_old" = "1" ] && rm -rf "$backup"
    return 0
  fi

  rm -rf "$stage"
  if [ "$had_old" = "1" ]; then
    mv "$backup" "$INSTALL_DIR" 2>/dev/null
  fi
  die "$(t "安装失败,已还原旧版本" "install failed; previous version restored")"
}

print_installed_version() {
  local ver
  ver="$(grep -E '^version:' "$TMP_DIR/SKILL.md" 2>/dev/null | head -n 1 | sed -E 's/^version:[[:space:]]*//' | tr -d "\"' \r")"
  if [ -n "$ver" ]; then
    print_status info "$(t "版本" "Version"): $ver"
  fi
}

# 从 settings.local.json / settings.json 的 env 中读取 ANTHROPIC_BASE_URL(只读地址,不读 key)
settings_base_url() {
  local f v
  for f in "$CONFIG_DIR/settings.local.json" "$CONFIG_DIR/settings.json"; do
    [ -f "$f" ] || continue
    v="$(sed -n 's/.*"ANTHROPIC_BASE_URL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -n 1)"
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 1
}

# 未带鉴权请求 /api/status,确认 Claude Code 接入的是 BUZZ 网关。只提醒,不报错。
check_connection() {
  local base body
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    base="$ANTHROPIC_BASE_URL"
  else
    base="$(settings_base_url)"
  fi
  base="${base%/}"
  base="${base%/v1}"
  base="${base%/}"

  if [ -z "$base" ]; then
    print_status warn "$(t "警告: 未找到 Claude Code 的 ANTHROPIC_BASE_URL 配置" "WARNING: no ANTHROPIC_BASE_URL found in Claude Code config")"
  else
    body="$(curl -fsS --connect-timeout 5 --max-time 10 "$base/api/status" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -Eq '"gateway"[[:space:]]*:[[:space:]]*"buzz"'; then
      print_status ok "$(t "Claude Code 已接入 BUZZ。重启 Claude Code 或运行 /reload-skills,然后直接说要的图片即可。" "Claude Code is connected to BUZZ. Restart Claude Code or run /reload-skills, then just ask for an image.")"
      return 0
    fi
    print_status warn "$(t "警告: 当前地址不是 BUZZ 网关(或暂时无法访问)" "WARNING: the configured base URL is not a BUZZ gateway (or is unreachable)")"
  fi
  print_status warn "$(t "注意: 这个 skill 只有在 Claude Code 接入 BUZZ 后才能使用。接入教程:" "Note: this skill only works when Claude Code is connected to BUZZ. Setup guide:") $DOCS_URL"
  return 0
}

do_install() {
  command -v curl >/dev/null 2>&1 || die "$(t "需要 curl,请先安装" "curl is required, please install it first")"

  print_status info "$(t "安装 buzz-image skill 到" "Installing buzz-image skill to") $INSTALL_DIR"

  TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t buzz-image)" || die "$(t "无法创建临时目录" "cannot create temp directory")"
  trap 'rm -rf "$TMP_DIR"' EXIT

  download_skill
  print_installed_version
  install_skill
  print_status ok "$(t "已安装到" "Installed to") $INSTALL_DIR"

  check_connection
  echo ""
}

do_uninstall() {
  if [ -e "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR" || die "$(t "卸载失败" "uninstall failed"): $INSTALL_DIR"
    print_status ok "$(t "已卸载" "Removed") $INSTALL_DIR"
  else
    print_status info "$(t "未安装 buzz-image,无需卸载" "buzz-image is not installed; nothing to remove")"
  fi
}

################################################################################
# 入口
################################################################################

main() {
  local want_help=0 want_uninstall=0 arg

  detect_lang

  for arg in "$@"; do
    case "$arg" in
      -h|--help)   want_help=1 ;;
      --uninstall) want_uninstall=1 ;;
      *)
        print_status error "$(t "未知参数" "Unknown argument"): $arg ($(t "使用 --help 查看帮助" "use --help for usage"))"
        exit 2 ;;
    esac
  done

  [ "$want_help" = "1" ] && show_help
  if [ "$want_uninstall" = "1" ] || [ "${BUZZ_IMAGE_UNINSTALL:-}" = "1" ]; then
    do_uninstall
  else
    do_install
  fi
}

main "$@"
