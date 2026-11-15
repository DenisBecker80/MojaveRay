#!/bin/bash
# Invoked only by the explicit macOS administrator authorization dialog.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
umask 077

fail() { echo "$1" >&2; exit 1; }
[ "$(/usr/bin/id -u)" = 0 ] || fail "Требуются права администратора."
[ "$#" = 2 ] || fail "Неверные параметры установки."
action="$1"
owner_uid="$2"
case "$owner_uid" in ''|0*|*[!0-9]*) fail "Некорректный UID.";; esac
[ "$owner_uid" -gt 1 ] && [ "$owner_uid" -le 2147483647 ] || fail "Некорректный UID."
case "$action" in install|uninstall) ;; *) fail "Неизвестное действие.";; esac

base="/Library/PrivilegedHelperTools/com.denisbekker.MojaveRay.$owner_uid"
label="com.denisbekker.MojaveRay.helper.$owner_uid"
plist="/Library/LaunchDaemons/$label.plist"
socket="/var/run/mojaveray-control-$owner_uid.sock"
resource_dir="$(cd "$(dirname "$0")" && pwd -P)"

safe_existing() {
    local path="$1"
    [ ! -L "$path" ] || fail "Отказ: символическая ссылка $path"
    if [ -e "$path" ]; then
        [ "$(/usr/bin/stat -f %u "$path")" = 0 ] || fail "Отказ: неверный владелец $path"
        local mode
        mode="$(/usr/bin/stat -f %Lp "$path")"
        [ $((8#$mode & 022)) -eq 0 ] || fail "Отказ: небезопасные права $path"
    fi
}
for path in /Library /Library/PrivilegedHelperTools /Library/LaunchDaemons "$base" "$plist"; do
    safe_existing "$path"
done
for name in control network.sh tun2socks; do safe_existing "$base/$name"; done

unload_service() {
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        if [ -x "$base/control" ]; then "$base/control" client "$owner_uid" stop; fi
        /bin/launchctl bootout system "$plist"
    fi
}

if [ "$action" = uninstall ]; then
    unload_service
    if [ -f "$base/network.sh" ]; then
        /usr/bin/env -i PATH="$PATH" LC_ALL=C /bin/bash "$base/network.sh" stop "$owner_uid"
    fi
    /bin/rm -f "$plist" "$base/control" "$base/network.sh" "$base/tun2socks"
    if [ -S "$socket" ] && [ ! -L "$socket" ]; then /bin/rm -f "$socket"; fi
    if [ -d "$base" ]; then /bin/rmdir "$base"; fi
    echo "Помощник удалён. Сохранённый VPN-ключ не затронут."
    exit 0
fi

for source in "$resource_dir/bin/control" "$resource_dir/bin/tun2socks" "$resource_dir/mojaveray-helper.sh"; do
    [ -f "$source" ] && [ ! -L "$source" ] || fail "Нет компонента: $source"
done
/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
stage="$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.mojaveray-install.XXXXXX)"
changed=0
committed=0
had_previous=0
cleanup() {
    local rc=$?
    trap - EXIT
    if [ "$changed" = 1 ] && [ "$committed" = 0 ]; then
        /bin/launchctl bootout system "$plist" >/dev/null 2>&1 || true
        if [ "$had_previous" = 1 ]; then
            for name in control network.sh tun2socks; do
                /usr/bin/install -o root -g wheel -m 700 "$stage/old-$name" "$base/$name"
            done
            /usr/bin/install -o root -g wheel -m 644 "$stage/old.plist" "$plist"
            /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
        else
            /bin/rm -f "$plist" "$base/control" "$base/network.sh" "$base/tun2socks"
            /bin/rmdir "$base" >/dev/null 2>&1 || true
        fi
    fi
    /bin/rm -f "$stage/control" "$stage/network.sh" "$stage/tun2socks" "$stage/launchd.plist" \
        "$stage/old-control" "$stage/old-network.sh" "$stage/old-tun2socks" "$stage/old.plist"
    /bin/rmdir "$stage" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT
/usr/bin/install -o root -g wheel -m 700 "$resource_dir/bin/control" "$stage/control"
/usr/bin/install -o root -g wheel -m 700 "$resource_dir/bin/tun2socks" "$stage/tun2socks"
/usr/bin/install -o root -g wheel -m 700 "$resource_dir/mojaveray-helper.sh" "$stage/network.sh"
/bin/bash -n "$stage/network.sh"

pb=/usr/libexec/PlistBuddy
"$pb" -c "Add :Label string $label" "$stage/launchd.plist"
"$pb" -c 'Add :ProgramArguments array' "$stage/launchd.plist"
"$pb" -c "Add :ProgramArguments:0 string $base/control" "$stage/launchd.plist"
"$pb" -c 'Add :ProgramArguments:1 string serve' "$stage/launchd.plist"
"$pb" -c "Add :ProgramArguments:2 string $owner_uid" "$stage/launchd.plist"
"$pb" -c 'Add :RunAtLoad bool true' "$stage/launchd.plist"
"$pb" -c 'Add :KeepAlive bool true' "$stage/launchd.plist"
"$pb" -c 'Add :ThrottleInterval integer 5' "$stage/launchd.plist"
"$pb" -c 'Add :ExitTimeOut integer 130' "$stage/launchd.plist"
"$pb" -c 'Add :ProcessType string Background' "$stage/launchd.plist"
"$pb" -c 'Add :Umask integer 63' "$stage/launchd.plist"
/usr/bin/plutil -lint "$stage/launchd.plist"

if [ -d "$base" ]; then
    [ -f "$plist" ] || fail "Неполная предыдущая установка: сначала удалите помощник через меню приложения."
    for name in control network.sh tun2socks; do /bin/cp "$base/$name" "$stage/old-$name"; done
    /bin/cp "$plist" "$stage/old.plist"
    had_previous=1
fi
unload_service
# Also restore a session left by versions 1.0–1.2 before migration.
/bin/bash "$stage/network.sh" stop "$owner_uid"
changed=1
/bin/mkdir -p "$base"
/usr/sbin/chown root:wheel "$base"
/bin/chmod 700 "$base"
for name in control network.sh tun2socks; do
    /usr/bin/install -o root -g wheel -m 700 "$stage/$name" "$base/$name"
done
/usr/bin/install -o root -g wheel -m 644 "$stage/launchd.plist" "$plist"
/bin/launchctl bootstrap system "$plist"
for ((attempt=0; attempt<50; attempt++)); do
    if "$base/control" client "$owner_uid" status >/dev/null 2>&1; then
        committed=1
        echo "Системный помощник установлен. Повторный пароль для подключения не нужен."
        exit 0
    fi
    /bin/sleep 0.1
done
fail "Служба не ответила после установки. Изменения установки отменены."
