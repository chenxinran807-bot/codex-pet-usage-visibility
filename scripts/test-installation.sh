#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export CODEX_HOME="$TMP/codex-home"
mkdir -p "$HOME/Applications" "$CODEX_HOME/pets"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "command unexpectedly succeeded: $*"; fi; }

"$ROOT/scripts/install.sh" >/dev/null
"$ROOT/scripts/install.sh" >/dev/null
"$ROOT/scripts/install.sh" >/dev/null

app_backup_count="$(find "$HOME/Applications" -maxdepth 1 -type d -name 'Codex Pet Quota.app.backup-*' | wc -l | tr -d ' ')"
pet_backup_count="$(find "$CODEX_HOME/pets" -maxdepth 1 -type d -name 'pixel-code-companion.backup-*' | wc -l | tr -d ' ')"
[[ "$app_backup_count" -eq 2 ]] || fail "expected two distinct app backups"
[[ "$pet_backup_count" -eq 2 ]] || fail "expected two distinct pet backups"
find "$HOME/Applications" -maxdepth 1 -type d -name 'Codex Pet Quota.app.backup-*' -exec test -f '{}/Contents/Info.plist' \; || fail "app backup nesting detected"
find "$CODEX_HOME/pets" -maxdepth 1 -type d -name 'pixel-code-companion.backup-*' -exec test -f '{}/pet.json' \; || fail "pet backup nesting detected"

"$ROOT/scripts/uninstall.sh" --yes >/dev/null
[[ ! -e "$HOME/Applications/Codex Pet Quota.app" ]] || fail "app was not removed"
[[ ! -e "$CODEX_HOME/pets/pixel-code-companion" ]] || fail "pet was not removed"
[[ "$(find "$HOME/Applications" -maxdepth 1 -type d -name 'Codex Pet Quota.app.backup-*' | wc -l | tr -d ' ')" -eq 2 ]] || fail "app backup was removed"
[[ "$(find "$CODEX_HOME/pets" -maxdepth 1 -type d -name 'pixel-code-companion.backup-*' | wc -l | tr -d ' ')" -eq 2 ]] || fail "pet backup was removed"

expect_fail "$ROOT/scripts/install.sh" --target / --dry-run
expect_fail "$ROOT/scripts/install.sh" --target // --dry-run
expect_fail "$ROOT/scripts/install.sh" --target /./ --dry-run
expect_fail "$ROOT/scripts/install.sh" --target /tmp/../ --dry-run
expect_fail "$ROOT/scripts/install.sh" --target /quota-overlay-does-not-exist/.. --dry-run
expect_fail env HOME=/ "$ROOT/scripts/install.sh" --dry-run
expect_fail env CODEX_HOME=/ "$ROOT/scripts/install.sh" --dry-run
expect_fail env CODEX_HOME=// "$ROOT/scripts/install.sh" --dry-run
expect_fail env CODEX_HOME=/tmp/../ "$ROOT/scripts/install.sh" --dry-run
expect_fail env CODEX_HOME=relative/codex-home "$ROOT/scripts/install.sh" --dry-run

expect_fail "$ROOT/scripts/uninstall.sh" --target / --yes --dry-run
expect_fail "$ROOT/scripts/uninstall.sh" --target // --yes --dry-run
expect_fail "$ROOT/scripts/uninstall.sh" --target /./ --yes --dry-run
expect_fail "$ROOT/scripts/uninstall.sh" --target /tmp/../ --yes --dry-run
expect_fail "$ROOT/scripts/uninstall.sh" --target /quota-overlay-does-not-exist/.. --yes --dry-run
expect_fail "$ROOT/scripts/uninstall.sh" --target relative/applications --yes --dry-run
expect_fail env HOME=/ "$ROOT/scripts/uninstall.sh" --yes --dry-run
expect_fail env CODEX_HOME=/ "$ROOT/scripts/uninstall.sh" --yes --dry-run

mkdir -p "$HOME/Applications/Codex Pet Quota.app/Contents"
cp "$ROOT/dist/Codex Pet Quota.app/Contents/Info.plist" "$HOME/Applications/Codex Pet Quota.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.example.unrelated "$HOME/Applications/Codex Pet Quota.app/Contents/Info.plist"
mkdir -p "$CODEX_HOME/pets/pixel-code-companion"
printf '{"id":"unrelated"}\n' > "$CODEX_HOME/pets/pixel-code-companion/pet.json"
expect_fail "$ROOT/scripts/uninstall.sh" --yes
[[ -d "$HOME/Applications/Codex Pet Quota.app" && -d "$CODEX_HOME/pets/pixel-code-companion" ]] || fail "unrelated target was removed"
expect_fail "$ROOT/scripts/install.sh"

rm -rf "$HOME/Applications/Codex Pet Quota.app" "$CODEX_HOME/pets/pixel-code-companion"
ln -s "$TMP" "$HOME/Applications/Codex Pet Quota.app"
ln -s "$TMP" "$CODEX_HOME/pets/pixel-code-companion"
expect_fail "$ROOT/scripts/uninstall.sh" --yes
[[ -L "$HOME/Applications/Codex Pet Quota.app" && -L "$CODEX_HOME/pets/pixel-code-companion" ]] || fail "symlink target was removed"

echo "Installation safety tests passed"
