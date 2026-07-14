#!/usr/bin/env bash
set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# agent-rules-skill — project executables updater
#
# Refreshes the executables a bootstrapped project copied from this skill:
#   bin/sync-agent-config          (port matching the configured runtime)
#   .agents/hooks/sync-on-edit.sh  (only when the project already has it)
#
# Project data is never touched: AGENTS.md, .agents/** sources and
# bin/sync-agent-config-options.json stay as they are.
#
# Usage:
#   ./update.sh [project-path] [--runtime ruby|node|python|bun]
#
# Without a project path on a terminal, an interactive step-by-step wizard
# (like install.sh) asks for the project and runtime. Non-interactive runs
# default to the current directory.
#
# The runtime defaults to the one saved by install.sh in
# $XDG_CONFIG_HOME/agent-rules-skill/config.json (auto-detected when unset).
# ─────────────────────────────────────────────────────────────────────────────

GUM_VERSION="v0.16.2"
GUM_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules-skill/bin"
GUM_BIN="$GUM_CACHE_DIR/gum"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/agent-rules-skill/config.json"
GUM=""

usage() {
  sed -n '/^# agent-rules-skill/,/^# ────/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'
}

# ── Runtime helpers (mirrors install.sh) ──────────────────────────────────────

resolve_runtime() {
  case "$1" in
    ruby|node|python|bun) echo "$1"; return ;;
  esac
  local candidate
  for candidate in ruby node python3 bun; do
    if command -v "$candidate" >/dev/null 2>&1; then
      [[ "$candidate" == "python3" ]] && echo "python" || echo "$candidate"
      return
    fi
  done
  echo "ruby"
}

# Template file + interpreter binary for a concrete runtime. Bun runs the same
# source as the Node port.
runtime_template() {
  case "$1" in
    node|bun) echo "sync-agent-config.js" ;;
    python)   echo "sync-agent-config.py" ;;
    *)        echo "sync-agent-config"    ;;
  esac
}

runtime_interpreter() {
  case "$1" in
    node)   echo "node"    ;;
    bun)    echo "bun"     ;;
    python) echo "python3" ;;
    *)      echo "ruby"    ;;
  esac
}

config_runtime() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  sed -n 's/.*"runtime"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$CONFIG_FILE" | head -n 1
}

# ── gum bootstrap + styling (mirrors install.sh; used by the wizard only) ─────

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="Darwin" ;;
    Linux)  os="Linux"  ;;
    *)
      echo "Unsupported system: $(uname -s)" >&2
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64"  ;;
    x86_64|amd64)  arch="x86_64" ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
  echo "${os}_${arch}"
}

ensure_gum() {
  if command -v gum >/dev/null 2>&1; then
    GUM="gum"
    return
  fi
  if [[ -x "$GUM_BIN" ]]; then
    GUM="$GUM_BIN"
    return
  fi

  mkdir -p "$GUM_CACHE_DIR"
  local platform archive url tmp
  platform="$(detect_platform)"
  archive="gum_${GUM_VERSION#v}_${platform}.tar.gz"
  url="https://github.com/charmbracelet/gum/releases/download/${GUM_VERSION}/${archive}"
  tmp="$(mktemp -d)"

  echo "gum not found — downloading ${GUM_VERSION} for ${platform}..."
  curl -fsSL "$url" -o "$tmp/gum.tar.gz"
  tar -xzf "$tmp/gum.tar.gz" -C "$tmp"
  find "$tmp" -type f -name gum -exec cp {} "$GUM_BIN" \;
  chmod +x "$GUM_BIN"
  rm -rf "$tmp"

  GUM="$GUM_BIN"
}

header() {
  "$GUM" style \
    --border rounded \
    --border-foreground 212 \
    --padding "1 3" \
    --margin "1 0" \
    --bold \
    --foreground 212 \
    "agent-rules-skill — update"

  "$GUM" style \
    --foreground 240 \
    --margin "0 0 1 0" \
    "Refresh a project's copied executables from the current templates"
}

section() {
  echo
  "$GUM" style --foreground 212 --bold "$1"
}

kv() {
  "$GUM" join --horizontal \
    "$("$GUM" style --foreground 244 --width 12 "  $1")" \
    "$("$GUM" style --foreground 252 "$2")"
}

# Styled when the wizard is active, plain otherwise, so both paths share the
# same update code below.
say_success() { if [[ -n "$GUM" ]]; then "$GUM" style --foreground 82  "  ✅ $1"; else echo "✅ $1"; fi }
say_info()    { if [[ -n "$GUM" ]]; then "$GUM" style --foreground 244 "  ℹ️  $1"; else echo "ℹ️  $1"; fi }
say_muted()   { if [[ -n "$GUM" ]]; then "$GUM" style --foreground 240 "  $1";    else echo "$1"; fi }
say_warn()    { if [[ -n "$GUM" ]]; then "$GUM" style --foreground 214 "  ⚠️  $1" >&2; else echo "⚠️  $1" >&2; fi }

# ── Argument parsing ──────────────────────────────────────────────────────────

PROJECT_DIR=""
RUNTIME_CHOICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)   RUNTIME_CHOICE="${2:-}"; shift 2 ;;
    --runtime=*) RUNTIME_CHOICE="${1#--runtime=}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -n "$PROJECT_DIR" ]]; then
        echo "Only one project path is accepted (got '$PROJECT_DIR' and '$1')." >&2
        exit 1
      fi
      PROJECT_DIR="$1"; shift
      ;;
  esac
done

# ── Wizard (no path given on a terminal) ──────────────────────────────────────

if [[ -z "$PROJECT_DIR" ]] && [[ -t 0 ]]; then
  ensure_gum
  header

  # 1. Project
  section "📍 Which project should be updated?"
  PROJECT_DIR=$("$GUM" input \
    --value "$PWD" \
    --placeholder "/absolute/path/to/project" \
    --prompt "  Project path: ")
  if [[ -z "$PROJECT_DIR" || ! -d "$PROJECT_DIR" ]]; then
    say_warn "Invalid or non-existent path: ${PROJECT_DIR:-<empty>}"
    exit 1
  fi

  # 2. Runtime (skipped when --runtime was passed)
  if [[ -z "$RUNTIME_CHOICE" ]]; then
    section "🧰 Which runtime should run bin/sync-agent-config?"
    SAVED_RUNTIME="$(config_runtime)"
    RUNTIME_OPTIONS=()
    if [[ -n "$SAVED_RUNTIME" ]]; then
      say_muted "enter keeps the preference saved by install.sh"
      RUNTIME_OPTIONS+=("saved — installer preference ($SAVED_RUNTIME)")
    fi
    RUNTIME_OPTIONS+=(
      "auto — detect an available runtime"
      "ruby — reference implementation"
      "node — Node.js port"
      "bun — Node port on the Bun runtime"
      "python — Python 3 port"
    )
    RUNTIME_RAW=$("$GUM" choose "${RUNTIME_OPTIONS[@]}")
    case "$RUNTIME_RAW" in
      saved*)  RUNTIME_CHOICE="$SAVED_RUNTIME" ;;
      ruby*)   RUNTIME_CHOICE="ruby"   ;;
      node*)   RUNTIME_CHOICE="node"   ;;
      bun*)    RUNTIME_CHOICE="bun"    ;;
      python*) RUNTIME_CHOICE="python" ;;
      *)       RUNTIME_CHOICE="auto"   ;;
    esac
  fi

  # 3. Review
  RUNTIME_PREVIEW="$(resolve_runtime "$RUNTIME_CHOICE")"
  section "🔎 Review"
  kv "Project" "$PROJECT_DIR"
  kv "Runtime" "$RUNTIME_PREVIEW"
  kv "Updates" "bin/sync-agent-config · .agents/hooks/sync-on-edit.sh"
  echo

  if ! "$GUM" confirm "Update this project?"; then
    say_muted "Update cancelled."
    exit 0
  fi

  section "🚀 Updating"
fi

PROJECT_DIR="${PROJECT_DIR:-$PWD}"

# ── Validation ────────────────────────────────────────────────────────────────

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Invalid or non-existent project path: $PROJECT_DIR" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

SYNC_TARGET="$PROJECT_DIR/bin/sync-agent-config"
if [[ ! -f "$SYNC_TARGET" ]]; then
  say_warn "No bin/sync-agent-config found in $PROJECT_DIR."
  say_warn "This project does not look bootstrapped — run the skill first (see SKILL.md)."
  exit 1
fi

RUNTIME="$(resolve_runtime "${RUNTIME_CHOICE:-$(config_runtime)}")"
RUNTIME_BIN="$(runtime_interpreter "$RUNTIME")"
TEMPLATE="$SKILL_DIR/templates/$(runtime_template "$RUNTIME")"

if ! command -v "$RUNTIME_BIN" >/dev/null 2>&1; then
  say_warn "'$RUNTIME_BIN' is not on PATH — bin/sync-agent-config will need it to run."
fi

# ── Update ────────────────────────────────────────────────────────────────────

# Stage the template so runtime-specific tweaks (bun shebang) happen before the
# copy/compare, keeping reruns idempotent.
STAGED="$(mktemp)"
trap 'rm -f "$STAGED"' EXIT
cp "$TEMPLATE" "$STAGED"
if [[ "$RUNTIME" == "bun" ]]; then
  # Hooks execute bin/sync-agent-config directly, so the shebang must call bun.
  sed -i.bak '1s|env node|env bun|' "$STAGED" && rm -f "$STAGED.bak"
fi

update_file() { # <staged-src> <dst> <label>
  local src="$1" dst="$2" label="$3"
  if cmp -s "$src" "$dst"; then
    chmod +x "$dst"
    say_success "$label already up to date"
    return
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  say_success "$label updated"
}

[[ -n "$GUM" ]] || echo "Updating project executables in $PROJECT_DIR [runtime: $RUNTIME]"
update_file "$STAGED" "$SYNC_TARGET" "bin/sync-agent-config"

HOOK_TARGET="$PROJECT_DIR/.agents/hooks/sync-on-edit.sh"
if [[ -f "$HOOK_TARGET" ]]; then
  update_file "$SKILL_DIR/templates/sync-on-edit.sh" "$HOOK_TARGET" ".agents/hooks/sync-on-edit.sh"
else
  say_info ".agents/hooks/sync-on-edit.sh not present — skipped"
fi

say_muted "Done. Run 'bin/sync-agent-config --check' inside the project to verify drift."
