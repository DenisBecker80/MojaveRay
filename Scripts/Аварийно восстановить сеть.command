#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_UID="$(/usr/bin/id -u)"
STATE_HELPER="/var/run/mojaveray-$USER_UID/helper-copy.sh"
BUILD_HELPER="$PROJECT_DIR/Build/MojaveRay.app/Contents/Resources/mojaveray-helper.sh"
INSTALLED_HELPER="/Applications/MojaveRay.app/Contents/Resources/mojaveray-helper.sh"
SOURCE_HELPER="$PROJECT_DIR/Resources/mojaveray-helper.sh"

# Prefer the serialized service operation; fallback keeps legacy recovery usable.
for CONTROL in /Applications/MojaveRay.app/Contents/Resources/bin/control \
    "$PROJECT_DIR/Build/MojaveRay.app/Contents/Resources/bin/control"; do
    if [ -x "$CONTROL" ] && "$CONTROL" client "$USER_UID" stop; then
        echo "Сеть восстановлена системным помощником."
        read -r -p "Нажмите Enter, чтобы закрыть окно…" _
        exit 0
    fi
done

if /usr/bin/sudo /usr/bin/test -x "$STATE_HELPER"; then
    HELPER="$STATE_HELPER"
elif [ -x "$INSTALLED_HELPER" ]; then
    HELPER="$INSTALLED_HELPER"
elif [ -x "$BUILD_HELPER" ]; then
    HELPER="$BUILD_HELPER"
else
    HELPER="$SOURCE_HELPER"
fi

echo "Восстанавливаю маршруты, DNS, IPv6 и системный прокси…"
/usr/bin/sudo "$HELPER" stop "$USER_UID"
echo "Готово. Обычные сетевые настройки восстановлены."
read -r -p "Нажмите Enter, чтобы закрыть окно…" _
