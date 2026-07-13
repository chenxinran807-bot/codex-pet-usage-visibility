#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

VERSION="0.1.0"
ARCHIVE="$ROOT/dist/Codex-Pet-Quota-v$VERSION.zip"

"$ROOT/scripts/package-release.sh" "$VERSION" >/dev/null
[[ -f "$ARCHIVE" ]] || fail "release archive was not created"
first_hash="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
"$ROOT/scripts/package-release.sh" "$VERSION" >/dev/null
second_hash="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$first_hash" == "$second_hash" ]] || fail "release archive is not deterministic"

unzip -q "$ARCHIVE" -d "$TMP/extracted"
PACKAGE="$TMP/extracted/Codex Pet Quota v$VERSION"
[[ -d "$PACKAGE/Codex Pet Quota.app" ]] || fail "top-level app is missing"
bundle_version="$(plutil -extract CFBundleShortVersionString raw "$PACKAGE/Codex Pet Quota.app/Contents/Info.plist")"
[[ "$bundle_version" == "$VERSION" ]] || fail "bundle version $bundle_version does not match package version $VERSION"
[[ -x "$PACKAGE/安装.command" ]] || fail "installer is not executable"
[[ -x "$PACKAGE/卸载.command" ]] || fail "uninstaller is not executable"
[[ -f "$PACKAGE/使用说明.txt" ]] || fail "Chinese readme is missing"
[[ -x "$PACKAGE/Support/install.sh" ]] || fail "support installer is missing or not executable"
[[ -x "$PACKAGE/Support/uninstall.sh" ]] || fail "support uninstaller is missing or not executable"
[[ -x "$PACKAGE/Support/login-item.sh" ]] || fail "login-item helper is missing or not executable"
bash -n "$PACKAGE/安装.command" "$PACKAGE/卸载.command" \
  "$PACKAGE/Support/install.sh" "$PACKAGE/Support/uninstall.sh" "$PACKAGE/Support/login-item.sh"

export HOME="$TMP/home"
export CODEX_HOME="$TMP/codex-home"
export CODEX_PET_QUOTA_NO_LAUNCH=1
export CODEX_PET_QUOTA_SKIP_LOGIN_ITEM=1
mkdir -p "$HOME" "$CODEX_HOME"
"$PACKAGE/安装.command" >/dev/null
[[ -d "$HOME/Applications/Codex Pet Quota.app" ]] || fail "package wrapper did not install app"
[[ -f "$CODEX_HOME/pets/pixel-code-companion/pet.json" ]] || fail "package wrapper did not install pet"
printf 'y\n' | "$PACKAGE/卸载.command" >/dev/null
[[ ! -e "$HOME/Applications/Codex Pet Quota.app" ]] || fail "package wrapper did not uninstall app"
[[ ! -e "$CODEX_HOME/pets/pixel-code-companion" ]] || fail "package wrapper did not uninstall pet"

cat > "$TMP/failing-login-backend" <<'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
cat > "$TMP/fake-open" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" > "$PACKAGE_TEST_OPEN_MARKER"
SCRIPT
chmod +x "$TMP/failing-login-backend" "$TMP/fake-open"
export CODEX_PET_QUOTA_SKIP_LOGIN_ITEM=0
export CODEX_PET_QUOTA_NO_LAUNCH=0
export CODEX_PET_LOGIN_BACKEND="$TMP/failing-login-backend"
export CODEX_PET_QUOTA_OPEN_BIN="$TMP/fake-open"
export PACKAGE_TEST_OPEN_MARKER="$TMP/opened"
failure_output="$("$PACKAGE/安装.command" 2>&1)"
[[ -f "$PACKAGE_TEST_OPEN_MARKER" ]] || fail "login-item failure prevented app launch"
[[ "$failure_output" == *"登录项设置失败"* && "$failure_output" == *"系统设置"* ]] || fail "login-item failure did not explain manual recovery"

echo "Release package tests passed"
