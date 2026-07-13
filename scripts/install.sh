#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/Codex Pet Quota.app"
SOURCE_PET="$ROOT/PetAssets/pixel-code-companion"
TARGET_DIR="$HOME/Applications"
DRY_RUN=0

usage() { echo "Usage: $0 [--target DIRECTORY] [--source-app APP] [--source-pet DIRECTORY] [--dry-run]"; }
while (($#)); do
  case "$1" in
    --target) [[ $# -ge 2 ]] || { usage; exit 2; }; TARGET_DIR="$2"; shift 2 ;;
    --source-app) [[ $# -ge 2 ]] || { usage; exit 2; }; SOURCE_APP="$2"; shift 2 ;;
    --source-pet) [[ $# -ge 2 ]] || { usage; exit 2; }; SOURCE_PET="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

PET_BASE="${CODEX_HOME:-$HOME/.codex}"
TARGET_APP="$TARGET_DIR/Codex Pet Quota.app"
TARGET_PET="$PET_BASE/pets/pixel-code-companion"
STAMP="$(date +%Y%m%d%H%M%S)-$$"
BACKUP_COUNTER=0

[[ "$SOURCE_APP" == /* && "$SOURCE_PET" == /* ]] || { echo "Source paths must be absolute." >&2; exit 1; }
[[ ! -L "$SOURCE_APP" && -d "$SOURCE_APP" ]] || { echo "Missing or unsafe release app; run scripts/build-release.sh first." >&2; exit 1; }
[[ ! -L "$SOURCE_PET" ]] || { echo "Refusing symlink pet source: $SOURCE_PET" >&2; exit 1; }
[[ -f "$SOURCE_PET/pet.json" && -f "$SOURCE_PET/spritesheet.png" ]] || { echo "Pet asset is incomplete." >&2; exit 1; }

source_app_identifier="$(plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$source_app_identifier" == "com.chenxinran.codexpetquota" ]] || { echo "Release app has an unexpected bundle identifier." >&2; exit 1; }
source_pet_identifier="$(plutil -extract id raw "$SOURCE_PET/pet.json" 2>/dev/null || true)"
[[ "$source_pet_identifier" == "pixel-code-companion-v2" ]] || { echo "Pet source has an unexpected id." >&2; exit 1; }

validate_safe_base() {
  local base="$1"
  [[ "$base" == /* ]] || { echo "Refusing unsafe installation base: $base" >&2; exit 1; }
  local slashless="${base//\//}"
  [[ -n "$slashless" ]] || { echo "Refusing unsafe installation base: $base" >&2; exit 1; }
  case "/$base/" in
    *"/./"*|*"/../"*) echo "Refusing unsafe installation base: $base" >&2; exit 1 ;;
  esac
  local standardized="$base"
  if [[ -d "$base" ]]; then standardized="$(cd "$base" && pwd -P)"; fi
  [[ -n "$standardized" && "$standardized" != "/" ]] || { echo "Refusing unsafe installation base: $base" >&2; exit 1; }
}
validate_safe_base "$TARGET_DIR"
validate_safe_base "$HOME"
validate_safe_base "$PET_BASE"

validate_replaceable_app() {
  [[ ! -L "$TARGET_APP" ]] || { echo "Refusing symlink app target: $TARGET_APP" >&2; exit 1; }
  [[ ! -e "$TARGET_APP" ]] && return
  local identifier
  identifier="$(plutil -extract CFBundleIdentifier raw "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$identifier" == "com.chenxinran.codexpetquota" ]] || {
    echo "Refusing to replace an unrelated app: $TARGET_APP" >&2; exit 1;
  }
}

validate_replaceable_pet() {
  [[ ! -L "$TARGET_PET" ]] || { echo "Refusing symlink pet target: $TARGET_PET" >&2; exit 1; }
  [[ ! -e "$TARGET_PET" ]] && return
  local identifier
  identifier="$(plutil -extract id raw "$TARGET_PET/pet.json" 2>/dev/null || true)"
  [[ "$identifier" == "pixel-code-companion-v2" ]] || {
    echo "Refusing to replace an unrelated pet: $TARGET_PET" >&2; exit 1;
  }
}

validate_replaceable_app
validate_replaceable_pet

run() { if ((DRY_RUN)); then printf 'Would run:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
backup_if_present() {
  local target="$1"
  [[ ! -e "$target" && ! -L "$target" ]] && return
  local backup
  while :; do
    BACKUP_COUNTER=$((BACKUP_COUNTER + 1))
    backup="$target.backup-$STAMP-$BACKUP_COUNTER"
    [[ ! -e "$backup" && ! -L "$backup" ]] && break
  done
  run mv "$target" "$backup"
}

run mkdir -p "$TARGET_DIR" "$(dirname "$TARGET_PET")"
backup_if_present "$TARGET_APP"
backup_if_present "$TARGET_PET"
run cp -R "$SOURCE_APP" "$TARGET_APP"
run cp -R "$SOURCE_PET" "$TARGET_PET"
if ((DRY_RUN)); then
  echo "Planned app installation: $TARGET_APP"
  echo "Planned pet installation: $TARGET_PET"
else
  echo "Installed app: $TARGET_APP"
  echo "Installed pet: $TARGET_PET"
fi
