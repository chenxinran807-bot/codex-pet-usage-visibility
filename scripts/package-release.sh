#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || {
  echo "Usage: $0 [VERSION, for example 0.1.0]" >&2
  exit 2
}

APP="$ROOT/dist/Codex Pet Quota.app"
[[ -d "$APP" ]] || { echo "Missing app. Run scripts/build-release.sh first." >&2; exit 1; }

PRODUCT="Codex Pet Quota v$VERSION"
STAGING="$ROOT/dist/.release-staging"
PACKAGE="$STAGING/$PRODUCT"
ARCHIVE="$ROOT/dist/Codex-Pet-Quota-v$VERSION.zip"
trap 'rm -rf "$STAGING"' EXIT
rm -rf "$STAGING"
mkdir -p "$PACKAGE/Support"
cp -R "$APP" "$PACKAGE/Codex Pet Quota.app"
plutil -replace CFBundleShortVersionString -string "$VERSION" \
  "$PACKAGE/Codex Pet Quota.app/Contents/Info.plist"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$ROOT/scripts/login-item.sh" "$PACKAGE/Support/"

cat > "$PACKAGE/安装.command" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Codex Pet Quota.app"
PET="$APP/Contents/Resources/PetAssets/pixel-code-companion"
"$DIR/Support/install.sh" --source-app "$APP" --source-pet "$PET"
TARGET="$HOME/Applications/Codex Pet Quota.app"
if [[ "${CODEX_PET_QUOTA_SKIP_LOGIN_ITEM:-0}" != 1 ]]; then
  if ! "$DIR/Support/login-item.sh" ensure "$TARGET"; then
    echo "警告：登录项设置失败，应用仍会启动。请在“系统设置 → 通用 → 登录项”中手动添加 Codex Pet Quota。" >&2
  fi
fi
if [[ "${CODEX_PET_QUOTA_NO_LAUNCH:-0}" != 1 ]]; then "${CODEX_PET_QUOTA_OPEN_BIN:-/usr/bin/open}" "$TARGET"; fi
echo "安装完成。额度面板已启动。"
SCRIPT

cat > "$PACKAGE/卸载.command" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
read -r -p "卸载 Codex Pet Quota 应用和像素代码伙伴桌宠资源？[y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "已取消。"; exit 0; }
"$DIR/Support/uninstall.sh" --yes
if [[ "${CODEX_PET_QUOTA_SKIP_LOGIN_ITEM:-0}" != 1 ]]; then
  TARGET="$HOME/Applications/Codex Pet Quota.app"
  if ! "$DIR/Support/login-item.sh" remove "$TARGET"; then
    echo "警告：无法检查登录项；如仍存在，请在“系统设置 → 通用 → 登录项”中手动删除。" >&2
  fi
fi
echo "卸载完成；安装时留下的备份未删除。"
SCRIPT

cat > "$PACKAGE/使用说明.txt" <<'TEXT'
Codex Pet Quota 安装说明

要求：macOS 13 或更高版本；已安装并登录 Codex。

安装：双击“安装.command”。应用会安装到“个人文件夹/Applications”，桌宠资源会安装到 Codex pets 目录，并设置为登录时打开。

如果系统拒绝自动设置登录项，安装仍会完成并启动应用。请打开“系统设置 → 通用 → 登录项”手动添加 Codex Pet Quota。

首次打开若被 macOS 阻止：打开“系统设置 → 隐私与安全性”，找到提示并点击“仍要打开”，然后再次打开应用。

使用：在 Codex 中选择“像素代码伙伴”。可拖动额度面板调整相对位置；双击面板恢复默认位置。

卸载：双击“卸载.command”并确认。它只删除经过身份校验的本应用和桌宠资源，不删除安装时创建的备份。

项目主页：https://github.com/chenxinran807-bot/codex-pet-usage-visibility
TEXT

chmod 755 "$PACKAGE/安装.command" "$PACKAGE/卸载.command" \
  "$PACKAGE/Support/install.sh" "$PACKAGE/Support/uninstall.sh" "$PACKAGE/Support/login-item.sh"

# Normalize metadata so identical inputs create an identical archive.
find "$PACKAGE" -exec touch -h -t 202001010000 {} +
rm -f "$ARCHIVE"
(
  cd "$STAGING"
  COPYFILE_DISABLE=1 /usr/bin/zip -X -q -r "$ARCHIVE" "$PRODUCT"
)
echo "Packaged: $ARCHIVE"
