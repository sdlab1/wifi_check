#!/usr/bin/env bash
#
# wifi-check.sh — комплексная диагностика Wi-Fi и интернет-соединения в Linux
#
# GitHub: https://github.com/USERNAME/wifi-diagnostic
# License: MIT
#
set -uo pipefail

# ═══════════════════════════════════════════════════════════
#  НАСТРОЙКИ — меняйте под себя
# ═══════════════════════════════════════════════════════════

# Цели для PING (каждая получает по PING_COUNT пакетов)
PING_TARGETS=(
    "1.1.1.1"
    "8.8.8.8"
    "openrouter.ai"
    "opencode.ai"
)
PING_COUNT=100          # количество пакетов на каждую цель
PING_INTERVAL=0.2       # интервал между пакетами (сек)
PING_TIMEOUT=2          # таймаут ответа (сек)

# Цели для MTR (показывает потери по хопам)
MTR_TARGETS=(
    "openrouter.ai"
    "opencode.ai"
)
MTR_COUNT=50            # количество probes на хоп

# Логирование в файл (пусто — не логировать)
LOG_FILE=""

# ═══════════════════════════════════════════════════════════
#  ЦВЕТА (только если вывод в TTY)
# ═══════════════════════════════════════════════════════════

if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
    C_YELLOW="" C_BLUE="" C_CYAN=""
fi

section() { printf "\n${C_BOLD}${C_CYAN}── %s ────────────────────────────────────${C_RESET}\n\n" "$1"; }
ok()      { printf "${C_GREEN}✓${C_RESET} %s\n" "$1"; }
warn()    { printf "${C_YELLOW}⚠${C_RESET} %s\n" "$1"; }
err()     { printf "${C_RED}✗${C_RESET} %s\n" "$1"; }

# ═══════════════════════════════════════════════════════════
#  ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ═══════════════════════════════════════════════════════════

MISSING_DEPS=()
for cmd in inxi iw ip ping mtr awk grep; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING_DEPS+=("$cmd")
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    err "Отсутствуют зависимости: ${MISSING_DEPS[*]}"
    echo ""
    echo "Установите (Debian/Ubuntu/MX):"
    echo "  sudo apt install inxi iw iproute2 iputils-ping mtr-tiny"
    exit 1
fi

# ═══════════════════════════════════════════════════════════
#  АВТООПРЕДЕЛЕНИЕ WI-FI ИНТЕРФЕЙСА
# ═══════════════════════════════════════════════════════════

WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
if [ -z "${WIFI_IFACE:-}" ]; then
    err "Wi-Fi интерфейс не найден (iw dev не вернул ни одного)"
    exit 1
fi

# ═══════════════════════════════════════════════════════════
#  ЛОГИРОВАНИЕ
# ═══════════════════════════════════════════════════════════

if [ -n "$LOG_FILE" ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# ═══════════════════════════════════════════════════════════
#  ФУНКЦИЯ: ping с прогрессом в одну строку
# ═══════════════════════════════════════════════════════════

ping_with_progress() {
    local host="$1"
    local count="$2"
    local tmpfile
    tmpfile=$(mktemp)

    ping -c "$count" -i "$PING_INTERVAL" -W "$PING_TIMEOUT" "$host" > "$tmpfile" 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        local received
        received=$(grep -c "icmp_seq" "$tmpfile" 2>/dev/null)
        received=${received:-0}
        printf "\r  Прогресс: ${C_DIM}%d/%d${C_RESET}" "$received" "$count"
        sleep 0.3
    done
    wait "$pid" 2>/dev/null

    local received
    received=$(grep -c "icmp_seq" "$tmpfile" 2>/dev/null)
    received=${received:-0}

    # Цвет прогресса: зелёный если все, жёлтый если ≥90%, красный иначе
    local pct=$(( count > 0 ? received * 100 / count : 0 ))
    local color="$C_RED"
    [ "$pct" -ge 90 ] && color="$C_YELLOW"
    [ "$pct" -ge 100 ] && color="$C_GREEN"
    printf "\r  Прогресс: ${color}%d/%d${C_RESET} — готово\n" "$received" "$count"
    echo ""
    tail -3 "$tmpfile"
    rm -f "$tmpfile"
}

# ═══════════════════════════════════════════════════════════
#  ОСНОВНОЙ БЛОК
# ═══════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════"
printf "  ${C_BOLD}ДИАГНОСТИКА WI-FI${C_RESET} — %s\n" "$(date)"
echo "  Интерфейс: $WIFI_IFACE"
echo "═══════════════════════════════════════════════════════════"

# ─── 1. Железо и драйвер ────────────────────────────────────
section "1. ЖЕЛЕЗО И ДРАЙВЕР"
echo "Адаптер:"
inxi -n 2>/dev/null | grep -A2 "Device-1" || echo "  (inxi не вернул данные)"
echo ""
echo "Загруженные модули Wi-Fi:"
lsmod | grep -E "rtw|88x2bu|mt76|iwlwifi|ath" || echo "  (модули не найдены)"
echo ""
echo "Активный драйвер:"
lsusb -t 2>/dev/null | grep -E "rtw|88x2bu" | sed 's/^/  /' || true
echo ""
echo "Версия ядра: $(uname -r)"
echo ""
echo "Ошибки драйвера в dmesg (последние 20 строк):"
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    sudo dmesg 2>/dev/null | grep -iE "rtw_8822bu|88x2bu|mt76|iwlwifi" | tail -20 || echo "  (ошибок нет)"
else
    warn "Нужен sudo для чтения dmesg (пропускаем)"
fi

# ─── 2. Режим USB ───────────────────────────────────────────
section "2. РЕЖИМ USB"
lsusb -t 2>/dev/null || echo "  (lsusb недоступен)"
echo ""
echo "Интерпретация: 5000M = USB 3.0, 480M = USB 2.0"

# ─── 3. Состояние подключения ───────────────────────────────
section "3. СОСТОЯНИЕ ПОДКЛЮЧЕНИЯ"
iw dev "$WIFI_IFACE" link 2>/dev/null || echo "  $WIFI_IFACE не подключен"
echo ""
echo "IP-адрес:"
ip -brief addr show "$WIFI_IFACE"
echo ""
echo "Шлюз:"
ip route | grep default

# ─── 4. Сигнал и скорость ───────────────────────────────────
section "4. СИГНАЛ И СКОРОСТЬ"
iw dev "$WIFI_IFACE" station dump 2>/dev/null \
    | grep -E "signal|tx bitrate|rx bitrate|tx retries|tx failed|beacon loss|connected time" \
    || echo "  станция не найдена"

# ─── 5. Управление питанием ─────────────────────────────────
section "5. УПРАВЛЕНИЕ ПИТАНИЕМ"
echo "NetworkManager powersave:"
grep -r "wifi.powersave" /etc/NetworkManager/conf.d/ 2>/dev/null || echo "  (не найдено)"
echo ""
echo "Текущий режим питания:"
iwconfig "$WIFI_IFACE" 2>/dev/null | grep "Power Management" || echo "  (iwconfig недоступен)"
echo ""
echo "Параметры драйвера (modprobe.d):"
grep -h "rtw88\|88x2bu" /etc/modprobe.d/*.conf 2>/dev/null || echo "  (не найдено)"

# ─── 6. TCP/IP ──────────────────────────────────────────────
section "6. НАСТРОЙКИ TCP/IP"
echo "Congestion control:"
sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null
echo ""
echo "Буферы (rmem_max / wmem_max):"
sysctl -n net.core.rmem_max net.core.wmem_max 2>/dev/null
echo ""
echo "Доп. параметры:"
for p in net.ipv4.tcp_slow_start_after_idle \
         net.ipv4.tcp_window_scaling \
         net.ipv4.tcp_sack \
         net.ipv4.tcp_ecn; do
    printf "  %-40s = %s\n" "$p" "$(sysctl -n "$p" 2>/dev/null)"
done

# ─── 7. Статистика интерфейса ───────────────────────────────
section "7. СТАТИСТИКА ИНТЕРФЕЙСА"
ip -s link show "$WIFI_IFACE"

# ─── 8. PING ────────────────────────────────────────────────
section "8. ТЕСТ PING ($PING_COUNT пакетов на цель)"

GW=$(ip route | grep default | awk '{print $3}' | head -1)
if [ -n "${GW:-}" ]; then
    echo "▸ Шлюз (baseline, $GW):"
    ping_with_progress "$GW" "$PING_COUNT"
fi

for target in "${PING_TARGETS[@]}"; do
    echo ""
    echo "▸ $target:"
    ping_with_progress "$target" "$PING_COUNT"
done

# ─── 9. MTR ─────────────────────────────────────────────────
section "9. MTR ($MTR_COUNT probes на хоп)"
echo "  ${C_DIM}Loss% на хопе 1 > 0 — проблема в вашем Wi-Fi${C_RESET}"
echo "  ${C_DIM}Loss% на хопе 2+ > 0 — проблема у провайдера/оператора${C_RESET}"

for target in "${MTR_TARGETS[@]}"; do
    echo ""
    echo "▸ mtr -r -c $MTR_COUNT $target:"
    echo ""
    mtr -r -c "$MTR_COUNT" "$target"
done

echo ""
echo "═══════════════════════════════════════════════════════════"
printf "  ${C_BOLD}ГОТОВО${C_RESET} — %s\n" "$(date +%H:%M:%S)"
echo "═══════════════════════════════════════════════════════════"
