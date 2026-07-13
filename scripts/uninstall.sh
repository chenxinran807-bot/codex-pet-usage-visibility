#!/bin/bash
set -euo pipefail

TARGET_DIR="$HOME/Applications"
YES=0
DRY_RUN=0
usage() { echo "Usage: $0 [--target DIRECTORY] [--yes] [--dry-run]"; }
while (($#)); do
  case "$1" in
    --target) [[ $# -ge 2 ]] || { usage; exit 2; }; TARGET_DIR="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

TARGET_APP="$TARGET_DIR/Codex Pet Quota.app"
TARGET_PET="${CODEX_HOME:-$HOME/.codex}/pets/pixel-code-companion"

reject_unsafe_base() {
  local base="$1"
  [[ "$base" == /* ]] || { echo "Refusing unsafe installation base: $base" >&2; exit 1; }
  local slashless="${base//\//}"
  [[ -n "$slashless" ]] || { echo "Refusing unsafe installation base: $base" >&2; exit 1; }
  case "/$base/" in
    *"/./"*|*"/../"*) echo "Refusing unsafe installation base: $base" >&2; exit 1 ;;
  esac
  local standardized="$base"
  if [[ -d "$base" ]]; then standardized="$(cd "$base" && pwd -P)"; fi
  [[ -n "$standardized" && "$standardized" != "/" ]] || {
    echo "Refusing unsafe installation base: $base" >&2; exit 1;
  }
}
reject_unsafe_base "$TARGET_DIR"
reject_unsafe_base "$HOME"
reject_unsafe_base "${CODEX_HOME:-$HOME/.codex}"

validate_app() {
  [[ ! -L "$TARGET_APP" ]] || { echo "Refusing symlink app target: $TARGET_APP" >&2; exit 1; }
  [[ ! -e "$TARGET_APP" ]] && return
  [[ -d "$TARGET_APP" ]] || { echo "App target is not a directory: $TARGET_APP" >&2; exit 1; }
  local identifier
  identifier="$(plutil -extract CFBundleIdentifier raw "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$identifier" == "com.chenxinran.codexpetquota" ]] || {
    echo "Refusing app with unexpected bundle identifier: $TARGET_APP" >&2; exit 1;
  }
}

validate_pet() {
  [[ ! -L "$TARGET_PET" ]] || { echo "Refusing symlink pet target: $TARGET_PET" >&2; exit 1; }
  [[ ! -e "$TARGET_PET" ]] && return
  [[ -d "$TARGET_PET" ]] || { echo "Pet target is not a directory: $TARGET_PET" >&2; exit 1; }
  local identifier
  identifier="$(plutil -extract id raw "$TARGET_PET/pet.json" 2>/dev/null || true)"
  [[ "$identifier" == "pixel-code-companion-v2" ]] || {
    echo "Refusing pet with unexpected id: $TARGET_PET" >&2; exit 1;
  }
}

validate_app
validate_pet
if ((!YES)); then
  read -r -p "Remove '$TARGET_APP' and '$TARGET_PET' only? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || { echo "Cancelled."; exit 0; }
fi

if ((DRY_RUN)); then
  [[ -e "$TARGET_APP" ]] && echo "Would remove validated app: $TARGET_APP" || echo "App target absent; no removal planned: $TARGET_APP"
  [[ -e "$TARGET_PET" ]] && echo "Would remove validated pet: $TARGET_PET" || echo "Pet target absent; no removal planned: $TARGET_PET"
else
  rm -rf "$TARGET_APP" "$TARGET_PET"
  echo "Removed project app and pet targets. Backups, if any, were retained."
fi
