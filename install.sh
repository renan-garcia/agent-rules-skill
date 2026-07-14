#!/usr/bin/env bash
set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# agent-rules-skill — interactive installer
# Installs the skill into the skills/ directory of the selected agent tools
# (Cursor, Claude Code, opencode) and saves the generation platform preference
# (cursor, claude, codex, opencode) for the sync script.
# ─────────────────────────────────────────────────────────────────────────────

GUM_VERSION="v0.16.2"
GUM_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules-skill/bin"
GUM_BIN="$GUM_CACHE_DIR/gum"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-rules-skill"
CONFIG_FILE="$CONFIG_DIR/config.json"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Utilities ─────────────────────────────────────────────────────────────────

# Concrete runtime that runs bin/sync-agent-config. "auto" resolves to the first
# interpreter found on this machine, preferring the Ruby reference.
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
    "agent-rules-skill"

  "$GUM" style \
    --foreground 240 \
    --margin "0 0 1 0" \
    "Vendor-neutral bootstrap for Cursor · Claude Code · Codex · opencode"
}

section() {
  echo
  "$GUM" style --foreground 212 --bold "$1"
}

success() {
  "$GUM" style --foreground 82 "  ✅ $1"
}

info() {
  "$GUM" style --foreground 244 "  $1"
}

muted() {
  "$GUM" style --foreground 240 "  $1"
}

warn() {
  "$GUM" style --foreground 214 "  ⚠️  $1"
}

kv() {
  "$GUM" join --horizontal \
    "$("$GUM" style --foreground 244 --width 12 "  $1")" \
    "$("$GUM" style --foreground 252 "$2")"
}

# ── Main logic ────────────────────────────────────────────────────────────────

ensure_gum
header

# ── 1. Scope ──────────────────────────────────────────────────────────────────
section "📍 How do you want to install the skill?"

SCOPE=$("$GUM" choose \
  "Global — for the current user, available in every project" \
  "Project — into a specific repo" \
  "Symlink — point to this folder (ideal during development)")

case "$SCOPE" in
  "Symlink"*)
    SCOPE_KIND="symlink"
    BASE_DIR="$HOME"
    ;;
  "Global"*)
    SCOPE_KIND="global"
    BASE_DIR="$HOME"
    ;;
  "Project"*)
    SCOPE_KIND="project"
    PROJECT_PATH=$("$GUM" input \
      --placeholder "/absolute/path/to/project" \
      --prompt "  Project path: ")
    if [[ -z "$PROJECT_PATH" || ! -d "$PROJECT_PATH" ]]; then
      warn "Invalid or non-existent path: ${PROJECT_PATH:-<empty>}"
      exit 1
    fi
    BASE_DIR="$PROJECT_PATH"
    ;;
esac

# Resolve the skills/ destination of a given tool for the chosen scope.
dest_for_tool() {
  case "$1" in
    "Cursor")      echo "$BASE_DIR/.cursor/skills/agent-rules-skill" ;;
    "Claude Code") echo "$BASE_DIR/.claude/skills/agent-rules-skill" ;;
    "opencode")
      if [[ "$SCOPE_KIND" == "project" ]]; then
        echo "$BASE_DIR/.opencode/skills/agent-rules-skill"
      else
        echo "$BASE_DIR/.config/opencode/skills/agent-rules-skill"
      fi
      ;;
  esac
}

# ── 2. Install targets ────────────────────────────────────────────────────────
section "📦 Install the skill into which tools?"
muted "space to toggle · enter to confirm — Codex has no skills/ dir (generation only)"

TOOLS_RAW=$("$GUM" choose \
  --no-limit \
  --selected "Cursor,Claude Code,opencode" \
  "Cursor" \
  "Claude Code" \
  "opencode")

if [[ -z "$TOOLS_RAW" ]]; then
  warn "No install target selected. Exiting."
  exit 1
fi

INSTALL_TOOLS=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  INSTALL_TOOLS+=("$line")
done <<< "$TOOLS_RAW"

# ── 3. Generation platforms ───────────────────────────────────────────────────
section "⚙️  Which platforms should sync-agent-config generate for?"
muted "saved as your default — Codex is generation-only"

GEN_RAW=$("$GUM" choose \
  --no-limit \
  --selected "Cursor,Claude Code,Codex,opencode" \
  "Cursor" \
  "Claude Code" \
  "Codex" \
  "opencode")

if [[ -z "$GEN_RAW" ]]; then
  warn "No generation platform selected. Exiting."
  exit 1
fi

PLATFORMS_JSON="["
PLATFORMS_LIST=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  PLATFORMS_LIST+=("$line")
  case "$line" in
    "Cursor")      PLATFORMS_JSON+="\"cursor\"," ;;
    "Claude Code") PLATFORMS_JSON+="\"claude\"," ;;
    "Codex")       PLATFORMS_JSON+="\"codex\","  ;;
    "opencode")    PLATFORMS_JSON+="\"opencode\"," ;;
  esac
done <<< "$GEN_RAW"
PLATFORMS_JSON="${PLATFORMS_JSON%,}]"

PLATFORMS_DISPLAY=$(printf '%s, ' "${PLATFORMS_LIST[@]}")
PLATFORMS_DISPLAY=${PLATFORMS_DISPLAY%, }
TOOLS_DISPLAY=$(printf '%s, ' "${INSTALL_TOOLS[@]}")
TOOLS_DISPLAY=${TOOLS_DISPLAY%, }

# ── 4. Sync runtime ───────────────────────────────────────────────────────────
# bin/sync-agent-config ships in three interpreter ports (Ruby reference, Node,
# Python); Bun runs the Node source. They are behaviourally identical; pick the
# one whose runtime the project's machines already have. "auto" resolves to the
# first found here.
section "🧰 Which runtime should run bin/sync-agent-config?"
muted "all ports are equivalent — auto picks the first interpreter found on this machine"

RUNTIME_RAW=$("$GUM" choose \
  "auto — detect an available runtime (recommended)" \
  "ruby — reference implementation" \
  "node — Node.js port" \
  "bun — Node port on the Bun runtime" \
  "python — Python 3 port")

case "$RUNTIME_RAW" in
  ruby*)   RUNTIME_CHOICE="ruby"   ;;
  node*)   RUNTIME_CHOICE="node"   ;;
  bun*)    RUNTIME_CHOICE="bun"    ;;
  python*) RUNTIME_CHOICE="python" ;;
  *)       RUNTIME_CHOICE="auto"   ;;
esac

RUNTIME="$(resolve_runtime "$RUNTIME_CHOICE")"
RUNTIME_BIN="$(runtime_interpreter "$RUNTIME")"

if ! command -v "$RUNTIME_BIN" >/dev/null 2>&1; then
  warn "'$RUNTIME_BIN' is not on PATH — install it before running bin/sync-agent-config."
fi

if [[ "$RUNTIME_CHOICE" == "auto" ]]; then
  RUNTIME_DISPLAY="auto → $RUNTIME"
else
  RUNTIME_DISPLAY="$RUNTIME"
fi

# ── 5. Review ─────────────────────────────────────────────────────────────────
section "🔎 Review"
kv "Scope" "${SCOPE%% —*}"
kv "Install" "$TOOLS_DISPLAY"
kv "Generate" "$PLATFORMS_DISPLAY"
kv "Runtime" "$RUNTIME_DISPLAY"
[[ "$SCOPE_KIND" == "project" ]] && kv "Project" "$PROJECT_PATH"
echo

if ! "$GUM" confirm "Confirm installation?"; then
  info "Installation cancelled."
  exit 0
fi

# ── 5. Install skill ──────────────────────────────────────────────────────────
# Only the real skill assets are shipped — never the whole folder (which could
# include dev/test dirs and, if the target is nested, copy itself recursively).
SKILL_ASSETS=(SKILL.md README.md install.sh templates examples)

section "🚀 Installing"

for tool in "${INSTALL_TOOLS[@]}"; do
  dest="$(dest_for_tool "$tool")"
  mkdir -p "$(dirname "$dest")"

  if [[ "$SCOPE_KIND" == "symlink" ]]; then
    [[ -e "$dest" || -L "$dest" ]] && rm -rf "$dest"
    ln -sf "$SKILL_DIR" "$dest"
  else
    rm -rf "$dest"
    mkdir -p "$dest"
    for asset in "${SKILL_ASSETS[@]}"; do
      [[ -e "$SKILL_DIR/$asset" ]] || continue
      cp -R "$SKILL_DIR/$asset" "$dest/"
    done
  fi

  success "$tool → $dest"
done

# ── 6. Save configuration ─────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
  "platforms": $PLATFORMS_JSON,
  "install_scope": "$SCOPE_KIND",
  "install_targets": "$TOOLS_DISPLAY",
  "runtime": "$RUNTIME",
  "runtime_choice": "$RUNTIME_CHOICE",
  "skill_source": "$SKILL_DIR"
}
EOF
success "Preferences saved"

# ── 7. Success summary ────────────────────────────────────────────────────────
# Emoji per tool, aligned "tool → path" rows. Each logical line is styled on its
# own so the box stays a clean list instead of a mixed table.
tool_emoji() {
  case "$1" in
    "Cursor")      echo "🌀" ;;
    "Claude Code") echo "🤖" ;;
    "opencode")    echo "🧩" ;;
    *)             echo "🔧" ;;
  esac
}

SUMMARY_ROWS=""
for tool in "${INSTALL_TOOLS[@]}"; do
  dest="$(dest_for_tool "$tool")"
  row="$(printf '   %s  %-12s %s' "$(tool_emoji "$tool")" "$tool" "$dest")"
  SUMMARY_ROWS+="$("$GUM" style --foreground 245 "$row")
"
done

"$GUM" style \
  --border rounded \
  --border-foreground 82 \
  --padding "1 3" \
  --margin "1 0" \
  "$("$GUM" style --foreground 82 --bold '🎉  agent-rules-skill installed')

$("$GUM" style --foreground 252 --bold '📦 Installed into')
${SUMMARY_ROWS}
$("$GUM" style --foreground 252 "$(printf '⚙️  %-14s %s' 'Generates for' "$PLATFORMS_DISPLAY")")
$("$GUM" style --foreground 252 "$(printf '🧰 %-14s %s' 'Sync runtime' "$RUNTIME_DISPLAY  (bin/$(runtime_template "$RUNTIME"))")")
$("$GUM" style --foreground 240 "$(printf '📄 %-14s %s' 'Config' "$CONFIG_FILE")")"

# ── 8. Next steps (optional) ──────────────────────────────────────────────────
CURRENT_DIR="$(pwd)"
if "$GUM" confirm "Show next steps to bootstrap a project?"; then
  section "👉 Next steps"
  info "1️⃣  Open the project in any supported agent (Cursor, Claude Code, opencode, Codex)."
  info "2️⃣  Invoke the skill:"
  "$GUM" style --foreground 117 --margin "0 0 0 5" "💬 \"Use the agent-rules-skill to configure agents in this project.\""
  info "3️⃣  The skill detects existing configs and creates:"
  "$GUM" style --foreground 244 --margin "0 0 0 5" "📝 AGENTS.md · .agents/ · bin/sync-agent-config"
  for p in "${PLATFORMS_LIST[@]}"; do
    case "$p" in
      "Cursor")      muted "   → .cursor/rules/ .cursor/agents/ .cursor/hooks.json" ;;
      "Claude Code") muted "   → .claude/rules/ .claude/agents/ .claude/settings.json · CLAUDE.md" ;;
      "Codex")       muted "   → .codex/agents/ .codex/hooks.json" ;;
      "opencode")    muted "   → .opencode/rules/ .opencode/agents/ opencode.json" ;;
    esac
  done
fi
