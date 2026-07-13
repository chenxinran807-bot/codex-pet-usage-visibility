#!/bin/bash
set -euo pipefail

NAME="Codex Pet Quota"
BACKEND="${CODEX_PET_LOGIN_BACKEND:-}"

usage() { echo "Usage: $0 ensure|remove /absolute/path/to/Codex\\ Pet\\ Quota.app" >&2; }
[[ $# -eq 2 ]] || { usage; exit 2; }
ACTION="$1"
APP_PATH="$2"
[[ "$ACTION" == ensure || "$ACTION" == remove ]] || { usage; exit 2; }
[[ "$APP_PATH" == /* ]] || { echo "Login item path must be absolute." >&2; exit 1; }

canonical_path() {
  local path="$1" parent base
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  [[ -d "$parent" ]] || return 1
  printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$base"
}
EXPECTED="$(canonical_path "$APP_PATH")" || { echo "Login item parent does not exist." >&2; exit 1; }

backend() {
  local operation="$1"; shift
  if [[ -n "$BACKEND" ]]; then "$BACKEND" "$operation" "$@"; return; fi
  case "$operation" in
    list)
      /usr/bin/osascript <<'APPLESCRIPT'
set output to ""
tell application "System Events"
  repeat with itemRef in every login item
    set output to output & (name of itemRef) & tab & (path of itemRef) & linefeed
  end repeat
end tell
return output
APPLESCRIPT
      ;;
    add)
      /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  tell application "System Events" to make login item at end with properties {name:item 1 of argv, path:item 2 of argv, hidden:true}
end run
APPLESCRIPT
      ;;
    remove-exact)
      /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  set expectedName to item 1 of argv
  set expectedPath to item 2 of argv
  tell application "System Events"
    repeat with itemRef in (every login item whose name is expectedName)
      if (path of itemRef) is expectedPath then delete itemRef
    end repeat
  end tell
end run
APPLESCRIPT
      ;;
  esac
}

matching=0
stale_paths=()
items="$(backend list)"
while IFS=$'\t' read -r item_name item_path; do
  [[ "$item_name" == "$NAME" && -n "$item_path" ]] || continue
  canonical_item="$(canonical_path "$item_path" 2>/dev/null || printf '%s' "$item_path")"
  if [[ "$canonical_item" == "$EXPECTED" ]]; then
    matching=1
  elif [[ "$ACTION" == ensure && -f "$canonical_item/Contents/Info.plist" ]]; then
    identifier="$(plutil -extract CFBundleIdentifier raw "$canonical_item/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$identifier" == "com.chenxinran.codexpetquota" ]] && stale_paths+=("$item_path")
  fi
done <<< "$items"

case "$ACTION" in
  ensure)
    if ((${#stale_paths[@]})); then
      for stale_path in "${stale_paths[@]}"; do backend remove-exact "$NAME" "$stale_path"; done
    fi
    ((matching)) || backend add "$NAME" "$EXPECTED"
    ;;
  remove) ((matching)) && backend remove-exact "$NAME" "$EXPECTED" || true ;;
esac
