#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/Build"
APP_DIR="$BUILD_DIR/MojaveRay.app"
ZIP_PATH="$BUILD_DIR/MojaveRay-macOS-Mojave.zip"

pause_on_exit() {
    local status=$?
    echo
    if [ "$status" -eq 0 ]; then
        echo "Готово. Приложение находится в папке Build."
    else
        echo "Сборка завершилась с ошибкой. Текст выше подскажет причину."
    fi
    if [ -n "${STAGE_DIR:-}" ]; then
        /bin/rm -rf "$STAGE_DIR"
    fi
    if [ "${MOJAVERAY_NONINTERACTIVE:-0}" != "1" ] && [ -t 0 ]; then
        read -r -p "Нажмите Enter, чтобы закрыть окно…" _ || true
    fi
    exit "$status"
}
trap pause_on_exit EXIT

cd "$PROJECT_DIR"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "x86_64" ] || [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    echo "Эта сборка предназначена для Intel Mac."
    exit 1
fi
if ! SWIFTC_BIN="$(/usr/bin/xcrun --find swiftc)" || ! SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"; then
    echo "Не найден swiftc или SDK macOS. Установите Command Line Tools: xcode-select --install"
    exit 1
fi

MOJAVERAY_NONINTERACTIVE=1 /bin/bash "$SCRIPT_DIR/Получить компоненты.command"

echo "Проверяю системный помощник…"
/bin/bash -n "$PROJECT_DIR/Resources/mojaveray-helper.sh"
/usr/bin/plutil -lint "$PROJECT_DIR/Resources/Info.plist"

export MACOSX_DEPLOYMENT_TARGET=10.14
mkdir -p "$BUILD_DIR"
STAGE_DIR="$(/usr/bin/mktemp -d "$BUILD_DIR/.mojaveray-build.XXXXXX")"
STAGE_APP="$STAGE_DIR/MojaveRay.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources/bin"

echo "Собираю ядро MojaveRay…"
"$SWIFTC_BIN" -sdk "$SDK" -target x86_64-apple-macosx10.14 \
    -O -whole-module-optimization -parse-as-library -module-name MojaveRayCore \
    -emit-module -emit-module-path "$STAGE_DIR/MojaveRayCore.swiftmodule" \
    -emit-object Sources/MojaveRayCore/*.swift -o "$STAGE_DIR/MojaveRayCore.o"

echo "Собираю MojaveRay для Intel…"
"$SWIFTC_BIN" -sdk "$SDK" -target x86_64-apple-macosx10.14 \
    -O -I "$STAGE_DIR" Sources/MojaveRay/*.swift "$STAGE_DIR/MojaveRayCore.o" \
    -framework AppKit -framework Security -o "$STAGE_APP/Contents/MacOS/MojaveRay"

cp "$PROJECT_DIR/Resources/MojaveRayIcon.png" "$STAGE_APP/Contents/Resources/MojaveRayIcon.png"
cp "$PROJECT_DIR/Resources/MojaveRay.icns" "$STAGE_APP/Contents/Resources/MojaveRay.icns"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/mojaveray-helper.sh" "$STAGE_APP/Contents/Resources/mojaveray-helper.sh"
cp "$PROJECT_DIR/Vendor/bin/xray" "$STAGE_APP/Contents/Resources/bin/xray"
cp "$PROJECT_DIR/Vendor/bin/tun2socks" "$STAGE_APP/Contents/Resources/bin/tun2socks"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGE_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/bin/bash "$PROJECT_DIR/Scripts/BuildControl.sh" "$STAGE_APP/Contents/Resources"
chmod 755 \
    "$STAGE_APP/Contents/MacOS/MojaveRay" \
    "$STAGE_APP/Contents/Resources/mojaveray-helper.sh" \
    "$STAGE_APP/Contents/Resources/bin/xray" \
    "$STAGE_APP/Contents/Resources/bin/tun2socks"

/usr/bin/codesign --force --deep --sign - "$STAGE_APP"
/usr/bin/codesign --verify --deep --strict "$STAGE_APP"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE_APP" "$STAGE_DIR/MojaveRay.zip"

if [ -e "$APP_DIR" ]; then
    /bin/rm -rf "$APP_DIR"
fi
/bin/mv "$STAGE_APP" "$APP_DIR"
/bin/mv -f "$STAGE_DIR/MojaveRay.zip" "$ZIP_PATH"

echo
echo "Создано: $APP_DIR"
echo "Архив для переноса на Mojave: $ZIP_PATH"
/usr/bin/open -R "$APP_DIR"

trap - EXIT
pause_on_exit
