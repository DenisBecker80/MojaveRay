#!/bin/bash

set -u

NETWORKSETUP=/usr/sbin/networksetup
ROUTE=/sbin/route
IFCONFIG=/sbin/ifconfig
ID=/usr/bin/id
AWK=/usr/bin/awk
GREP=/usr/bin/grep
SED=/usr/bin/sed
CP=/bin/cp
CHMOD=/bin/chmod
MKDIR=/bin/mkdir
RM=/bin/rm
RMDIR=/bin/rmdir
KILL=/bin/kill
SLEEP=/bin/sleep
TAIL=/usr/bin/tail

fail() {
    echo "$1" >&2
    exit 1
}

is_digits() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_ipv4() {
    local ip="$1"
    local octets=()
    local octet
    case "$ip" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    IFS=. read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        is_digits "$octet" || return 1
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

require_root() {
    [ "$($ID -u)" = "0" ] || fail "Системный помощник должен выполняться с правами администратора."
}

state_dir_for_uid() {
    local uid="$1"
    is_digits "$uid" || fail "Некорректный UID."
    [ "$uid" -gt 0 ] || fail "UID root использовать нельзя."
    echo "/var/run/mojaveray-$uid"
}

default_interface() {
    $ROUTE -n get default 2>/dev/null | $AWK '/interface:/{print $2; exit}'
}

default_gateway() {
    $ROUTE -n get default 2>/dev/null | $AWK '/gateway:/{print $2; exit}'
}

service_for_device() {
    local device="$1"
    $NETWORKSETUP -listnetworkserviceorder | $AWK -v device="$device" '
        /^\([0-9]+\)/ {
            service=$0
            sub(/^\([0-9]+\) /, "", service)
            next
        }
        index($0, "Device: " device ")") > 0 {
            print service
            exit
        }
    '
}

snapshot_common() {
    local state_dir="$1"
    local service="$2"
    echo "$service" > "$state_dir/service"
    $NETWORKSETUP -getdnsservers "$service" > "$state_dir/dns.txt" 2>&1 || return 1
    $NETWORKSETUP -getinfo "$service" > "$state_dir/ipv6.txt" 2>&1 || return 1

    local ipv6_mode
    ipv6_mode="$($AWK -F': ' '/^IPv6:/{print $2; exit}' "$state_dir/ipv6.txt")"
    case "$ipv6_mode" in
        Automatic|Off|"Link-local only") ;;
        Manual)
            local address prefix router
            address="$($AWK -F': ' '/^IPv6 IP address:/{print $2; exit}' "$state_dir/ipv6.txt")"
            prefix="$($AWK -F': ' '/^IPv6 Prefix Length:/{print $2; exit}' "$state_dir/ipv6.txt")"
            router="$($AWK -F': ' '/^IPv6 Router:/{print $2; exit}' "$state_dir/ipv6.txt")"
            [ -n "$address" ] && [ -n "$prefix" ] && [ -n "$router" ] || return 1
            ;;
        *) return 1 ;;
    esac
    return 0
}

restore_dns() {
    local state_dir="$1"
    [ -f "$state_dir/service" ] && [ -f "$state_dir/dns.txt" ] || return 0
    local service
    service="$(/bin/cat "$state_dir/service")"
    if $GREP -q "^There aren't any DNS Servers" "$state_dir/dns.txt"; then
        $NETWORKSETUP -setdnsservers "$service" empty >/dev/null 2>&1 || true
        return 0
    fi

    local dns_values=()
    while IFS= read -r line; do
        case "$line" in
            ''|*' '*) ;;
            *) dns_values+=("$line") ;;
        esac
    done < "$state_dir/dns.txt"
    if [ "${#dns_values[@]}" -gt 0 ]; then
        $NETWORKSETUP -setdnsservers "$service" "${dns_values[@]}" >/dev/null 2>&1 || true
    else
        $NETWORKSETUP -setdnsservers "$service" empty >/dev/null 2>&1 || true
    fi
}

restore_ipv6() {
    local state_dir="$1"
    [ -f "$state_dir/service" ] && [ -f "$state_dir/ipv6.txt" ] || return 0
    local service mode
    service="$(/bin/cat "$state_dir/service")"
    mode="$($AWK -F': ' '/^IPv6:/{print $2; exit}' "$state_dir/ipv6.txt")"
    case "$mode" in
        Automatic)
            $NETWORKSETUP -setv6automatic "$service" >/dev/null 2>&1 || true
            ;;
        Off)
            $NETWORKSETUP -setv6off "$service" >/dev/null 2>&1 || true
            ;;
        "Link-local only")
            $NETWORKSETUP -setv6linklocal "$service" >/dev/null 2>&1 || true
            ;;
        Manual)
            local address prefix router
            address="$($AWK -F': ' '/^IPv6 IP address:/{print $2; exit}' "$state_dir/ipv6.txt")"
            prefix="$($AWK -F': ' '/^IPv6 Prefix Length:/{print $2; exit}' "$state_dir/ipv6.txt")"
            router="$($AWK -F': ' '/^IPv6 Router:/{print $2; exit}' "$state_dir/ipv6.txt")"
            if [ -n "$address" ] && [ -n "$prefix" ] && [ -n "$router" ]; then
                $NETWORKSETUP -setv6manual "$service" "$address" "$prefix" "$router" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

restore_socks_proxy() {
    local state_dir="$1"
    [ -f "$state_dir/service" ] && [ -f "$state_dir/socks.txt" ] || return 0
    local service enabled server port
    service="$(/bin/cat "$state_dir/service")"
    enabled="$($AWK -F': ' '/^Enabled:/{print $2; exit}' "$state_dir/socks.txt")"
    server="$($AWK -F': ' '/^Server:/{print $2; exit}' "$state_dir/socks.txt")"
    port="$($AWK -F': ' '/^Port:/{print $2; exit}' "$state_dir/socks.txt")"

    if [ -n "$server" ] && is_digits "$port"; then
        $NETWORKSETUP -setsocksfirewallproxy "$service" "$server" "$port" off >/dev/null 2>&1 || true
    fi
    if [ "$enabled" = "Yes" ]; then
        $NETWORKSETUP -setsocksfirewallproxystate "$service" on >/dev/null 2>&1 || true
    else
        $NETWORKSETUP -setsocksfirewallproxystate "$service" off >/dev/null 2>&1 || true
    fi
}

remove_routes() {
    local state_dir="$1"
    if [ -f "$state_dir/half-routes-added" ]; then
        $ROUTE -n delete -net 0.0.0.0/1 198.18.0.1 >/dev/null 2>&1 || true
        $ROUTE -n delete -net 128.0.0.0/1 198.18.0.1 >/dev/null 2>&1 || true
    fi
    if [ -f "$state_dir/server-route-added" ] && [ -f "$state_dir/server-ip" ] && [ -f "$state_dir/gateway" ]; then
        local server gateway
        server="$(/bin/cat "$state_dir/server-ip")"
        gateway="$(/bin/cat "$state_dir/gateway")"
        $ROUTE -n delete -host "$server" "$gateway" >/dev/null 2>&1 || true
    fi
}

remove_state_files() {
    local state_dir="$1"
    $RM -f \
        "$state_dir/mode" \
        "$state_dir/service" \
        "$state_dir/dns.txt" \
        "$state_dir/ipv6.txt" \
        "$state_dir/socks.txt" \
        "$state_dir/server-ip" \
        "$state_dir/gateway" \
        "$state_dir/tun-name" \
        "$state_dir/half-routes-added" \
        "$state_dir/server-route-added" \
        "$state_dir/tun.pid" \
        "$state_dir/tun-command" \
        "$state_dir/tun-start" \
        "$state_dir/tun.log" \
        "$state_dir/watchdog.pid" \
        "$state_dir/helper-copy.sh" \
        "$state_dir/ready"
    $RMDIR "$state_dir" >/dev/null 2>&1 || true
}

stop_network() {
    local uid="$1"
    local state_dir
    state_dir="$(state_dir_for_uid "$uid")"
    [ -d "$state_dir" ] || return 0

    if [ -f "$state_dir/watchdog.pid" ]; then
        local watchdog_pid
        watchdog_pid="$(/bin/cat "$state_dir/watchdog.pid" 2>/dev/null || true)"
        local watchdog_command
        watchdog_command="$(/bin/ps -ww -p "$watchdog_pid" -o command= 2>/dev/null || true)"
        if is_digits "$watchdog_pid" && [ "$watchdog_pid" -gt 1 ] && [ "$watchdog_pid" != "$$" ] &&
            [[ "$watchdog_command" == *"$state_dir/helper-copy.sh watchdog $uid "* ]]; then
            $KILL "$watchdog_pid" >/dev/null 2>&1 || true
        fi
    fi

    local mode=""
    [ -f "$state_dir/mode" ] && mode="$(/bin/cat "$state_dir/mode")"
    if [ "$mode" = "tun" ]; then
        remove_routes "$state_dir"
    elif [ "$mode" = "proxy" ]; then
        restore_socks_proxy "$state_dir"
    fi
    if [ -f "$state_dir/tun.pid" ]; then
        local tun_pid
        tun_pid="$(/bin/cat "$state_dir/tun.pid" 2>/dev/null || true)"
        local expected_command current_command expected_start current_start
        expected_command="$(/bin/cat "$state_dir/tun-command" 2>/dev/null || true)"
        current_command="$(/bin/ps -ww -p "$tun_pid" -o command= 2>/dev/null || true)"
        expected_start="$(/bin/cat "$state_dir/tun-start" 2>/dev/null || true)"
        current_start="$(/bin/ps -ww -p "$tun_pid" -o lstart= 2>/dev/null || true)"
        # Legacy 1.2 has no identity files; only terminate its specific binary.
        if [ -z "$expected_command" ] && [[ "$current_command" == *"/MojaveRay.app/Contents/Resources/bin/tun2socks -device utun"* ]]; then
            expected_command="$current_command"
            expected_start="$current_start"
        fi
        if [ -z "$expected_command" ] && [[ "$current_command" == "/Library/PrivilegedHelperTools/com.denisbekker.MojaveRay.$uid/tun2socks -device utun"* ]]; then
            expected_command="$current_command"
            expected_start="$current_start"
        fi
        if is_digits "$tun_pid" && [ "$tun_pid" -gt 1 ] && [ "$tun_pid" != "$$" ] &&
            [ -n "$expected_command" ] && [ "$current_command" = "$expected_command" ] &&
            [ -n "$expected_start" ] && [ "$current_start" = "$expected_start" ]; then
            $KILL "$tun_pid" >/dev/null 2>&1 || true
            $SLEEP 1
            if [ "$(/bin/ps -ww -p "$tun_pid" -o command= 2>/dev/null || true)" = "$expected_command" ] &&
                [ "$(/bin/ps -ww -p "$tun_pid" -o lstart= 2>/dev/null || true)" = "$expected_start" ]; then
                $KILL -9 "$tun_pid" >/dev/null 2>&1 || true
            fi
        fi
    fi
    restore_dns "$state_dir"
    restore_ipv6 "$state_dir"
    remove_state_files "$state_dir"
}

start_watchdog() {
    # The persistent service owns lifecycle monitoring and serializes cleanup.
    [ "${MOJAVERAY_SERVICE:-0}" = 1 ] && return 0
    local state_dir="$1"
    local uid="$2"
    local app_pid="$3"
    $CP "$0" "$state_dir/helper-copy.sh" || return 1
    $CHMOD 700 "$state_dir/helper-copy.sh" || return 1
    (
        trap '' HUP
        exec "$state_dir/helper-copy.sh" watchdog "$uid" "$app_pid"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$state_dir/watchdog.pid"
}

start_full() {
    local uid="$1"
    local app_pid="$2"
    local server_ip="$3"
    local tun_name="$4"
    local requested_interface="$5"
    local socks_port="$6"
    local tun_binary="$7"

    is_digits "$app_pid" || fail "Некорректный PID приложения."
    is_ipv4 "$server_ip" || fail "Для TUN требуется IPv4-адрес сервера."
    local tun_index="${tun_name#utun}"
    [ "$tun_index" != "$tun_name" ] && is_digits "$tun_index" ||
        fail "Некорректное имя TUN-интерфейса."
    case "$requested_interface" in
        ''|*[!a-zA-Z0-9]*) fail "Некорректный сетевой интерфейс." ;;
    esac
    is_digits "$socks_port" || fail "Некорректный порт SOCKS."
    [ "$socks_port" = "10808" ] || fail "Разрешён только локальный порт 10808."
    case "$tun_binary" in
        */MojaveRay.app/Contents/Resources/bin/tun2socks) ;;
        "/Library/PrivilegedHelperTools/com.denisbekker.MojaveRay.$uid/tun2socks") ;;
        *) fail "Некорректный путь к tun2socks." ;;
    esac
    [ -f "$tun_binary" ] && [ -x "$tun_binary" ] || fail "Компонент tun2socks не найден."

    local state_dir interface gateway service
    state_dir="$(state_dir_for_uid "$uid")"
    stop_network "$uid"
    $MKDIR -p "$state_dir" || fail "Не удалось создать каталог состояния."
    $CHMOD 700 "$state_dir"

    echo "tun" > "$state_dir/mode"
    (
        trap '' HUP
        exec "$tun_binary" \
            -device "$tun_name" \
            -proxy "socks5://127.0.0.1:$socks_port" \
            -interface "$requested_interface" \
            -loglevel warning
    ) </dev/null >"$state_dir/tun.log" 2>&1 &
    echo "$!" > "$state_dir/tun.pid"

    local attempt=0
    while [ "$attempt" -lt 50 ]; do
        if $IFCONFIG "$tun_name" >/dev/null 2>&1; then
            break
        fi
        if ! $KILL -0 "$(/bin/cat "$state_dir/tun.pid")" >/dev/null 2>&1; then
            local tun_error
            tun_error="$($TAIL -n 3 "$state_dir/tun.log" 2>/dev/null | /usr/bin/tr '\n' ' ')"
            stop_network "$uid"
            fail "tun2socks завершился до создания $tun_name. $tun_error"
        fi
        $SLEEP 0.1
        attempt=$((attempt + 1))
    done
    if ! $IFCONFIG "$tun_name" >/dev/null 2>&1; then
        local tun_error
        tun_error="$($TAIL -n 3 "$state_dir/tun.log" 2>/dev/null | /usr/bin/tr '\n' ' ')"
        stop_network "$uid"
        fail "Интерфейс $tun_name не появился за 5 секунд. $tun_error"
    fi

    /bin/ps -ww -p "$(/bin/cat "$state_dir/tun.pid")" -o command= > "$state_dir/tun-command"
    /bin/ps -ww -p "$(/bin/cat "$state_dir/tun.pid")" -o lstart= > "$state_dir/tun-start"

    interface="$(default_interface)"
    gateway="$(default_gateway)"
    [ -n "$interface" ] && [ -n "$gateway" ] || {
        stop_network "$uid"
        fail "Не удалось определить основной маршрут."
    }
    [ "$interface" = "$requested_interface" ] || {
        stop_network "$uid"
        fail "Активный сетевой интерфейс изменился во время подключения. Повторите попытку."
    }
    service="$(service_for_device "$interface")"
    [ -n "$service" ] || {
        stop_network "$uid"
        fail "Не удалось определить активную сетевую службу."
    }

    echo "$server_ip" > "$state_dir/server-ip"
    echo "$gateway" > "$state_dir/gateway"
    echo "$tun_name" > "$state_dir/tun-name"
    snapshot_common "$state_dir" "$service" || {
        stop_network "$uid"
        fail "Не удалось сохранить текущие DNS/IPv6-настройки."
    }

    $IFCONFIG "$tun_name" 198.18.0.1 198.18.0.1 up >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось активировать $tun_name."
    }

    if $ROUTE -n add -host "$server_ip" "$gateway" >/dev/null 2>&1; then
        /usr/bin/touch "$state_dir/server-route-added"
    else
        local existing_gateway
        existing_gateway="$($ROUTE -n get "$server_ip" 2>/dev/null | $AWK '/gateway:/{print $2; exit}')"
        [ "$existing_gateway" = "$gateway" ] || {
            stop_network "$uid"
            fail "Не удалось закрепить маршрут к VPN-серверу."
        }
    fi

    $ROUTE -n add -net 0.0.0.0/1 198.18.0.1 >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось добавить первый маршрут VPN."
    }
    /usr/bin/touch "$state_dir/half-routes-added"
    $ROUTE -n add -net 128.0.0.0/1 198.18.0.1 >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось добавить второй маршрут VPN."
    }

    $NETWORKSETUP -setdnsservers "$service" 1.1.1.1 8.8.8.8 >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось включить защищённый DNS-маршрут."
    }
    $NETWORKSETUP -setv6off "$service" >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось временно отключить IPv6 для защиты от утечки."
    }

    /usr/bin/touch "$state_dir/ready"
    start_watchdog "$state_dir" "$uid" "$app_pid" || {
        stop_network "$uid"
        fail "Не удалось запустить защитное восстановление сети."
    }
    echo "OK: полный VPN включён для $service"
}

start_proxy() {
    local uid="$1"
    local app_pid="$2"
    is_digits "$app_pid" || fail "Некорректный PID приложения."

    local state_dir interface service auth
    state_dir="$(state_dir_for_uid "$uid")"
    stop_network "$uid"
    $MKDIR -p "$state_dir" || fail "Не удалось создать каталог состояния."
    $CHMOD 700 "$state_dir"

    interface="$(default_interface)"
    service="$(service_for_device "$interface")"
    [ -n "$service" ] || {
        remove_state_files "$state_dir"
        fail "Не удалось определить активную сетевую службу."
    }

    echo "proxy" > "$state_dir/mode"
    snapshot_common "$state_dir" "$service" || {
        stop_network "$uid"
        fail "Не удалось сохранить текущие сетевые настройки."
    }
    $NETWORKSETUP -getsocksfirewallproxy "$service" > "$state_dir/socks.txt" 2>&1 || {
        stop_network "$uid"
        fail "Не удалось сохранить настройки SOCKS-прокси."
    }
    auth="$($AWK -F': ' '/^Authenticated Proxy Enabled:/{print $2; exit}' "$state_dir/socks.txt")"
    [ "$auth" != "1" ] || {
        # Ничего ещё не менялось. Не пытайтесь восстанавливать пароль через
        # networksetup: команда не возвращает сохранённый секрет.
        $RM -f "$state_dir/socks.txt"
        stop_network "$uid"
        fail "В системе уже настроен SOCKS-прокси с паролем; используйте режим полного VPN."
    }

    $NETWORKSETUP -setsocksfirewallproxy "$service" 127.0.0.1 10808 off >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось настроить SOCKS-прокси."
    }
    $NETWORKSETUP -setsocksfirewallproxystate "$service" on >/dev/null 2>&1 || {
        stop_network "$uid"
        fail "Не удалось включить SOCKS-прокси."
    }

    /usr/bin/touch "$state_dir/ready"
    start_watchdog "$state_dir" "$uid" "$app_pid" || {
        stop_network "$uid"
        fail "Не удалось запустить защитное восстановление сети."
    }
    echo "OK: системный прокси включён для $service"
}

watchdog() {
    local uid="$1"
    local app_pid="$2"
    is_digits "$app_pid" || exit 1
    while $KILL -0 "$app_pid" >/dev/null 2>&1; do
        $SLEEP 2
    done
    stop_network "$uid"
}

main() {
    require_root
    local action="${1:-}"
    case "$action" in
        service-start-full)
            [ "$#" -eq 4 ] || fail "Неверные параметры service-start-full."
            local interface tun_name index
            interface="$(default_interface)"
            tun_name=""
            for ((index=72; index<=99; index++)); do
                if ! $IFCONFIG "utun$index" >/dev/null 2>&1; then
                    tun_name="utun$index"
                    break
                fi
            done
            [ -n "$tun_name" ] || fail "Нет свободного интерфейса utun."
            start_full "$2" "$3" "$4" "$tun_name" "$interface" 10808 \
                "/Library/PrivilegedHelperTools/com.denisbekker.MojaveRay.$2/tun2socks"
            ;;
        start-full)
            [ "$#" -eq 8 ] || fail "Неверные параметры start-full."
            start_full "$2" "$3" "$4" "$5" "$6" "$7" "$8"
            ;;
        start-proxy)
            [ "$#" -eq 3 ] || fail "Неверные параметры start-proxy."
            start_proxy "$2" "$3"
            ;;
        stop)
            [ "$#" -eq 2 ] || fail "Неверные параметры stop."
            stop_network "$2"
            echo "OK: сеть восстановлена"
            ;;
        watchdog)
            [ "$#" -eq 3 ] || exit 1
            watchdog "$2" "$3"
            ;;
        *) fail "Неизвестное действие системного помощника." ;;
    esac
}

main "$@"
