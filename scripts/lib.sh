#!/usr/bin/env bash
# Shared helpers. Sourced by run_digest.sh and doctor.sh.
#
# The central problem this file solves: launchd does NOT give a job your shell's
# PATH. It hands over a minimal one (typically /usr/bin:/bin:/usr/sbin:/sbin),
# so Homebrew, npm-global and ~/.local binaries are all invisible. The classic
# symptom is "works when I run it by hand, silent at 9am". Every executable this
# project needs is therefore resolved explicitly rather than trusted to PATH.

if [[ "$OSTYPE" == "darwin"* ]]; then
  SUPPORT_DIR="$HOME/Library/Application Support/whatsapp-bridge"
else
  SUPPORT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whatsapp-bridge"
fi
export SUPPORT_DIR

# Directories a GUI shell would have but launchd does not.
EXTRA_PATHS=(
  /opt/homebrew/bin          # Homebrew, Apple Silicon
  /usr/local/bin             # Homebrew, Intel
  "$HOME/.local/bin"         # uv, pipx
  "$HOME/.claude/local"      # Claude Code local install
  "$HOME/.npm-global/bin"    # npm prefix override
  /usr/local/lib/node_modules/.bin
  "$HOME/bin"
  /usr/bin
  /bin
)

# find_bin <name> [more candidate absolute paths...]
# Echoes an absolute path, or nothing if not found.
find_bin() {
  local name="$1"; shift
  local candidate

  for candidate in "$@"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done

  # PATH first: if the caller is an interactive shell, this is the right answer.
  candidate=$(command -v "$name" 2>/dev/null) || true
  [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }

  for dir in "${EXTRA_PATHS[@]}"; do
    [[ -x "$dir/$name" ]] && { printf '%s' "$dir/$name"; return 0; }
  done

  return 1
}

# Run a command with a wall-clock limit, capturing stdout to a file.
# macOS ships no GNU `timeout`, so this is done by hand.
# Usage: run_limited <seconds> <outfile> <cmd> [args...]
run_limited() {
  local secs="$1" outfile="$2"; shift 2
  "$@" > "$outfile" 2>/dev/null &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

# Pick the bridge binary matching this machine. Apple Silicon reports arm64;
# Intel reports x86_64. Under Rosetta an arm64 Mac can report x86_64, so prefer
# the native build when both are present and the hardware is really Apple Silicon.
bridge_binary() {
  local repo="$1"
  local arch
  arch=$(uname -m)

  if [[ "$arch" == "x86_64" ]] && sysctl -n sysctl.proc_translated >/dev/null 2>&1; then
    # We are a translated (Rosetta) process on Apple Silicon.
    [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]] && arch="arm64"
  fi

  case "$arch" in
    arm64|aarch64) printf '%s' "$repo/bin/whatsapp-bridge-arm64" ;;
    x86_64|amd64)  printf '%s' "$repo/bin/whatsapp-bridge-amd64" ;;
    *)             printf '%s' "$repo/bin/whatsapp-bridge-$arch" ;;
  esac
}
