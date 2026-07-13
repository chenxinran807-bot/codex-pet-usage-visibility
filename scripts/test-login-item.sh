#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
BACKEND="$TMP/backend"
mkdir -p "$TMP/apps/Expected.app/Contents" "$TMP/apps/Stale.app/Contents" "$TMP/apps/Other.app/Contents"
cat > "$TMP/apps/Stale.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.chenxinran.codexpetquota</string></dict></plist>
PLIST
cat > "$TMP/apps/Other.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.unrelated</string></dict></plist>
PLIST

cat > "$BACKEND" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
case "$1" in
  list) [[ ! -f "$LOGIN_ITEM_TEST_STATE" ]] || cat "$LOGIN_ITEM_TEST_STATE" ;;
  add) printf '%s\t%s\n' "$2" "$3" >> "$LOGIN_ITEM_TEST_STATE" ;;
  remove-exact)
    awk -F '\t' -v name="$2" -v path="$3" '!(NF >= 2 && $1 == name && $2 == path)' \
      "$LOGIN_ITEM_TEST_STATE" > "$LOGIN_ITEM_TEST_STATE.next"
    mv "$LOGIN_ITEM_TEST_STATE.next" "$LOGIN_ITEM_TEST_STATE"
    ;;
  *) exit 2 ;;
esac
SCRIPT
chmod +x "$BACKEND"
export LOGIN_ITEM_TEST_STATE="$STATE"
export CODEX_PET_LOGIN_BACKEND="$BACKEND"
HELPER="$ROOT/scripts/login-item.sh"
EXPECTED="$TMP/apps/Expected.app"
OTHER="$TMP/apps/Other.app"
STALE="$TMP/apps/Stale.app"

"$HELPER" ensure "$EXPECTED"
[[ "$(wc -l < "$STATE" | tr -d ' ')" -eq 1 ]] || exit 1
"$HELPER" ensure "$EXPECTED"
[[ "$(wc -l < "$STATE" | tr -d ' ')" -eq 1 ]] || { echo "ensure was not idempotent" >&2; exit 1; }

printf 'Codex Pet Quota\t%s\n' "$STALE" >> "$STATE"
printf 'Codex Pet Quota\t%s\n' "$OTHER" >> "$STATE"
"$HELPER" ensure "$EXPECTED"
if rg -F "$STALE" "$STATE" >/dev/null; then echo "stale project login item was retained" >&2; exit 1; fi
[[ "$(rg -F "$OTHER" "$STATE" | wc -l | tr -d ' ')" -eq 1 ]] || { echo "unrelated same-name item changed" >&2; exit 1; }
[[ "$(rg -F "$EXPECTED" "$STATE" | wc -l | tr -d ' ')" -eq 1 ]] || { echo "expected item duplicated" >&2; exit 1; }

"$HELPER" remove "$EXPECTED"
[[ "$(rg -F "$OTHER" "$STATE" | wc -l | tr -d ' ')" -eq 1 ]] || { echo "unrelated same-name item removed" >&2; exit 1; }
if rg -F "$EXPECTED" "$STATE" >/dev/null; then echo "expected item not removed" >&2; exit 1; fi

echo "Login item tests passed"
