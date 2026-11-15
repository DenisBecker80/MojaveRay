#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/Vendor/bin"
TEMP_DIR=""

finish() {
    local status=$?
    if [ -n "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
    if [ "$status" -ne 0 ]; then
        echo "Не удалось подготовить компоненты. Проверьте сообщение выше." >&2
        if [ "${MOJAVERAY_NONINTERACTIVE:-0}" != 1 ] && [ -t 0 ]; then
            read -r -p "Нажмите Enter, чтобы закрыть окно… " _ || true
        fi
    fi
    exit "$status"
}
trap finish EXIT
sha256() { /usr/bin/openssl dgst -sha256 "$1" | /usr/bin/awk '{print $NF}'; }
valid_binary() {
    [ -f "$1" ] && [ "$(sha256 "$1")" = "$2" ] &&
    [[ "$(/usr/bin/file -b "$1")" == *Mach-O*x86_64* ]]
}

prepare() {
    local name="$1" version="$2" asset="$3" member="$4" url="$5" archive_sha="$6" binary_sha="$7"
    local dest="$VENDOR_DIR/$name"
    if valid_binary "$dest" "$binary_sha"; then
        chmod 755 "$dest"
        echo "PASS: $name $version — SHA-256 проверена."
        return
    fi
    local zip_path="$TEMP_DIR/$name.zip" candidate found=0
    for candidate in "$HOME/Downloads/${asset%.zip}-$version.zip" "$HOME/Downloads/$asset"; do
        if [ -f "$candidate" ]; then
            if [ "$(sha256 "$candidate")" = "$archive_sha" ]; then
                cp "$candidate" "$zip_path"
                found=1
                break
            fi
            echo "Пропускаю $candidate: это не проверенный архив $name $version."
        fi
    done
    if [ "$found" = 0 ]; then
        echo "Загружаю $name $version…"
        /usr/bin/curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 "$url" --output "$zip_path"
    fi
    if [ "$(sha256 "$zip_path")" != "$archive_sha" ]; then
        echo "Ошибка: SHA-256 скачанного архива $name $version не совпадает." >&2
        return 1
    fi
    /usr/bin/unzip -p "$zip_path" "$member" > "$TEMP_DIR/$name"
    if ! valid_binary "$TEMP_DIR/$name" "$binary_sha"; then
        echo "Ошибка: проверка исполняемого файла $name не пройдена." >&2
        return 1
    fi
    chmod 755 "$TEMP_DIR/$name"
    mv -f "$TEMP_DIR/$name" "$dest"
    echo "PASS: $name $version — SHA-256 проверена."
}
mkdir -p "$VENDOR_DIR"
TEMP_DIR="$(mktemp -d "$VENDOR_DIR/.components.XXXXXX")"
prepare xray v1.8.1 Xray-macos-64.zip xray \
    https://github.com/XTLS/Xray-core/releases/download/v1.8.1/Xray-macos-64.zip \
    03144e3e92c8740107830cd274eb8b4873bfd65447ea53a1063eac9565f09025 \
    4e5fd3ed0bf7afa135621953bec9338b43b9f8724f9cb5f0a3f0d951e18c221f
prepare tun2socks v2.5.0 tun2socks-darwin-amd64.zip tun2socks-darwin-amd64 \
    https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.0/tun2socks-darwin-amd64.zip \
    0704e26e14a875b68311801b1009c8e9291df4709ff24e1f1aa877ac57b035e7 \
    2ab3f29867fe3b495d5eb3d8d5964760e3bd21475f92f6db03b79ee0a94a037e
echo "Компоненты Mojave-совместимой версии подготовлены."
