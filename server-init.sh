#!/usr/bin/env bash
# ==============================================================================
#  server-init.sh — Первичная инициализация Linux-сервера
#
#  Поддерживаемые дистрибутивы:
#    Debian/Ubuntu/Mint/Kali/Pop!_OS    (apt)
#    RHEL/CentOS/AlmaLinux/Rocky/Oracle (dnf/yum + EPEL)
#    Fedora                             (dnf)
#    Arch Linux/Manjaro/EndeavourOS     (pacman)
#    Alpine Linux                       (apk)
#    openSUSE Leap/Tumbleweed           (zypper)
#
#  Использование:
#    sudo bash server-init.sh [--dry-run] [--skip-packages] [--replace-keys]
#                             [--ssh-key "<pubkey>"] [--help]
#
#  Идемпотентность: скрипт безопасно запускать повторно.
# ==============================================================================

set -euo pipefail

# ─── Встроенные публичные SSH-ключи владельца ────────────────────────────────
DEFAULT_SSH_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTZInxJwOu59cJICNH4boabF5Bq1XASTnhTNvH1IsmS"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD3H0tLIjwCMCtuoOn9KTU7itiLXBwCpQu94r4v7tHJJFnvmwiYftyiXxGigx4G92b+qB8Chl591mil2p/q3gdqSpPMqNAtlJkrcUcISTEUy1Qd7n0YVwuem+cOiQys+OF8n17yNe5lwsgEbC/cVG4YeFki9BEDU3igdrOeBLdWcDE7tg0ihluO/gY6/+39XK10o7+f7wTZQluV0j1r4n+ycZgMezH8Bl5WF7A2YagRjQBr5Iw6zB++WKxvrnBP7jPmGWhHPXo57ZSRbFz2lr4JSHzlKE9SnfBZ2K4mJvcmRTyuY2/Xq53Eza74SLnCQ866yznjLyDp4UjfXMsDLh97 KostiaevVI"
)

# ─── Цвета и вспомогательные функции ─────────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'

log_section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${RESET}"; echo -e "${BOLD}${BLUE}  $1${RESET}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════════${RESET}"; }
log_ok()      { echo -e "  ${GREEN}✔${RESET}  $1"; }
log_skip()    { echo -e "  ${DIM}–  $1 (пропущено, уже выполнено)${RESET}"; }
log_info()    { echo -e "  ${CYAN}ℹ${RESET}  $1"; }
log_warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
log_error()   { echo -e "  ${RED}✘${RESET}  $1" >&2; }
log_step()    { echo -e "  ${YELLOW}→${RESET}  $1"; }
die()         { log_error "$1"; exit 1; }

# ─── Разбор аргументов ────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_PACKAGES=false
REPLACE_KEYS=false
EXTRA_SSH_KEYS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift ;;
        --skip-packages)
            SKIP_PACKAGES=true
            shift ;;
        --replace-keys)
            REPLACE_KEYS=true
            shift ;;
        --ssh-key)
            [[ $# -lt 2 ]] && die "Флаг --ssh-key требует аргумент с публичным ключом"
            EXTRA_SSH_KEYS+=("$2")
            shift 2 ;;
        --ssh-key=*)
            EXTRA_SSH_KEYS+=("${1#*=}")
            shift ;;
        --help|-h)
            echo "Использование: sudo bash server-init.sh [опции]"
            echo "  --dry-run            Показать что будет сделано без реальных изменений"
            echo "  --skip-packages      Пропустить установку пакетов (только конфиги)"
            echo "  --ssh-key \"<ключ>\"   Добавить дополнительный публичный SSH-ключ"
            echo "  --replace-keys       Заменить authorized_keys только ключами из скрипта"
            echo "  --help, -h           Показать эту справку"
            exit 0 ;;
        *)
            die "Неизвестный аргумент: $1. Используйте --help." ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] $*${RESET}"
    else
        "$@"
    fi
}

# ─── Глобальное состояние ОС (заполняется в detect_os) ───────────────────────
OS_ID=""        # debian, ubuntu, rhel, fedora, arch, alpine, opensuse...
OS_FAMILY=""    # debian | rhel | arch | alpine | suse
OS_CODENAME=""  # bullseye, bookworm, trixie, jammy...
OS_VERSION=""   # основная версия (11, 12, 13, 22...)
OS_PRETTY=""    # красивое название для вывода
PKG_MGR=""      # apt | dnf | yum | pacman | apk | zypper
HAS_SYSTEMD=true
SSH_SERVICE="ssh"   # ssh (Debian/Ubuntu) или sshd (остальные)

# ─── 0. Определение дистрибутива ─────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        OS_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "")
        OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1 2>/dev/null || echo "")
        OS_PRETTY=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "$OS_ID")
        local id_like; id_like=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "")
        [[ -z "$OS_ID" && -n "$id_like" ]] && OS_ID="$id_like"
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|mint|pop|kali|raspbian|elementary|zorin|parrot)
            OS_FAMILY="debian"; PKG_MGR="apt"; SSH_SERVICE="ssh" ;;
        rhel|centos|almalinux|rocky|ol|oracle|amzn|scientific)
            OS_FAMILY="rhel"; SSH_SERVICE="sshd"
            command -v dnf &>/dev/null && PKG_MGR="dnf" || PKG_MGR="yum" ;;
        fedora)
            OS_FAMILY="rhel"; PKG_MGR="dnf"; SSH_SERVICE="sshd" ;;
        arch|manjaro|endeavouros|garuda|artix|cachyos)
            OS_FAMILY="arch"; PKG_MGR="pacman"; SSH_SERVICE="sshd" ;;
        alpine)
            OS_FAMILY="alpine"; PKG_MGR="apk"; SSH_SERVICE="sshd"; HAS_SYSTEMD=false ;;
        opensuse*|suse|sles|leap|tumbleweed)
            OS_FAMILY="suse"; PKG_MGR="zypper"; SSH_SERVICE="sshd" ;;
        *)
            if   command -v apt-get &>/dev/null; then OS_FAMILY="debian"; PKG_MGR="apt";    SSH_SERVICE="ssh"
            elif command -v dnf     &>/dev/null; then OS_FAMILY="rhel";   PKG_MGR="dnf";    SSH_SERVICE="sshd"
            elif command -v yum     &>/dev/null; then OS_FAMILY="rhel";   PKG_MGR="yum";    SSH_SERVICE="sshd"
            elif command -v pacman  &>/dev/null; then OS_FAMILY="arch";   PKG_MGR="pacman"; SSH_SERVICE="sshd"
            elif command -v apk     &>/dev/null; then OS_FAMILY="alpine"; PKG_MGR="apk";    SSH_SERVICE="sshd"; HAS_SYSTEMD=false
            elif command -v zypper  &>/dev/null; then OS_FAMILY="suse";   PKG_MGR="zypper"; SSH_SERVICE="sshd"
            else OS_FAMILY="unknown"; PKG_MGR="unknown"
            fi ;;
    esac

    if ! command -v systemctl &>/dev/null; then
        HAS_SYSTEMD=false
    fi
}

# ─── Абстракция пакетного менеджера ──────────────────────────────────────────
pkg_update() {
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true ;;
        dnf)    dnf makecache -q --refresh 2>/dev/null || dnf check-update -q 2>/dev/null || true ;;
        yum)    yum makecache -q 2>/dev/null || true ;;
        pacman) pacman -Sy --noconfirm --quiet 2>/dev/null || true ;;
        apk)    apk update -q 2>/dev/null || true ;;
        zypper) zypper refresh -q 2>/dev/null || true ;;
    esac
}

pkg_install() {
    local pkg="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] pkg_install ${pkg}${RESET}"
        return 0
    fi
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>/dev/null ;;
        dnf)    dnf install -y -q "$pkg" 2>/dev/null ;;
        yum)    yum install -y -q "$pkg" 2>/dev/null ;;
        pacman) pacman -S --noconfirm --needed --quiet "$pkg" 2>/dev/null ;;
        apk)    apk add -q "$pkg" 2>/dev/null ;;
        zypper) zypper install -y -q "$pkg" 2>/dev/null ;;
        *)      return 1 ;;
    esac
}

pkg_install_many() {
    local label="${1}"; shift
    local failed=()
    log_step "Устанавливаем: ${label}..."
    for pkg in "$@"; do
        if ! pkg_install "$pkg"; then
            log_warn "Пакет '${pkg}' недоступен — пропущен"
            failed+=("$pkg")
        fi
    done
    [[ ${#failed[@]} -eq 0 ]] && log_ok "${label} установлены" || log_warn "Пропущены: ${failed[*]}"
}

# ─── Абстракция сервисного менеджера ──────────────────────────────────────────
svc_enable() {
    local svc="$1"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        run systemctl enable "$svc" 2>/dev/null || true
    else
        run rc-update add "$svc" default 2>/dev/null || true
    fi
}

svc_start() {
    local svc="$1"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        run systemctl start "$svc" 2>/dev/null || true
    else
        run rc-service "$svc" start 2>/dev/null || true
    fi
}

svc_restart() {
    local svc="$1"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        run systemctl restart "$svc" 2>/dev/null || true
    else
        run rc-service "$svc" restart 2>/dev/null || true
    fi
}

svc_reload() {
    local svc="$1"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        run systemctl reload "$svc" 2>/dev/null || run systemctl restart "$svc" 2>/dev/null || true
    else
        run rc-service "$svc" reload 2>/dev/null || run rc-service "$svc" restart 2>/dev/null || true
    fi
}

svc_is_active() {
    local svc="$1"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        systemctl is-active --quiet "$svc" 2>/dev/null
    else
        rc-service "$svc" status 2>/dev/null | grep -q started
    fi
}

# ─── Предварительные проверки ─────────────────────────────────────────────────
preflight_checks() {
    log_section "Предварительные проверки"

    if [[ $EUID -ne 0 && "$DRY_RUN" != "true" ]]; then
        die "Скрипт должен быть запущен с правами root: sudo bash $0"
    fi
    log_ok "Права запуска проверены (root / dry-run)"

    detect_os
    if [[ "$OS_FAMILY" == "unknown" || "$PKG_MGR" == "unknown" ]]; then
        die "Неизвестный дистрибутив. Поддерживаются: Debian/Ubuntu, RHEL/CentOS/AlmaLinux/Rocky, Fedora, Arch, Alpine, openSUSE"
    fi
    log_ok "ОС: ${OS_PRETTY} (family: ${OS_FAMILY}, pkg: ${PKG_MGR})"
    [[ "$HAS_SYSTEMD" == "false" ]] && log_info "Системный менеджер: OpenRC (не systemd)"

    if ! curl -fsS --connect-timeout 5 https://example.com > /dev/null 2>&1; then
        log_warn "Нет доступа к интернету — некоторые компоненты могут не установиться"
    else
        log_ok "Интернет-соединение в порядке"
    fi

    local free_kb; free_kb=$(df /usr --output=avail 2>/dev/null | tail -1 || df / --output=avail 2>/dev/null | tail -1 || echo 10485760)
    local free_gb; free_gb=$(( free_kb / 1024 / 1024 ))
    (( free_kb < 2097152 )) \
        && log_warn "Мало места: ${free_gb} ГБ (рекомендуется ≥2 ГБ)" \
        || log_ok "Свободное место: ${free_gb} ГБ"
}

# ─── 1. Системная подготовка ──────────────────────────────────────────────────
setup_system() {
    log_section "1 · Системная подготовка"

    # ── Таймзона ─────────────────────────────────────────────────────────────
    local current_tz="unknown"
    if command -v timedatectl &>/dev/null; then
        current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
    elif [[ -f /etc/timezone ]]; then
        current_tz=$(cat /etc/timezone)
    fi

    if [[ "$current_tz" == "Europe/Moscow" ]]; then
        log_skip "Таймзона уже Europe/Moscow"
    else
        log_step "Устанавливаем таймзону Europe/Moscow (было: ${current_tz})"
        if command -v timedatectl &>/dev/null; then
            run timedatectl set-timezone Europe/Moscow 2>/dev/null || {
                run ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
                [[ "$DRY_RUN" != "true" ]] && echo "Europe/Moscow" > /etc/timezone
            }
        else
            run ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
            [[ "$DRY_RUN" != "true" ]] && echo "Europe/Moscow" > /etc/timezone
        fi
        log_ok "Таймзона → Europe/Moscow"
    fi

    # ── NTP ──────────────────────────────────────────────────────────────────
    log_step "Настраиваем синхронизацию времени"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        if command -v timedatectl &>/dev/null; then
            run mkdir -p /etc/systemd/timesyncd.conf.d
            if [[ "$DRY_RUN" != "true" ]]; then
                cat > /etc/systemd/timesyncd.conf.d/custom.conf << 'EOF'
[Time]
NTP=0.ru.pool.ntp.org 1.ru.pool.ntp.org 0.europe.pool.ntp.org
FallbackNTP=time.cloudflare.com pool.ntp.org
EOF
            fi
            run systemctl enable --now systemd-timesyncd 2>/dev/null || true
            run timedatectl set-ntp true 2>/dev/null || true
            log_ok "NTP: systemd-timesyncd включён"
        fi
    elif command -v chronyd &>/dev/null; then
        run rc-service chronyd start 2>/dev/null || true
        run rc-update add chronyd default 2>/dev/null || true
        log_ok "NTP: chronyd (OpenRC)"
    elif command -v ntpd &>/dev/null; then
        run rc-service ntpd start 2>/dev/null || true
        run rc-update add ntpd default 2>/dev/null || true
        log_ok "NTP: ntpd (OpenRC)"
    else
        log_warn "NTP-клиент не найден — установите chrony или ntp вручную"
    fi

    # ── Лимит логов systemd-journald (200 МБ) ────────────────────────────────
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        log_step "Ограничиваем размер журнала systemd-journald до 200 МБ"
        run mkdir -p /etc/systemd/journald.conf.d
        if [[ "$DRY_RUN" != "true" ]]; then
            cat > /etc/systemd/journald.conf.d/99-server-init.conf << 'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
            systemctl restart systemd-journald 2>/dev/null || true
        fi
        log_ok "Лимит systemd-journald: SystemMaxUse=200M"
    fi

    # ── Локали ───────────────────────────────────────────────────────────────
    log_step "Настраиваем локали (en_US.UTF-8 + ru_RU.UTF-8)"
    case "$OS_FAMILY" in
        debian)
            if ! locale -a 2>/dev/null | grep -qi "en_US\.utf-\?8"; then
                pkg_install locales 2>/dev/null || true
            fi
            if ! locale -a 2>/dev/null | grep -qi "en_US\.utf-\?8" || ! locale -a 2>/dev/null | grep -qi "ru_RU\.utf-\?8"; then
                if [[ -f /etc/locale.gen ]]; then
                    run sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
                    run sed -i 's/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
                    run locale-gen
                fi
            else
                log_skip "Локали en_US.UTF-8 и ru_RU.UTF-8 уже сгенерированы"
            fi
            run update-locale LANG=en_US.UTF-8 2>/dev/null || true
            ;;
        rhel)
            if ! locale -a 2>/dev/null | grep -qi "en_US\.utf-\?8"; then
                pkg_install "glibc-langpack-en" 2>/dev/null || true
                pkg_install "glibc-langpack-ru" 2>/dev/null || true
            fi
            run localectl set-locale LANG=en_US.UTF-8 2>/dev/null || true
            ;;
        arch)
            if [[ -f /etc/locale.gen ]]; then
                run sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
                run sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
                run locale-gen
            fi
            [[ "$DRY_RUN" != "true" ]] && echo "LANG=en_US.UTF-8" > /etc/locale.conf
            ;;
        alpine)
            log_info "Alpine Linux: ограниченная поддержка локалей (musl libc)"
            [[ "$DRY_RUN" != "true" ]] && { mkdir -p /etc/profile.d; echo 'export LANG=en_US.UTF-8' > /etc/profile.d/locale.sh; }
            ;;
        suse)
            run localectl set-locale LANG=en_US.UTF-8 2>/dev/null || true
            ;;
    esac

    if [[ "$DRY_RUN" != "true" && "$OS_FAMILY" != "alpine" ]]; then
        cat > /etc/locale.conf << 'EOF'
LANG=en_US.UTF-8
LC_MESSAGES=en_US.UTF-8
LC_TIME=ru_RU.UTF-8
LC_MONETARY=ru_RU.UTF-8
LC_NUMERIC=ru_RU.UTF-8
LC_COLLATE=en_US.UTF-8
EOF
    fi
    log_ok "Локали настроены: LANG=en_US.UTF-8, ru_RU.UTF-8 как вспомогательная"

    # ── Обновление индекса пакетов ────────────────────────────────────────────
    log_step "Обновляем индекс пакетов"
    run pkg_update
    log_ok "Индекс пакетов обновлён"
}

# ─── 1б. Авто-создание Swap и тюнинг ядра (TCP BBR + sysctl) ─────────────────
setup_swap() {
    log_section "1б · Настройка Swap-файла"

    local swap_total_kb=0
    swap_total_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if (( swap_total_kb > 0 )); then
        local swap_mb=$(( swap_total_kb / 1024 ))
        log_skip "Swap уже активен (${swap_mb} МБ)"
        return 0
    fi

    local ram_kb; ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local ram_mb=$(( ram_kb / 1024 ))
    if (( ram_mb > 4200 )); then
        log_skip "ОЗУ ${ram_mb} МБ (> 4 ГБ) — создание авто-swap не требуется"
        return 0
    fi

    local free_kb; free_kb=$(df / --output=avail 2>/dev/null | tail -1 || echo 0)
    if (( free_kb < 5242880 )); then
        log_warn "Свободно менее 5 ГБ на / — пропускаем создание /swapfile"
        return 0
    fi

    log_step "ОЗУ ${ram_mb} МБ, swap отсутствует — создаём /swapfile (2 ГБ)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] создание и активация /swapfile (2G)${RESET}"
        return 0
    fi

    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l 2G /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null || {
                log_warn "Не удалось выделить место под /swapfile"
                rm -f /swapfile
                return 0
            }
        fi
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || true
    if swapon /swapfile 2>/dev/null; then
        if ! grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log_ok "Swap 2 ГБ (/swapfile) создан, активирован и добавлен в /etc/fstab"
    else
        rm -f /swapfile
        log_warn "Ядро/контейнер не разрешает swapon (например, LXC/OpenVZ) — пропущено"
    fi
}

setup_sysctl() {
    log_section "1в · Сетевой тюнинг (TCP BBR) и параметры ядра"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] настройка /etc/sysctl.d/99-server-init.conf (TCP BBR, swappiness=10)${RESET}"
        return 0
    fi

    mkdir -p /etc/sysctl.d
    modprobe tcp_bbr 2>/dev/null || true

    local has_bbr=false
    if grep -qw "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        has_bbr=true
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi

    {
        echo "# /etc/sysctl.d/99-server-init.conf — создано server-init.sh"
        echo ""
        echo "# Память и кэш ФС"
        echo "vm.swappiness = 10"
        echo "vm.vfs_cache_pressure = 50"
        echo ""
        if [[ "$has_bbr" == "true" ]]; then
            echo "# Алгоритм управления перегрузкой TCP BBR"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
            echo ""
        fi
        echo "# Базовая сетевая защита"
        echo "net.ipv4.tcp_syncookies = 1"
        echo "net.ipv4.conf.all.rp_filter = 1"
        echo "net.ipv4.conf.default.rp_filter = 1"
        echo "net.ipv4.conf.all.accept_redirects = 0"
        echo "net.ipv4.conf.default.accept_redirects = 0"
        echo "net.ipv4.conf.all.send_redirects = 0"
    } > /etc/sysctl.d/99-server-init.conf

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-server-init.conf >/dev/null 2>&1 || true

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "TCP BBR активирован (congestion_control = bbr, qdisc = fq)"
    else
        log_info "TCP congestion control: ${current_cc} (модуль BBR недоступен в текущем ядре)"
    fi
    log_ok "Параметры sysctl применены (vm.swappiness=10, защита сети)"
}

# ─── 1г. Дополнительные репозитории ──────────────────────────────────────────
setup_extra_repos() {
    log_section "1г · Настройка репозиториев"

    case "$OS_FAMILY" in
        debian)
            # Разделяем собственно Debian и Ubuntu/производные
            if [[ "$OS_ID" == "ubuntu" ]]; then
                if command -v add-apt-repository &>/dev/null && [[ "$DRY_RUN" != "true" ]]; then
                    add-apt-repository -y universe >/dev/null 2>&1 || true
                    add-apt-repository -y multiverse >/dev/null 2>&1 || true
                    apt-get update -qq 2>/dev/null || true
                    log_ok "Ubuntu: репозитории universe и multiverse проверены"
                else
                    log_skip "Ubuntu: стандартные репозитории активны"
                fi
                return 0
            elif [[ "$OS_ID" != "debian" ]]; then
                log_skip "Производный дистрибутив (${OS_ID}) — пропускаем правку Debian sources.list"
                return 0
            fi

            local src="/etc/apt/sources.list"
            local deb822="/etc/apt/sources.list.d/debian.sources"
            local changed=false
            local codename="$OS_CODENAME"
            [[ -z "$codename" ]] && codename=$(lsb_release -sc 2>/dev/null || echo "")
            [[ -z "$codename" ]] && { log_skip "Не удалось определить codename — пропускаем backports"; return 0; }
            log_info "Debian codename: ${codename}"

            if [[ "$DRY_RUN" != "true" ]]; then
                # На Debian 11 (bullseye) старый URL deb.debian.org/debian bullseye-backports удалён (перенесён в archive.debian.org)
                if [[ "$codename" == "bullseye" && -f "$src" ]]; then
                    if grep -q "deb\.debian\.org/debian[[:space:]]\+bullseye-backports" "$src" 2>/dev/null; then
                        sed -i '/deb\.debian\.org\/debian[[:space:]]\+bullseye-backports/d' "$src" 2>/dev/null || true
                        changed=true
                        log_info "Удалён устаревший URL deb.debian.org bullseye-backports"
                    fi
                fi

                # Начиная с Debian 12 (bookworm) добавился компонент non-free-firmware
                local nf_components="contrib non-free"
                if [[ "$codename" != "bullseye" && "$codename" != "buster" ]]; then
                    nf_components="contrib non-free non-free-firmware"
                fi

                if [[ -f "$deb822" ]]; then
                    if ! grep -q "non-free" "$deb822" 2>/dev/null; then
                        sed -i "s/^Components: main$/Components: main ${nf_components}/" "$deb822" 2>/dev/null || true
                        changed=true
                        log_ok "Добавлены ${nf_components} в debian.sources"
                    fi
                elif [[ -f "$src" ]]; then
                    if grep -q "^deb " "$src" 2>/dev/null && ! grep -q "non-free" "$src" 2>/dev/null; then
                        sed -i "/^deb http.*debian\.org\/debian[[:space:]]/ s/$/ ${nf_components}/" "$src" 2>/dev/null || true
                        changed=true
                        log_ok "Добавлены ${nf_components} в sources.list"
                    fi
                    if ! grep -qE "^deb.*security" "$src" 2>/dev/null; then
                        echo "deb http://security.debian.org/debian-security ${codename}-security main ${nf_components}" >> "$src"
                        changed=true
                        log_ok "Добавлен ${codename}-security"
                    fi
                    if ! grep -q "${codename}-backports" "$src" 2>/dev/null; then
                        if [[ "$codename" == "bullseye" ]]; then
                            echo "deb [check-valid-until=no] http://archive.debian.org/debian bullseye-backports main contrib non-free" >> "$src"
                            log_ok "Добавлен archive.debian.org bullseye-backports"
                        else
                            echo "deb http://deb.debian.org/debian ${codename}-backports main ${nf_components}" >> "$src"
                            log_ok "Добавлен ${codename}-backports"
                        fi
                        changed=true
                    fi
                fi

                if [[ "$changed" == "true" ]]; then
                    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || log_warn "apt-get update завершился с предупреждениями"
                    log_ok "Индекс apt обновлён после настройки источников"
                else
                    log_skip "Источники Debian уже настроены"
                fi
            else
                echo -e "  ${DIM}[dry-run] настройка источников Debian (${codename})${RESET}"
            fi
            ;;

        rhel)
            log_step "Подключаем EPEL и CRB для RHEL-семейства..."
            if ! rpm -q epel-release &>/dev/null 2>&1; then
                if [[ "$OS_ID" == "amzn" ]]; then
                    pkg_install "amazon-linux-extras" && run amazon-linux-extras install epel -y 2>/dev/null || true
                elif (( ${OS_VERSION:-8} >= 9 )); then
                    pkg_install "epel-release" || true
                    run dnf config-manager --set-enabled crb 2>/dev/null || \
                    run dnf config-manager --set-enabled powertools 2>/dev/null || true
                else
                    pkg_install "epel-release" || true
                    run dnf config-manager --set-enabled powertools 2>/dev/null || \
                    run yum-config-manager --enable powertools 2>/dev/null || true
                fi
                log_ok "EPEL подключён"
                run pkg_update
            else
                log_skip "EPEL уже установлен"
            fi
            ;;

        arch)
            log_skip "Arch Linux: основные репозитории уже включены"
            ;;

        alpine)
            if ! grep -q "community" /etc/apk/repositories 2>/dev/null; then
                local alpine_ver; alpine_ver=$(cut -d. -f1-2 /etc/alpine-release 2>/dev/null || echo "edge")
                if [[ "$DRY_RUN" != "true" ]]; then
                    echo "https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community" >> /etc/apk/repositories
                    run apk update -q
                    log_ok "Alpine community репозиторий добавлен"
                fi
            else
                log_skip "Alpine community уже настроен"
            fi
            ;;

        suse)
            log_step "Проверяем репозитории openSUSE..."
            run zypper refresh -q 2>/dev/null || true
            log_ok "Репозитории openSUSE обновлены"
            ;;
    esac
}

# ─── 2. Установка пакетов ─────────────────────────────────────────────────────
install_packages() {
    log_section "2 · Установка CLI-утилит"

    [[ "$SKIP_PACKAGES" == "true" ]] && { log_warn "Установка пакетов пропущена (--skip-packages)"; return 0; }

    local base_deps=()
    case "$OS_FAMILY" in
        debian)
            base_deps=(curl wget git ca-certificates gnupg apt-transport-https
                       build-essential unzip poppler-utils)
            [[ "$OS_ID" == "ubuntu" ]] && base_deps+=(software-properties-common)
            ;;
        rhel)
            base_deps=(curl wget git ca-certificates gnupg2
                       gcc gcc-c++ make unzip poppler-utils) ;;
        arch)
            base_deps=(curl wget git ca-certificates gnupg
                       base-devel unzip poppler) ;;
        alpine)
            base_deps=(curl wget git ca-certificates gnupg
                       build-base unzip poppler-utils) ;;
        suse)
            base_deps=(curl wget git ca-certificates gpg2
                       gcc gcc-c++ make unzip poppler-tools) ;;
    esac
    pkg_install_many "Базовые зависимости" "${base_deps[@]}"

    local cli_common=(htop ncdu jq tmux tree file lsof strace pv bc rsync socat)
    pkg_install_many "Общие утилиты" "${cli_common[@]}"

    # ripgrep
    pkg_install ripgrep || log_warn "ripgrep: недоступен"

    # fd-find
    case "$OS_FAMILY" in
        debian)  pkg_install fd-find  || log_warn "fd-find: недоступен" ;;
        arch)    pkg_install fd       || log_warn "fd: недоступен" ;;
        alpine)  pkg_install fd       || log_warn "fd: недоступен" ;;
        rhel)    pkg_install fd-find  || pkg_install fd || log_warn "fd: недоступен" ;;
        suse)    pkg_install fd       || log_warn "fd: недоступен" ;;
    esac

    # bat
    case "$OS_FAMILY" in
        debian)
            if ! pkg_install bat 2>/dev/null; then
                pkg_install batcat 2>/dev/null || log_warn "bat: недоступен"
            fi ;;
        rhel|arch|alpine|suse) pkg_install bat || log_warn "bat: недоступен" ;;
    esac

    # chafa
    case "$OS_FAMILY" in
        debian)
            if ! pkg_install chafa 2>/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -t "${OS_CODENAME}-backports" chafa 2>/dev/null \
                    || log_warn "chafa: недоступен"
            fi ;;
        rhel|arch|alpine|suse) pkg_install chafa || log_warn "chafa: недоступен" ;;
    esac

    # DNS утилиты
    case "$OS_FAMILY" in
        debian)  pkg_install dnsutils   || log_warn "dnsutils: недоступен" ;;
        rhel)    pkg_install bind-utils || log_warn "bind-utils: недоступен" ;;
        arch)    pkg_install bind       || log_warn "bind: недоступен" ;;
        alpine)  pkg_install bind-tools || log_warn "bind-tools: недоступен" ;;
        suse)    pkg_install bind-utils || log_warn "bind-utils: недоступен" ;;
    esac

    pkg_install mtr   || log_warn "mtr: недоступен"
    pkg_install iotop || log_warn "iotop: недоступен"
    case "$OS_FAMILY" in
        debian|rhel|arch|suse) pkg_install sysstat || log_warn "sysstat: недоступен" ;;
        alpine) log_info "sysstat: в Alpine используйте procps" ;;
    esac

    # Архиваторы
    local archivers=()
    case "$OS_FAMILY" in
        debian) archivers=(zip unzip xz-utils p7zip-full) ;;
        rhel)   archivers=(zip unzip xz p7zip) ;;
        arch)   archivers=(zip unzip xz p7zip) ;;
        alpine) archivers=(zip unzip xz 7zip) ;;
        suse)   archivers=(zip unzip xz p7zip) ;;
    esac
    pkg_install_many "Архиваторы" "${archivers[@]}"

    # eza / exa
    case "$OS_FAMILY" in
        debian|rhel|suse)
            if ! pkg_install eza 2>/dev/null; then
                pkg_install exa 2>/dev/null || log_info "eza/exa: недоступен, используем ls"
            fi ;;
        arch)   pkg_install eza || pkg_install exa || log_info "eza: недоступен" ;;
        alpine) pkg_install eza 2>/dev/null || log_info "eza: недоступен в Alpine" ;;
    esac

    pkg_install net-tools || log_warn "net-tools: недоступен"

    log_ok "Установка CLI-утилит завершена"

    install_btop
    install_fzf
    install_zoxide
    install_starship
}

install_btop() {
    command -v btop &>/dev/null && { log_skip "btop уже установлен ($(btop --version 2>/dev/null | head -1))"; return 0; }
    log_step "Устанавливаем btop..."

    pkg_install btop && { log_ok "btop установлен через ${PKG_MGR}"; return 0; }

    if [[ "$OS_FAMILY" == "debian" && -n "$OS_CODENAME" && "$DRY_RUN" != "true" ]]; then
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -t "${OS_CODENAME}-backports" btop 2>/dev/null; then
            log_ok "btop установлен из ${OS_CODENAME}-backports"
            return 0
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] загрузка btop из GitHub releases${RESET}"
        return 0
    fi

    local arch; arch=$(uname -m)
    local arch_suffix
    case "$arch" in
        x86_64)  arch_suffix="x86_64-linux-musl" ;;
        aarch64) arch_suffix="aarch64-linux-musl" ;;
        *)  log_warn "btop: неподдерживаемая архитектура ${arch}"; return 0 ;;
    esac

    log_step "Ищем актуальный btop release через GitHub API..."
    local btop_url
    btop_url=$(curl -fsSL "https://api.github.com/repos/aristocratos/btop/releases/latest" 2>/dev/null \
        | grep -o '"browser_download_url": *"[^"]*'"${arch_suffix}"'[^"]*\.\(tbz\|tar\.bz2\)"' \
        | head -1 | cut -d'"' -f4 || true)

    [[ -z "$btop_url" ]] && { log_warn "btop: не удалось получить URL из GitHub API"; return 0; }

    local tmp_dir; tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN
    local ext="tbz"; [[ "$btop_url" == *".tar.bz2" ]] && ext="tar.bz2"

    if curl -fsSL "$btop_url" -o "${tmp_dir}/btop.${ext}"; then
        tar -xjf "${tmp_dir}/btop.${ext}" -C "$tmp_dir" 2>/dev/null || true
        local btop_bin; btop_bin=$(find "$tmp_dir" -name btop -type f | head -1)
        if [[ -n "$btop_bin" ]]; then
            install -Dm755 "$btop_bin" /usr/local/bin/btop
            log_ok "btop установлен из GitHub release"
        else
            log_warn "btop: бинарник не найден в архиве"
        fi
    else
        log_warn "btop: не удалось загрузить архив"
    fi
}

install_fzf() {
    command -v fzf &>/dev/null && { log_skip "fzf уже установлен ($(fzf --version 2>/dev/null))"; return 0; }
    log_step "Устанавливаем fzf..."
    pkg_install fzf && { log_ok "fzf установлен через ${PKG_MGR}"; return 0; }

    if [[ "$DRY_RUN" != "true" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git /tmp/fzf-install 2>/dev/null || true
        if [[ -d /tmp/fzf-install ]]; then
            bash /tmp/fzf-install/install --bin 2>/dev/null || true
            [[ -f /tmp/fzf-install/bin/fzf ]] && install -Dm755 /tmp/fzf-install/bin/fzf /usr/local/bin/fzf
            rm -rf /tmp/fzf-install
            log_ok "fzf установлен из GitHub"
        fi
    else
        echo -e "  ${DIM}[dry-run] установка fzf из GitHub${RESET}"
    fi
}

install_zoxide() {
    # Если zoxide был установлен ранее в /root/.local/bin, переносим в /usr/local/bin
    if [[ ! -x /usr/local/bin/zoxide && -x /root/.local/bin/zoxide && "$DRY_RUN" != "true" ]]; then
        install -Dm755 /root/.local/bin/zoxide /usr/local/bin/zoxide
    fi

    command -v zoxide &>/dev/null && { log_skip "zoxide уже установлен ($(zoxide --version 2>/dev/null))"; return 0; }
    log_step "Устанавливаем zoxide..."
    pkg_install zoxide && { log_ok "zoxide установлен через ${PKG_MGR}"; return 0; }

    if [[ "$DRY_RUN" != "true" ]]; then
        if curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh -s -- --bin-dir /usr/local/bin; then
            log_ok "zoxide установлен в /usr/local/bin"
        else
            log_warn "zoxide: не удалось установить"
        fi
    else
        echo -e "  ${DIM}[dry-run] установка zoxide в /usr/local/bin${RESET}"
    fi
}

install_starship() {
    command -v starship &>/dev/null && { log_skip "starship уже установлен ($(starship --version 2>/dev/null | head -1))"; return 0; }
    log_step "Устанавливаем starship..."

    [[ "$OS_FAMILY" == "arch" ]] && pkg_install starship && { log_ok "starship установлен через pacman"; return 0; }

    if [[ "$DRY_RUN" != "true" ]]; then
        if curl -fsSL https://starship.rs/install.sh | sh -s -- --yes; then
            log_ok "starship установлен"
        else
            log_warn "starship: не удалось установить"
        fi
    else
        echo -e "  ${DIM}[dry-run] установка starship через starship.rs/install.sh${RESET}"
    fi
}

# ─── 3. Утилита view-pdf ──────────────────────────────────────────────────────
install_view_pdf() {
    log_section "3 · Установка утилиты view-pdf"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /usr/local/bin/view-pdf << 'SCRIPT'
#!/usr/bin/env bash
# view-pdf — просмотр PDF в терминале (графика через chafa, текст через pdftotext)
#
# Использование:
#   view-pdf file.pdf              # постраничный рендеринг
#   view-pdf file.pdf --text       # текстовый слой
#   view-pdf file.pdf --page 3     # конкретная страница
#   view-pdf file.pdf --width 120  # ширина в символах

set -euo pipefail

usage() {
    echo "Использование: view-pdf <file.pdf> [опции]"
    echo "  --text         Извлечь текстовый слой"
    echo "  --page N       Показать страницу N"
    echo "  --width N      Ширина в символах (по умолчанию: ширина терминала)"
    echo "  --dpi N        DPI рендеринга (по умолчанию: 150)"
}

check_deps() {
    local missing=()
    command -v pdftoppm  &>/dev/null || missing+=(pdftoppm)
    command -v pdftotext &>/dev/null || missing+=(pdftotext)
    command -v chafa     &>/dev/null || missing+=(chafa)
    [[ ${#missing[@]} -gt 0 ]] && {
        echo "Ошибка: не найдены: ${missing[*]}" >&2
        echo "Debian/Ubuntu: sudo apt-get install poppler-utils chafa" >&2
        echo "RHEL/Fedora:   sudo dnf install poppler-utils chafa" >&2
        echo "Arch:          sudo pacman -S poppler chafa" >&2
        echo "Alpine:        sudo apk add poppler-utils chafa" >&2
        exit 1
    }
}

PDF_FILE=""; TEXT_MODE=false; PAGE_NUM=""; WIDTH=$(tput cols 2>/dev/null || echo 120); DPI=150
while [[ $# -gt 0 ]]; do
    case "$1" in
        --text)   TEXT_MODE=true; shift ;;
        --page)   PAGE_NUM="$2"; shift 2 ;;
        --width)  WIDTH="$2"; shift 2 ;;
        --dpi)    DPI="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        -*)       echo "Неизвестная опция: $1" >&2; usage; exit 1 ;;
        *) [[ -z "$PDF_FILE" ]] && PDF_FILE="$1" || { echo "Лишний аргумент: $1" >&2; exit 1; }; shift ;;
    esac
done
[[ -z "$PDF_FILE" ]] && { usage; exit 1; }
[[ ! -f "$PDF_FILE" ]] && { echo "Файл не найден: $PDF_FILE" >&2; exit 1; }
check_deps

TOTAL_PAGES=$(pdfinfo "$PDF_FILE" 2>/dev/null | grep 'Pages:' | awk '{print $2}' || echo "?")

if [[ "$TEXT_MODE" == "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  📄  %s  [текст]  (страниц: %s)\n" "$(basename "$PDF_FILE")" "$TOTAL_PAGES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ -n "$PAGE_NUM" ]] && pdftotext -f "$PAGE_NUM" -l "$PAGE_NUM" "$PDF_FILE" - \
        || pdftotext "$PDF_FILE" -
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

render_page() {
    local page_n="$1"
    pdftoppm -r "$DPI" -f "$page_n" -l "$page_n" -png "$PDF_FILE" "${TMP_DIR}/page" 2>/dev/null
    local img; img=$(ls "${TMP_DIR}/page"*.png 2>/dev/null | head -1)
    [[ -z "$img" ]] && { echo "Ошибка рендеринга страницы ${page_n}" >&2; return 1; }
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  📄  %s  │  Страница %d из %s\n" "$(basename "$PDF_FILE")" "$page_n" "$TOTAL_PAGES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    chafa --size "${WIDTH}x9999" "$img"
    rm -f "$img"
}

if [[ -n "$PAGE_NUM" ]]; then
    render_page "$PAGE_NUM"
else
    current_page=1
    [[ "$TOTAL_PAGES" == "?" ]] && TOTAL_PAGES=999
    while true; do
        render_page "$current_page"
        echo ""
        echo -n "  [←/h назад | →/l вперёд | q выход | число: страница]: "
        read -r input </dev/tty
        case "$input" in
            q|Q) break ;;
            h|H|b|B) (( current_page > 1 )) && (( current_page-- )) ;;
            l|L|n|N) (( current_page < TOTAL_PAGES )) && (( current_page++ )) ;;
            [0-9]*)
                if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= TOTAL_PAGES )); then
                    current_page=$input
                fi ;;
        esac
    done
fi
SCRIPT
        chmod +x /usr/local/bin/view-pdf
        log_ok "Установлена утилита /usr/local/bin/view-pdf"
    else
        echo -e "  ${DIM}[dry-run] создан /usr/local/bin/view-pdf${RESET}"
    fi
}

# ─── 4. Конфигурация Bash ─────────────────────────────────────────────────────
configure_bash() {
    log_section "4 · Настройка Bash"

    local profile_d_file="/etc/profile.d/99-server-init.sh"

    log_step "Создаём глобальную конфигурацию bash"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p /etc/profile.d

        cat > "$profile_d_file" << 'BASHRC'
# ============================================================
#  /etc/profile.d/99-server-init.sh — Terminal Ergonomics
#  Загружается в интерактивных сессиях bash.
# ============================================================

# Только для интерактивных сессий bash
[ -z "${BASH_VERSION:-}" ] && return
[[ $- != *i* ]] && return

# Гарантируем наличие /usr/local/bin в PATH
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac

# ─── Редактор по умолчанию ───────────────────────────────────────────────────
export EDITOR="${EDITOR:-nano}"
export VISUAL="$EDITOR"
export STARSHIP_CONFIG="/etc/starship/starship.toml"

# ─── АЛИАСЫ БЫСТРОЙ НАВИГАЦИИ ────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias -- -='cd -'

# ─── «SUDO PLEASE» ───────────────────────────────────────────────────────────
alias please='sudo $(fc -ln -1)'

# ─── ls / eza / exa ──────────────────────────────────────────────────────────
if command -v eza &>/dev/null; then
    alias ls='eza --color=auto --group-directories-first --icons 2>/dev/null || ls --color=auto'
    alias ll='eza -alF --color=auto --group-directories-first --icons --git 2>/dev/null || ls -alF'
    alias la='eza -a --color=auto --icons 2>/dev/null || ls -a'
    alias lt='eza --tree --level=2 --icons 2>/dev/null || tree'
elif command -v exa &>/dev/null; then
    alias ls='exa --color=auto --group-directories-first 2>/dev/null || ls --color=auto'
    alias ll='exa -alF --color=auto --group-directories-first --git 2>/dev/null || ls -alF'
    alias la='exa -a --color=auto 2>/dev/null || ls -a'
else
    alias ls='ls --color=auto --group-directories-first'
    alias ll='ls -alFh --color=auto'
    alias la='ls -Ah --color=auto'
fi

# ─── Общие алиасы ────────────────────────────────────────────────────────────
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias cp='cp -i'
alias rm='rm -i'

# bat / batcat
if   command -v batcat &>/dev/null; then alias bat='batcat'; alias cat='batcat --paging=never'
elif command -v bat     &>/dev/null; then alias cat='bat --paging=never'
fi

# fd-find → fd
if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    alias fd='fdfind'
fi

# ─── ИСТОРИЯ BASH ────────────────────────────────────────────────────────────
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT='%F %T  '
shopt -s histappend

# ─── ГОРЯЧИЕ КЛАВИШИ ─────────────────────────────────────────────────────────
bind '"\e[A": history-search-backward' 2>/dev/null || true
bind '"\e[B": history-search-forward'  2>/dev/null || true
bind 'set completion-ignore-case on'   2>/dev/null || true
bind 'set show-all-if-ambiguous on'    2>/dev/null || true
bind 'set colored-stats on'            2>/dev/null || true

# ─── ОПЦИИ BASH ──────────────────────────────────────────────────────────────
shopt -s checkwinsize cdspell autocd globstar cmdhist 2>/dev/null || true

# ─── fzf ИНТЕГРАЦИЯ ──────────────────────────────────────────────────────────
if command -v fzf &>/dev/null; then
    for _fzf_init in \
        /usr/share/doc/fzf/examples/key-bindings.bash \
        /usr/share/fzf/key-bindings.bash \
        /usr/share/bash-completion/completions/fzf \
        ~/.fzf.bash; do
        [[ -f "$_fzf_init" ]] && source "$_fzf_init" && break
    done
    unset _fzf_init
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'
    export FZF_CTRL_R_OPTS='--sort --exact'
fi

# ─── ZOXIDE ──────────────────────────────────────────────────────────────────
command -v zoxide &>/dev/null && eval "$(zoxide init bash)"

# ─── STARSHIP ─────────────────────────────────────────────────────────────────
command -v starship &>/dev/null && eval "$(starship init bash)"

# ─── АЛИАСЫ ──────────────────────────────────────────────────────────────────
alias cheatsheet='/usr/local/bin/cheatsheet'

# ─── ФУНКЦИЯ mkcd ────────────────────────────────────────────────────────────
mkcd() { mkdir -p "$1" && cd "$1" || return 1; }

# ─── ФУНКЦИЯ extract ─────────────────────────────────────────────────────────
extract() {
    [[ -z "${1:-}" ]] && { echo "Использование: extract <файл>"; return 1; }
    [[ ! -f "$1" ]] && { echo "Файл не найден: $1"; return 1; }
    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1"  ;; *.tar.gz|*.tgz) tar xzf "$1"    ;;
        *.tar.xz|*.txz)   tar xJf "$1"  ;; *.tar.zst)       tar --zstd -xf "$1" ;;
        *.tar)             tar xf "$1"   ;; *.bz2)           bunzip2 "$1"    ;;
        *.gz)              gunzip "$1"   ;; *.xz)            unxz "$1"       ;;
        *.zip)             unzip "$1"    ;; *.7z)            7z x "$1"       ;;
        *.rar)             unrar x "$1" 2>/dev/null || 7z x "$1" ;;
        *) echo "Неизвестный формат: $1"; return 1 ;;
    esac
}

# ─── ФУНКЦИЯ myip ────────────────────────────────────────────────────────────
myip() {
    echo "── Внутренние IP ───────────────────────────────"
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | while read -r ip; do printf "  %s\n" "$ip"; done
    echo "── Внешний IP ──────────────────────────────────"
    curl -fsS --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null && echo || echo "  (нет доступа)"
}

# ─── ФУНКЦИЯ sysinfo ─────────────────────────────────────────────────────────
sysinfo() {
    echo "── Система ─────────────────────────────────────"
    printf "  %-16s %s\n" "Хост:"     "$(hostname -f 2>/dev/null || hostname)"
    printf "  %-16s %s\n" "ОС:"       "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
    printf "  %-16s %s\n" "Ядро:"     "$(uname -r)"
    printf "  %-16s %s\n" "Архит.:"   "$(uname -m)"
    printf "  %-16s %s\n" "Uptime:"   "$(uptime -p 2>/dev/null || uptime)"
    printf "  %-16s %s\n" "Нагрузка:" "$(cut -d' ' -f1-3 /proc/loadavg)"
    echo ""
    echo "── Память ──────────────────────────────────────"
    free -h 2>/dev/null | grep -E 'Mem|Swap' | while read -r l; do printf "  %s\n" "$l"; done
    echo ""
    echo "── Диск (/) ────────────────────────────────────"
    df -h / 2>/dev/null | tail -1 | awk '{printf "  Всего: %s | Занято: %s | Свободно: %s (%s)\n",$2,$3,$4,$5}'
}
BASHRC

        log_ok "Создан ${profile_d_file}"

        if [[ "$OS_FAMILY" == "debian" ]]; then
            mkdir -p /etc/bash.bashrc.d
            ln -sf "$profile_d_file" /etc/bash.bashrc.d/99-server-init.sh 2>/dev/null || \
                cp "$profile_d_file" /etc/bash.bashrc.d/99-server-init.sh

            if ! grep -q 'bash.bashrc.d' /etc/bash.bashrc 2>/dev/null; then
                cat >> /etc/bash.bashrc << 'EOF'

# Загрузка /etc/bash.bashrc.d/*.sh
if [[ -d /etc/bash.bashrc.d ]]; then
    for _f in /etc/bash.bashrc.d/*.sh; do [[ -r "$_f" ]] && source "$_f"; done
    unset _f
fi
EOF
                log_ok "Добавлена загрузка /etc/bash.bashrc.d в /etc/bash.bashrc"
            fi
        fi

        if [[ "$OS_FAMILY" == "rhel" ]]; then
            mkdir -p /etc/bashrc.d
            ln -sf "$profile_d_file" /etc/bashrc.d/99-server-init.sh 2>/dev/null || \
                cp "$profile_d_file" /etc/bashrc.d/99-server-init.sh

            if [[ -f /etc/bashrc ]] && ! grep -q 'bashrc.d' /etc/bashrc 2>/dev/null; then
                cat >> /etc/bashrc << 'EOF'

# Загрузка /etc/bashrc.d/*.sh
if [[ -d /etc/bashrc.d ]]; then
    for _f in /etc/bashrc.d/*.sh; do [[ -r "$_f" ]] && source "$_f"; done
    unset _f
fi
EOF
                log_ok "Добавлена загрузка /etc/bashrc.d в /etc/bashrc"
            fi
        fi
    else
        echo -e "  ${DIM}[dry-run] создан ${profile_d_file}${RESET}"
    fi
}

# ─── 5. Конфигурация Starship ─────────────────────────────────────────────────
configure_starship() {
    log_section "5 · Конфигурация Starship"

    local config_dir="/etc/starship"
    run mkdir -p "$config_dir"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "${config_dir}/starship.toml" << 'TOML'
format = """
$username$hostname$directory$git_branch$git_status$python$nodejs$rust$golang$java$cmd_duration
$character"""

[username]
show_always = false
style_user  = "bold green"
style_root  = "bold red"
format      = "[$user]($style)@"

[hostname]
ssh_only = true
format   = "[$hostname](bold cyan) "

[directory]
style              = "bold blue"
truncate_to_repo   = false
truncation_length  = 4
truncation_symbol  = "…/"
home_symbol        = "~"

[git_branch]
symbol = " "
style  = "bold purple"
format = "on [$symbol$branch]($style) "

[git_status]
format   = '([\[$all_status$ahead_behind\]]($style) )'
style    = "bold yellow"
ahead    = "↑${count}"
behind   = "↓${count}"
modified = "!"
staged   = "+"
untracked = "?"

[python]
symbol = "🐍 "
style  = "yellow bold"
format = "[$symbol$version]($style) "

[nodejs]
symbol = " "
style  = "green bold"
format = "[$symbol$version]($style) "

[rust]
symbol = "🦀 "
style  = "bold red"
format = "[$symbol$version]($style) "

[golang]
symbol = "🐹 "
style  = "bold cyan"
format = "[$symbol$version]($style) "

[cmd_duration]
min_time = 2000
format   = "took [$duration](bold yellow) "

[character]
success_symbol = "[❯](bold green)"
error_symbol   = "[❯](bold red)"

[time]
disabled    = false
format      = "[$time]($style) "
time_format = "%H:%M"
style       = "dimmed"
TOML
        log_ok "Конфигурация Starship: ${config_dir}/starship.toml"
    fi
}

# ─── 6. MOTD Cheatsheet ───────────────────────────────────────────────────────
install_motd() {
    log_section "6 · MOTD Cheatsheet"

    local cheatsheet_bin="/usr/local/bin/cheatsheet"

    if [[ "$DRY_RUN" != "true" ]]; then
        # Удаляем старый /etc/profile.d/99-cheatsheet.sh (если остался от прошлых версий),
        # чтобы он не дублировал MOTD и не ломал scp/rsync
        rm -f /etc/profile.d/99-cheatsheet.sh
        if [[ -f /etc/profile ]]; then
            sed -i '/99-cheatsheet/d' /etc/profile 2>/dev/null || true
        fi

        cat > "$cheatsheet_bin" << 'MOTD'
#!/usr/bin/env bash
# /usr/local/bin/cheatsheet — динамическая памятка при логине и по команде cheatsheet

RESET=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[2m'
RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'; CYAN=$'\e[0;36m'; MAGENTA=$'\e[0;35m'
WHITE=$'\e[1;37m'; BG_DARK=$'\e[48;5;235m'
I="  "

HOST=$(hostname -s 2>/dev/null || echo "?")
FQDN=$(hostname -f 2>/dev/null || echo "$HOST")
OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime)
LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?")
DATE_STR=$(date '+%A, %d %B %Y  %H:%M %Z')
TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "?")
MEM_INFO=$(free -h 2>/dev/null | awk 'NR==2{printf "%s / %s (своб. %s)",$3,$2,$4}')
SWAP_INFO=$(free -h 2>/dev/null | awk 'NR==3{if($2=="0B" || $2=="0")print "— не настроен"; else printf "%s / %s",$3,$2}')
DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s занято из %s (%s)",$3,$2,$5}')
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
USERS_N=$(who 2>/dev/null | wc -l || echo "?")
MY_IP=$(echo "${SSH_CLIENT:-}" | awk '{print $1}' 2>/dev/null); [[ -z "$MY_IP" ]] && MY_IP="local"
COLS=$(tput cols 2>/dev/null || echo 80)
(( COLS < 40 )) && COLS=80
LINE=$(printf '%*s' "$COLS" '' | tr ' ' '─')

echo ""
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
printf "${BOLD}${WHITE}${BG_DARK}  🖥  %-*s${RESET}\n" $(( COLS - 5 )) "  $FQDN  ·  $OS"
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
echo ""

printf "${BOLD}${YELLOW}${I}СИСТЕМА${RESET}\n"
printf "${I}${DIM}%-18s${RESET}%s\n" "Дата / Время:"  "$DATE_STR"
printf "${I}${DIM}%-18s${RESET}%s\n" "Таймзона:"      "$TIMEZONE"
printf "${I}${DIM}%-18s${RESET}%s\n" "Ядро:"          "$KERNEL  ($ARCH)"
printf "${I}${DIM}%-18s${RESET}%s\n" "Аптайм:"        "$UPTIME"
printf "${I}${DIM}%-18s${RESET}%s\n" "Нагрузка:"      "$LOAD"
printf "${I}${DIM}%-18s${RESET}%s\n" "Память:"        "$MEM_INFO"
printf "${I}${DIM}%-18s${RESET}%s\n" "Своп:"          "$SWAP_INFO"
printf "${I}${DIM}%-18s${RESET}%s\n" "Диск (/):"      "$DISK_INFO"
printf "${I}${DIM}%-18s${RESET}%s\n" "IP-сервера:"    "$LOCAL_IP"
printf "${I}${DIM}%-18s${RESET}%s\n" "Ваш IP:"        "$MY_IP"
printf "${I}${DIM}%-18s${RESET}%s\n" "Сессий:"        "$USERS_N"
echo ""
printf "${BOLD}${CYAN}${I}%s${RESET}\n" "$LINE"

printf "\n${BOLD}${GREEN}${I}📁  НАВИГАЦИЯ И АЛИАСЫ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" ".."            "cd .. (уровень вверх)"
printf "${I}%-24s${DIM}%s${RESET}\n" "..."           "cd ../.. (два уровня)"
printf "${I}%-24s${DIM}%s${RESET}\n" "-"             "вернуться в предыдущую директорию"
printf "${I}%-24s${DIM}%s${RESET}\n" "mkcd <dir>"    "mkdir + cd одной командой"
printf "${I}%-24s${DIM}%s${RESET}\n" "please"        "sudo <последняя команда>"

printf "\n${BOLD}${GREEN}${I}🚀  ZOXIDE — умный cd${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "z <часть_пути>" "перейти по частичному совпадению"
printf "${I}%-24s${DIM}%s${RESET}\n" "zi"             "интерактивный выбор через fzf"
printf "${I}%-24s${DIM}%s${RESET}\n" "Принцип:"       "ранжирует по частоте и давности посещений"

printf "\n${BOLD}${GREEN}${I}🔍  FZF — интерактивный поиск${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+R"         "поиск по истории команд"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+T"         "найти файл и вставить в строку"
printf "${I}%-24s${DIM}%s${RESET}\n" "Alt+C"          "перейти в директорию через fzf"

printf "\n${BOLD}${YELLOW}${I}⌨  ГОРЯЧИЕ КЛАВИШИ BASH${RESET}\n"
printf "${BOLD}${I}  Перемещение:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+A / Home"  "начало строки"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+E / End"   "конец строки"
printf "${I}%-24s${DIM}%s${RESET}\n" "Alt+B / Alt+F"  "назад/вперёд на слово"
printf "${BOLD}${I}  Редактирование:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+W"         "удалить слово слева"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+U / Ctrl+K" "удалить до начала/конца строки"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+Y"         "вставить удалённое (yank)"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+_"         "отменить (undo)"
printf "${BOLD}${I}  Продвинутые:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+X Ctrl+E"  "открыть строку в EDITOR"
printf "${I}%-24s${DIM}%s${RESET}\n" "Alt+."          "вставить последний аргумент"
printf "${I}%-24s${DIM}%s${RESET}\n" "Ctrl+L"         "очистить экран"

printf "\n${BOLD}${MAGENTA}${I}📊  МОНИТОРИНГ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "btop"           "CPU/RAM/диск/сеть — красивый TUI"
printf "${I}%-24s${DIM}%s${RESET}\n" "htop"           "классический top"
printf "${I}%-24s${DIM}%s${RESET}\n" "ncdu"           "визуализатор дискового пространства"
printf "${I}%-24s${DIM}%s${RESET}\n" "iotop"          "мониторинг I/O по процессам"
printf "${I}%-24s${DIM}%s${RESET}\n" "sysinfo"        "краткая системная сводка"
printf "${I}%-24s${DIM}%s${RESET}\n" "myip"           "внутренний и внешний IP"

printf "\n${BOLD}${MAGENTA}${I}🔎  ПОИСК${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "rg <паттерн>"   "ripgrep: поиск текста в файлах"
printf "${I}%-24s${DIM}%s${RESET}\n" "fd <имя>"       "fd-find: поиск файлов"
printf "${I}%-24s${DIM}%s${RESET}\n" "jq . file.json" "форматирование/парсинг JSON"

printf "\n${BOLD}${CYAN}${I}🖼  МЕДИА В ТЕРМИНАЛЕ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "chafa img.png"  "показать изображение в терминале"
printf "${I}%-24s${DIM}%s${RESET}\n" "view-pdf f.pdf" "просмотр PDF постранично"
printf "${I}%-24s${DIM}%s${RESET}\n" "view-pdf --text" "извлечь текстовый слой PDF"

printf "\n${BOLD}${BLUE}${I}🖥  TMUX${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "tmux"           "новая сессия"
printf "${I}%-24s${DIM}%s${RESET}\n" "tmux a -t имя"  "подключиться к существующей сессии"
printf "${I}%-24s${DIM}%s${RESET}\n" "Prefix = Ctrl+B" "префикс-клавиша tmux"
printf "${I}%-24s${DIM}%s${RESET}\n" 'Prefix + | / -' "разделить вертикально/горизонтально"
printf "${I}%-24s${DIM}%s${RESET}\n" "Prefix + d"     "detach (сессия остаётся жить)"

printf "\n${BOLD}${BLUE}${I}🛠  ФУНКЦИИ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n" "extract <файл>" "распаковать любой архив"
printf "${I}%-24s${DIM}%s${RESET}\n" "mkcd <папка>"   "mkdir + cd"
printf "${I}%-24s${DIM}%s${RESET}\n" "myip"           "все IP-адреса"
printf "${I}%-24s${DIM}%s${RESET}\n" "sysinfo"        "системная сводка"
printf "${I}%-24s${DIM}%s${RESET}\n" "cheatsheet"     "эта памятка"

printf "\n${BOLD}${CYAN}%s${RESET}\n" "$LINE"
printf "${DIM}${I}cheatsheet  │  sysinfo  │  /etc/profile.d/99-server-init.sh${RESET}\n"
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
echo ""
MOTD

        chmod 755 "$cheatsheet_bin"
        log_ok "Установлена команда: ${cheatsheet_bin}"

        if [[ "$OS_FAMILY" == "debian" ]]; then
            for f in /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news \
                     /etc/update-motd.d/80-esm /etc/update-motd.d/91-contract-ua-esm-status; do
                [[ -f "$f" && -x "$f" ]] && { chmod -x "$f"; log_info "Отключён шумный MOTD: $(basename "$f")"; }
            done
            mkdir -p /etc/update-motd.d
            ln -sf "$cheatsheet_bin" /etc/update-motd.d/99-cheatsheet
            rm -f /etc/profile.d/99-cheatsheet-login.sh
            log_ok "Подключён PAM MOTD: /etc/update-motd.d/99-cheatsheet"
        else
            cat > /etc/profile.d/99-cheatsheet-login.sh << 'LOGIN_HOOK'
# Вывод памятки один раз при интерактивном входе в терминал
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]] && [ -t 1 ] && [ -z "${SERVER_INIT_MOTD_SHOWN:-}" ]; then
    export SERVER_INIT_MOTD_SHOWN=1
    /usr/local/bin/cheatsheet
fi
LOGIN_HOOK
            chmod 644 /etc/profile.d/99-cheatsheet-login.sh
            log_ok "Подключён login-хук: /etc/profile.d/99-cheatsheet-login.sh"
        fi
    else
        echo -e "  ${DIM}[dry-run] создан ${cheatsheet_bin}${RESET}"
    fi
}

# ─── 7. Конфигурация tmux ─────────────────────────────────────────────────────
configure_tmux() {
    log_section "7 · Конфигурация tmux"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/tmux.conf << 'TMUX'
# /etc/tmux.conf — глобальная конфигурация tmux

set -g prefix C-b
bind-key C-a send-prefix
set -g base-index 1
setw -g pane-base-index 1

bind r source-file /etc/tmux.conf \; display "Конфиг перезагружен"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g history-limit 50000
set -g mouse on
set -sg escape-time 10
set -g renumber-windows on

set -g status-interval 5
set -g status-position bottom
set -g status-style "bg=#1e2030 fg=#c8d3f5"
set -g status-left "#[fg=#82aaff,bold] ❐ #S #[fg=#444a73]│ "
set -g status-right "#[fg=#444a73]│ #[fg=#c8d3f5]%H:%M #[fg=#444a73]│ #[fg=#82aaff]#{host_short} "
setw -g window-status-format " #I:#W "
setw -g window-status-current-format "#[fg=#82aaff,bold,bg=#2d3153] #I:#W #[default]"
set -g pane-border-style "fg=#444a73"
set -g pane-active-border-style "fg=#82aaff"

setw -g mode-keys vi
bind Enter copy-mode
bind -T copy-mode-vi v send-keys -X begin-selection
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
TMUX
        log_ok "Конфигурация tmux: /etc/tmux.conf"
    fi
}

# ─── 8. Конфигурация nano ─────────────────────────────────────────────────────
configure_nano() {
    log_section "8 · Конфигурация nano"
    command -v nano &>/dev/null || { log_skip "nano не установлен"; return 0; }

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/nanorc << 'NANO'
set autoindent
set tabsize 4
set tabstospaces
set linenumbers
set mouse
set smooth
set cutfromcursor
set casesensitive
set historylog
include "/usr/share/nano/*.nanorc"
NANO
        log_ok "Конфигурация nano: /etc/nanorc"
    fi
}

# ─── 9. SSH Hardening + Установка ключей ──────────────────────────────────────
install_ssh_keys_for_user() {
    local target_user="$1"
    local target_home="$2"
    [[ -z "$target_home" || ! -d "$target_home" ]] && return 0

    local ssh_dir="${target_home}/.ssh"
    local ak_file="${ssh_dir}/authorized_keys"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] обновление ${ak_file} для пользователя ${target_user}${RESET}"
        return 0
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$ak_file"

    local tmp_ak; tmp_ak=$(mktemp)

    if [[ "$REPLACE_KEYS" == "true" ]]; then
        log_info "Режим --replace-keys: очищаем старые ключи в ${ak_file}"
    elif [[ -s "$ak_file" ]]; then
        # Разделяем слипшиеся на одной строке ключи (например, после ключа хостера без \n)
        sed -E 's/([^\n])(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[^[:space:]]+|sk-(ssh|ecdsa)-[^[:space:]]+)/\1\n\2/g' "$ak_file" >> "$tmp_ak"
        echo "" >> "$tmp_ak"
    fi

    # Добавляем встроенные ключи
    for k in "${DEFAULT_SSH_KEYS[@]}"; do
        echo "$k" >> "$tmp_ak"
    done

    # Добавляем ключи, переданные через --ssh-key
    if [[ ${#EXTRA_SSH_KEYS[@]} -gt 0 ]]; then
        for k in "${EXTRA_SSH_KEYS[@]}"; do
            echo "$k" >> "$tmp_ak"
        done
    fi

    # Оставляем только валидные строки ключей и дедуплицируем по типу+телу ключа ($1 $2)
    grep -E '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-(ssh|ecdsa)-)[[:space:]]+[A-Za-z0-9+/=]+' "$tmp_ak" \
        | awk '!seen[$1" "$2]++' > "${ak_file}.clean" || true

    mv "${ak_file}.clean" "$ak_file"
    rm -f "$tmp_ak"
    chmod 600 "$ak_file"

    local target_group
    target_group=$(id -gn "$target_user" 2>/dev/null || echo "$target_user")
    chown -R "${target_user}:${target_group}" "$ssh_dir" 2>/dev/null || true

    local count; count=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$ak_file" 2>/dev/null || echo 0)
    log_ok "Пользователь ${target_user}: ${count} валидных SSH-ключей в ${ak_file}"
}

harden_ssh() {
    log_section "9 · SSH-ключи и Hardening"

    # 1. Устанавливаем SSH-ключи для root и (если запуск через sudo) для $SUDO_USER
    install_ssh_keys_for_user "root" "/root"

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local sudo_home
        sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "/home/${SUDO_USER}")
        if [[ -d "$sudo_home" ]]; then
            install_ssh_keys_for_user "$SUDO_USER" "$sudo_home"
        fi
    fi

    local sshd_cfg="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_cfg" ]] && { log_warn "sshd_config не найден — SSH-сервер не установлен"; return 0; }

    # Резервная копия
    if [[ ! -f "${sshd_cfg}.bak" ]]; then
        run cp "$sshd_cfg" "${sshd_cfg}.bak"
        log_ok "Резервная копия: ${sshd_cfg}.bak"
    else
        log_skip "Резервная копия ${sshd_cfg}.bak уже существует"
    fi

    local root_keys="/root/.ssh/authorized_keys"
    local key_count=2
    if [[ "$DRY_RUN" != "true" ]]; then
        key_count=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$root_keys" 2>/dev/null || echo 0)
    fi

    if (( key_count == 0 )); then
        log_warn "ВНИМАНИЕ: нет валидных ключей в ${root_keys}!"
        log_warn "Пропускаем отключение паролей во избежание потери доступа."
        return 0
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        # Если поддерживается /etc/ssh/sshd_config.d — пишем приоритетный 00-server-init.conf,
        # так как в OpenSSH побеждает ПЕРВАЯ встреченная директива (иначе 50-cloud-init.conf
        # с PasswordAuthentication yes переопределит конец основного sshd_config).
        if [[ -d /etc/ssh/sshd_config.d ]]; then
            # Отключаем PasswordAuthentication yes в сторонних cloud-init drop-in файлах
            for dropin in /etc/ssh/sshd_config.d/*.conf; do
                [[ ! -f "$dropin" || "$(basename "$dropin")" == "00-server-init.conf" ]] && continue
                if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$dropin" 2>/dev/null; then
                    sed -i -E 's/^[[:space:]]*(PasswordAuthentication[[:space:]]+yes)/# overridden by 00-server-init.conf: \1/I' "$dropin" 2>/dev/null || true
                    log_info "Отключён PasswordAuthentication yes в $(basename "$dropin")"
                fi
            done

            cat > /etc/ssh/sshd_config.d/00-server-init.conf << 'SSHD_DROPIN'
# /etc/ssh/sshd_config.d/00-server-init.conf — создано server-init.sh
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
KbdInteractiveAuthentication no
X11Forwarding no
PrintMotd no
MaxAuthTries 2
MaxSessions 10
MaxStartups 3:50:10
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 20
LogLevel VERBOSE
SSHD_DROPIN
            chmod 644 /etc/ssh/sshd_config.d/00-server-init.conf
            log_ok "Создан приоритетный конфиг: /etc/ssh/sshd_config.d/00-server-init.conf"
        fi

        sshd_set() {
            local d="$1" v="$2"
            if grep -qE "^#?[[:space:]]*${d}[[:space:]]" "$sshd_cfg"; then
                sed -i -E "s|^#?[[:space:]]*${d}[[:space:]].*|${d} ${v}|" "$sshd_cfg"
            else
                echo "${d} ${v}" >> "$sshd_cfg"
            fi
        }

        sshd_set "PermitRootLogin"              "prohibit-password"
        sshd_set "PasswordAuthentication"       "no"
        sshd_set "PubkeyAuthentication"         "yes"
        sshd_set "AuthorizedKeysFile"           ".ssh/authorized_keys"
        sshd_set "PermitEmptyPasswords"         "no"
        sshd_set "KbdInteractiveAuthentication" "no"
        sshd_set "X11Forwarding"                "no"
        sshd_set "PrintMotd"                    "no"
        sshd_set "MaxAuthTries"                 "2"
        sshd_set "MaxSessions"                  "10"
        sshd_set "MaxStartups"                  "3:50:10"
        sshd_set "ClientAliveInterval"          "300"
        sshd_set "ClientAliveCountMax"          "2"
        sshd_set "LoginGraceTime"               "20"
        sshd_set "LogLevel"                     "VERBOSE"

        if sshd -t 2>/dev/null; then
            svc_reload "$SSH_SERVICE"
            log_ok "SSH перезагружен: пароли отключены, только ключи"
        else
            log_error "Ошибка синтаксиса sshd_config — откат"
            rm -f /etc/ssh/sshd_config.d/00-server-init.conf
            cp "${sshd_cfg}.bak" "$sshd_cfg"
            return 1
        fi
    else
        echo -e "  ${DIM}[dry-run] настройка /etc/ssh/sshd_config.d/00-server-init.conf и ${sshd_cfg}${RESET}"
    fi

    log_ok "SSH hardening применён"
    log_info "PermitRootLogin: prohibit-password | PasswordAuthentication: no"
    log_info "MaxAuthTries: 2 | MaxStartups: 3:50:10 | LoginGraceTime: 20s"
}

# ─── 10. Fail2ban + Recidive (анти-ботнет конфигурация) ───────────────────────
install_fail2ban() {
    log_section "10 · Fail2ban (SSH Aggressive + Incremental Ban + Recidive)"

    [[ "$SKIP_PACKAGES" == "true" ]] && { log_warn "Пропущено (--skip-packages)"; return 0; }

    if [[ "$OS_FAMILY" == "alpine" ]]; then
        log_info "Alpine: используем sshguard для OpenRC"
        pkg_install sshguard && svc_enable sshguard && svc_start sshguard \
            && log_ok "sshguard установлен и запущен" \
            || log_warn "sshguard: недоступен"
        return 0
    fi

    if command -v fail2ban-client &>/dev/null; then
        log_skip "fail2ban уже установлен ($(fail2ban-client --version 2>/dev/null | head -1))"
    else
        log_step "Устанавливаем fail2ban..."
        pkg_install fail2ban || { log_error "Не удалось установить fail2ban"; return 1; }
        log_ok "fail2ban установлен"
    fi

    # На Debian/Ubuntu для работы backend = systemd необходим python3-systemd
    if [[ "$OS_FAMILY" == "debian" && "$HAS_SYSTEMD" == "true" ]]; then
        pkg_install python3-systemd 2>/dev/null || true
    fi

    # Гарантируем наличие firewall-бэкенда (nftables или iptables)
    if ! command -v nft &>/dev/null && ! command -v iptables &>/dev/null; then
        pkg_install nftables 2>/dev/null || pkg_install iptables 2>/dev/null || true
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        # 1. Выбираем нативный banaction (nftables предпочтительнее на современных ядрах)
        local f2b_banaction="iptables-multiport"
        local f2b_banaction_all="iptables-allports"
        if command -v nft &>/dev/null && [[ -f /etc/fail2ban/action.d/nftables-multiport.conf || -f /etc/fail2ban/action.d/nftables.conf ]]; then
            f2b_banaction="nftables-multiport"
            f2b_banaction_all="nftables-allports"
            log_info "Fail2ban firewall backend: nftables (${f2b_banaction})"
        else
            log_info "Fail2ban firewall backend: iptables (${f2b_banaction})"
        fi

        # 2. Выбираем backend чтения логов для sshd (systemd journal vs файл)
        local sshd_log_block=""
        if [[ "$HAS_SYSTEMD" == "true" ]] && python3 -c "import systemd.journal" 2>/dev/null; then
            sshd_log_block="backend  = systemd"
            log_info "Fail2ban sshd log backend: systemd journal"
        elif [[ -f /var/log/auth.log ]]; then
            sshd_log_block=$'backend  = auto\nlogpath  = /var/log/auth.log'
            log_info "Fail2ban sshd log backend: /var/log/auth.log"
        elif [[ -f /var/log/secure ]]; then
            sshd_log_block=$'backend  = auto\nlogpath  = /var/log/secure'
            log_info "Fail2ban sshd log backend: /var/log/secure"
        else
            touch /var/log/auth.log 2>/dev/null || true
            sshd_log_block=$'backend  = auto\nlogpath  = /var/log/auth.log'
            log_info "Fail2ban sshd log backend: /var/log/auth.log (создан)"
        fi

        # 3. Проверяем поддержку mode = aggressive в фильтре sshd.conf
        local sshd_mode_line=""
        if grep -q "mode" /etc/fail2ban/filter.d/sshd.conf 2>/dev/null; then
            sshd_mode_line="mode     = aggressive"
        fi

        # ВАЖНО: fail2ban НЕ поддерживает inline-комментарии (# ...) после значений!
        cat > /etc/fail2ban/jail.local << F2B
# /etc/fail2ban/jail.local — создано server-init.sh
# Внимание: НЕ используйте inline-комментарии (# ...) на одной строке со значениями!

[DEFAULT]
bantime            = 4h
findtime           = 1h
maxretry           = 3
bantime.increment  = true
bantime.rndtime    = 15m
bantime.factor     = 2
bantime.maxtime    = 5w
banaction          = ${f2b_banaction}
banaction_allports = ${f2b_banaction_all}
backend            = auto
usedns             = warn
logencoding        = utf-8
enabled            = false

# ─── SSH (защита от распределённых и медленных ботнетов) ──────────────────────
# При отключённом парольном входе 2 ошибки подряд за 1 час = гарантированный бот
[sshd]
enabled  = true
port     = ssh
filter   = sshd
${sshd_mode_line}
${sshd_log_block}
maxretry = 2
findtime = 1h
bantime  = 4h

# ─── RECIDIVE (блокировка рецидивистов по всем портам) ────────────────────────
# 3 бана за 7 дней → полная блокировка всех портов на 4 недели
[recidive]
enabled   = true
filter    = recidive
backend   = auto
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime   = 4w
findtime  = 7d
maxretry  = 3
F2B

        log_ok "Создан /etc/fail2ban/jail.local (mode=aggressive, maxretry=2, bantime.increment=true)"

        touch /var/log/fail2ban.log 2>/dev/null || true

        if [[ ! -f /etc/fail2ban/filter.d/recidive.conf ]]; then
            cat > /etc/fail2ban/filter.d/recidive.conf << 'RECIDIVE'
[Definition]
failregex = ^%(__prefix_line)s(?:NOTICE  |WARNING |CRITICAL)?(?:\[\d+\])? Ban <HOST>$
ignoreregex =
RECIDIVE
            log_ok "Создан фильтр recidive.conf"
        fi

        if ! fail2ban-client -t >/dev/null 2>&1; then
            log_warn "Проверка fail2ban-client -t выявила предупреждение — проверяем вывод:"
            fail2ban-client -t 2>&1 | tail -5 | while read -r line; do log_info "  $line"; done || true
        fi

        svc_enable fail2ban
        svc_restart fail2ban
        sleep 2

        if svc_is_active fail2ban; then
            log_ok "fail2ban запущен и включён в автозагрузку"
        else
            log_warn "fail2ban не запустился — последние строки лога:"
            journalctl -u fail2ban --no-pager -n 15 2>/dev/null \
                | grep -v "^--" | tail -10 \
                | while read -r line; do echo -e "  ${RED}│${RESET} ${DIM}${line}${RESET}"; done || true
        fi

        sleep 1
        log_info "Статус джейлов:"
        fail2ban-client status 2>/dev/null | grep -E 'Jail|Number' \
            | while read -r line; do log_info "  $line"; done || true
    else
        echo -e "  ${DIM}[dry-run] создан /etc/fail2ban/jail.local (aggressive sshd + recidive)${RESET}"
    fi

    log_info "fail2ban-client status          — список джейлов"
    log_info "fail2ban-client status sshd     — SSH-джейл"
    log_info "fail2ban-client status recidive — рецидивисты"
    log_info "fail2ban-client set sshd unbanip <IP> — разбанить"
}

# ─── 11. Итоговая проверка ────────────────────────────────────────────────────
verify_installation() {
    log_section "11 · Итоговая проверка"

    local tools=(
        "btop:btop --version"
        "htop:htop --version"
        "ncdu:ncdu --version"
        "rg (ripgrep):rg --version"
        "fzf:fzf --version"
        "jq:jq --version"
        "tmux:tmux -V"
        "chafa:chafa --version"
        "pdftoppm:pdftoppm -v"
        "pdftotext:pdftotext -v"
        "view-pdf:view-pdf --help"
        "cheatsheet:cheatsheet --help"
        "starship:starship --version"
        "zoxide:zoxide --version"
        "fail2ban:fail2ban-client --version"
    )

    printf "  %-18s  %-8s  %s\n" "УТИЛИТА" "СТАТУС" "ВЕРСИЯ"
    printf "  %s\n" "$(printf '%0.s─' {1..55})"

    for entry in "${tools[@]}"; do
        local name="${entry%%:*}"
        local cmd="${entry#*:}"
        local bin; bin=$(echo "$cmd" | awk '{print $1}')

        if command -v "$bin" &>/dev/null; then
            local ver="ok"
            if [[ "$bin" != "cheatsheet" && "$bin" != "view-pdf" ]]; then
                ver=$(eval "$cmd" 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "ok")
            fi
            printf "  ${GREEN}✔${RESET}  %-16s  ${DIM}%-8s${RESET}  %s\n" "$name" "OK" "$ver"
        else
            printf "  ${RED}✘${RESET}  %-16s  ${RED}%-8s${RESET}\n" "$name" "MISSING"
        fi
    done

    echo ""
    local configs=(
        "/etc/profile.d/99-server-init.sh"
        "/usr/local/bin/cheatsheet"
        "/usr/local/bin/view-pdf"
        "/etc/tmux.conf"
        "/etc/starship/starship.toml"
        "/etc/sysctl.d/99-server-init.conf"
        "/etc/ssh/sshd_config.bak"
    )
    printf "  %-44s  %s\n" "КОНФИГ" "СТАТУС"
    printf "  %s\n" "$(printf '%0.s─' {1..55})"
    for cfg in "${configs[@]}"; do
        if [[ -f "$cfg" ]]; then
            printf "  ${GREEN}✔${RESET}  %-42s  ${DIM}OK${RESET}\n" "$cfg"
        else
            printf "  ${RED}✘${RESET}  %-42s  ${RED}MISSING${RESET}\n" "$cfg"
        fi
    done
}

# ─── Финальное сообщение ──────────────────────────────────────────────────────
print_summary() {
    log_section "✅ Инициализация завершена"

    cat << 'SUMMARY'

  Что было настроено:
  ┌─────────────────────────────────────────────────────────────────────┐
  │  1.  Таймзона → Europe/Moscow, NTP, лимит journald (200 МБ)        │
  │  2.  Локали: LANG=en_US.UTF-8 + ru_RU.UTF-8                        │
  │  3.  Авто-Swap (2 ГБ при RAM ≤ 4 ГБ) + TCP BBR и sysctl-тюнинг      │
  │  4.  Дополнительные репозитории (EPEL/backports/community)          │
  │  5.  CLI-стек: btop, htop, ncdu, rg, fd, jq, tmux, fzf, zoxide     │
  │  6.  Промпт starship с git, языками и временем выполнения           │
  │  7.  view-pdf + chafa: просмотр PDF и изображений в терминале       │
  │  8.  MOTD cheatsheet при логине + команда /usr/local/bin/cheatsheet │
  │  9.  Глобальный profile.d: алиасы, горячие клавиши, функции        │
  │  10. Конфигурация tmux с vim-клавишами и статусной строкой          │
  │  11. SSH-ключи (2 ключа) + SSH hardening (только по ключам)         │
  │  12. fail2ban: sshd (aggressive, maxretry=2, increment) + recidive  │
  └─────────────────────────────────────────────────────────────────────┘

SUMMARY

    echo -e "  ${BOLD}${GREEN}Следующие шаги:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Перезайдите в SSH или выполните: ${BOLD}source /etc/profile${RESET}"
    echo -e "  ${CYAN}2.${RESET} Вызовите памятку:                ${BOLD}cheatsheet${RESET}"
    echo -e "  ${CYAN}3.${RESET} Проверьте промпт starship:       ${BOLD}exec bash${RESET}"
    echo -e "  ${CYAN}4.${RESET} Статус fail2ban:                 ${BOLD}fail2ban-client status sshd${RESET}"
    echo -e "  ${CYAN}5.${RESET} Проверка TCP BBR:                ${BOLD}sysctl net.ipv4.tcp_congestion_control${RESET}"
    echo ""
    echo -e "  ${BOLD}${RED}⚠  ВАЖНО:${RESET} SSH-пароли отключены, ваши публичные ключи добавлены в"
    echo -e "     ${BOLD}~/.ssh/authorized_keys${RESET}. Проверьте вход в новом окне терминала"
    echo -e "     до закрытия текущей сессии!"
    echo ""
}

# ─── Главная точка входа ──────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║   🛠  server-init.sh — инициализация Linux-сервера       ║"
    echo "  ║   Universal Linux Setup · All Major Distros              ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    [[ "$DRY_RUN" == "true" ]] && echo -e "  ${YELLOW}⚠  РЕЖИМ DRY-RUN: реальных изменений не будет${RESET}\n"

    preflight_checks
    setup_system
    setup_swap
    setup_sysctl
    setup_extra_repos
    install_packages
    install_view_pdf
    configure_bash
    configure_starship
    install_motd
    configure_tmux
    configure_nano
    harden_ssh
    install_fail2ban
    verify_installation
    print_summary
}

main "$@"
