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
#    sudo bash server-init.sh [--dry-run] [--skip-packages] [--help]
#
#  Идемпотентность: скрипт безопасно запускать повторно.
# ==============================================================================

set -euo pipefail

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

for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=true ;;
        --skip-packages) SKIP_PACKAGES=true ;;
        --help|-h)
            echo "Использование: sudo bash server-init.sh [--dry-run] [--skip-packages]"
            echo "  --dry-run        Показать что будет сделано без реальных изменений"
            echo "  --skip-packages  Пропустить установку пакетов (только конфиги)"
            exit 0 ;;
        *) die "Неизвестный аргумент: $arg. Используйте --help." ;;
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
OS_CODENAME=""  # bullseye, jammy, ...
OS_VERSION=""   # основная версия (8, 9, 22...)
OS_PRETTY=""    # красивое название для вывода
PKG_MGR=""      # apt | dnf | yum | pacman | apk | zypper
HAS_SYSTEMD=true
SSH_SERVICE="ssh"   # ssh (Debian) или sshd (остальные)

# ─── 0. Определение дистрибутива ─────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        OS_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "")
        OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1 2>/dev/null || echo "")
        OS_PRETTY=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "$OS_ID")
        # ID_LIKE помогает с производными дистрибутивами
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
            # Определяем по наличию пакетного менеджера
            if   command -v apt-get &>/dev/null; then OS_FAMILY="debian"; PKG_MGR="apt";    SSH_SERVICE="ssh"
            elif command -v dnf     &>/dev/null; then OS_FAMILY="rhel";   PKG_MGR="dnf";    SSH_SERVICE="sshd"
            elif command -v yum     &>/dev/null; then OS_FAMILY="rhel";   PKG_MGR="yum";    SSH_SERVICE="sshd"
            elif command -v pacman  &>/dev/null; then OS_FAMILY="arch";   PKG_MGR="pacman"; SSH_SERVICE="sshd"
            elif command -v apk     &>/dev/null; then OS_FAMILY="alpine"; PKG_MGR="apk";    SSH_SERVICE="sshd"; HAS_SYSTEMD=false
            elif command -v zypper  &>/dev/null; then OS_FAMILY="suse";   PKG_MGR="zypper"; SSH_SERVICE="sshd"
            else OS_FAMILY="unknown"; PKG_MGR="unknown"
            fi ;;
    esac

    # Проверяем наличие systemd
    if ! command -v systemctl &>/dev/null; then
        HAS_SYSTEMD=false
    fi
}

# ─── Абстракция пакетного менеджера ──────────────────────────────────────────
pkg_update() {
    case "$PKG_MGR" in
        apt)    apt-get update -qq ;;
        dnf)    dnf makecache -q --refresh 2>/dev/null || dnf check-update -q 2>/dev/null || true ;;
        yum)    yum makecache -q 2>/dev/null || true ;;
        pacman) pacman -Sy --noconfirm --quiet 2>/dev/null ;;
        apk)    apk update -q ;;
        zypper) zypper refresh -q 2>/dev/null ;;
    esac
}

pkg_install() {
    # Устанавливает один пакет, возвращает 0 при успехе
    local pkg="$1"
    case "$PKG_MGR" in
        apt)    apt-get install -y -qq "$pkg" 2>/dev/null ;;
        dnf)    dnf install -y -q "$pkg" 2>/dev/null ;;
        yum)    yum install -y -q "$pkg" 2>/dev/null ;;
        pacman) pacman -S --noconfirm --needed --quiet "$pkg" 2>/dev/null ;;
        apk)    apk add -q "$pkg" 2>/dev/null ;;
        zypper) zypper install -y -q "$pkg" 2>/dev/null ;;
        *)      return 1 ;;
    esac
}

pkg_install_many() {
    # Устанавливает список пакетов, пропуская недоступные
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
        # Alpine: OpenRC
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
        run rc-service "$svc" reload 2>/dev/null || true
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

    [[ $EUID -ne 0 ]] && die "Скрипт должен быть запущен с правами root: sudo bash $0"
    log_ok "Запущен от root"

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

    local free_kb; free_kb=$(df /usr --output=avail 2>/dev/null | tail -1 || df / --output=avail | tail -1)
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
            run timedatectl set-timezone Europe/Moscow
        else
            # Alpine / без systemd
            run ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
            echo "Europe/Moscow" | run tee /etc/timezone > /dev/null
        fi
        log_ok "Таймзона → Europe/Moscow"
    fi

    # ── NTP ──────────────────────────────────────────────────────────────────
    log_step "Настраиваем синхронизацию времени"
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        # systemd-timesyncd (Debian/Ubuntu/Arch/RHEL с systemd)
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

    # ── Локали ───────────────────────────────────────────────────────────────
    log_step "Настраиваем локали (en_US.UTF-8 + ru_RU.UTF-8)"
    case "$OS_FAMILY" in
        debian)
            if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
                if [[ -f /etc/locale.gen ]]; then
                    run sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
                    run sed -i 's/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
                    run locale-gen
                fi
            else
                log_skip "Локаль en_US.UTF-8 уже сгенерирована"
            fi
            run update-locale LANG=en_US.UTF-8 2>/dev/null || true
            ;;
        rhel)
            # RHEL/Fedora: установить langpack если нет
            if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
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
            # Alpine использует musl — нет полного locale support
            log_info "Alpine Linux: ограниченная поддержка локалей (musl libc)"
            [[ "$DRY_RUN" != "true" ]] && { mkdir -p /etc/profile.d; echo 'export LANG=en_US.UTF-8'; } > /etc/profile.d/locale.sh
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

# ─── 1б. Дополнительные репозитории ──────────────────────────────────────────
setup_extra_repos() {
    log_section "1б · Настройка репозиториев"

    case "$OS_FAMILY" in
        # ── Debian: contrib, non-free, backports ──────────────────────────────
        debian)
            local src="/etc/apt/sources.list"
            local changed=false
            local codename="$OS_CODENAME"
            [[ -z "$codename" ]] && codename=$(lsb_release -sc 2>/dev/null || echo "")
            [[ -z "$codename" ]] && { log_skip "Не удалось определить codename — пропускаем backports"; return 0; }
            log_info "Debian/Ubuntu codename: ${codename}"

            if [[ "$DRY_RUN" != "true" ]]; then
                # non-free
                if grep -q "^deb " "$src" 2>/dev/null && ! grep -q "non-free" "$src" 2>/dev/null; then
                    sed -i '/^deb http.*debian\.org\/debian[[:space:]]/ s/$/ contrib non-free/' "$src" 2>/dev/null || true
                    changed=true; log_ok "Добавлены contrib non-free"
                fi
                # security
                if ! grep -qE "^deb.*security" "$src" 2>/dev/null; then
                    echo "deb http://security.debian.org/debian-security ${codename}-security main contrib non-free" >> "$src"
                    changed=true; log_ok "Добавлен ${codename}-security"
                fi
                # backports (для chafa, bat, более новые версии)
                if ! grep -q "backports" "$src" 2>/dev/null; then
                    echo "deb http://deb.debian.org/debian ${codename}-backports main contrib non-free" >> "$src"
                    changed=true; log_ok "Добавлены ${codename}-backports"
                fi
                [[ "$changed" == "true" ]] && { apt-get update -qq; log_ok "apt-get update после обновления источников"; } \
                    || log_skip "Источники уже настроены"
            else
                echo -e "  ${DIM}[dry-run] настройка /etc/apt/sources.list${RESET}"
            fi
            ;;

        # ── RHEL/CentOS: EPEL + PowerTools/CRB ───────────────────────────────
        rhel)
            log_step "Подключаем EPEL и CRB для RHEL-семейства..."
            if ! rpm -q epel-release &>/dev/null 2>&1; then
                if [[ "$OS_ID" == "amzn" ]]; then
                    pkg_install "amazon-linux-extras" && run amazon-linux-extras install epel -y 2>/dev/null || true
                elif (( OS_VERSION >= 9 )); then
                    pkg_install "epel-release"
                    # CRB (CodeReady Builder) заменил PowerTools в RHEL9
                    run dnf config-manager --set-enabled crb 2>/dev/null || \
                    run dnf config-manager --set-enabled powertools 2>/dev/null || true
                else
                    pkg_install "epel-release"
                    run dnf config-manager --set-enabled powertools 2>/dev/null || \
                    run yum-config-manager --enable powertools 2>/dev/null || true
                fi
                log_ok "EPEL подключён"
                run pkg_update
            else
                log_skip "EPEL уже установлен"
            fi
            ;;

        # ── Arch: multilib (опционально) ──────────────────────────────────────
        arch)
            log_skip "Arch Linux: основные репозитории уже включены"
            ;;

        # ── Alpine: community и edge testing ─────────────────────────────────
        alpine)
            if ! grep -q "community" /etc/apk/repositories 2>/dev/null; then
                local alpine_ver; alpine_ver=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1-2 || echo "edge")
                if [[ "$DRY_RUN" != "true" ]]; then
                    echo "https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community" >> /etc/apk/repositories
                    run apk update -q
                    log_ok "Alpine community репозиторий добавлен"
                fi
            else
                log_skip "Alpine community уже настроен"
            fi
            ;;

        # ── openSUSE: дополнительные репозитории ──────────────────────────────
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

    # ── Базовые зависимости (специфичны для каждого семейства) ───────────────
    local base_deps=()
    case "$OS_FAMILY" in
        debian)
            base_deps=(curl wget git ca-certificates gnupg apt-transport-https
                       build-essential unzip poppler-utils) ;;
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

    # ── CLI-утилиты (универсальные имена пакетов) ─────────────────────────────
    # Для пакетов с разными именами используем resolve_pkg()
    local cli_common=(htop ncdu jq tmux tree file lsof strace pv bc rsync socat)
    pkg_install_many "Общие утилиты" "${cli_common[@]}"

    # ripgrep
    case "$OS_FAMILY" in
        debian|rhel|arch|alpine|suse) pkg_install ripgrep || log_warn "ripgrep: недоступен" ;;
    esac

    # fd-find (разные имена)
    case "$OS_FAMILY" in
        debian)  pkg_install fd-find  || log_warn "fd-find: недоступен" ;;
        arch)    pkg_install fd       || log_warn "fd: недоступен" ;;
        alpine)  pkg_install fd       || log_warn "fd: недоступен" ;;
        rhel)    pkg_install fd-find  || pkg_install fd || log_warn "fd: недоступен (попробуйте вручную)" ;;
        suse)    pkg_install fd       || log_warn "fd: недоступен" ;;
    esac

    # bat — разные имена
    case "$OS_FAMILY" in
        debian)
            if ! pkg_install bat 2>/dev/null; then
                pkg_install batcat 2>/dev/null || log_warn "bat: недоступен"
            fi ;;
        rhel|arch|alpine|suse) pkg_install bat || log_warn "bat: недоступен" ;;
    esac

    # chafa — рендеринг изображений
    case "$OS_FAMILY" in
        debian)  pkg_install chafa || log_warn "chafa: недоступен (нет в Debian 11, добавьте backports)" ;;
        rhel)    pkg_install chafa || log_warn "chafa: недоступен (нет в EPEL)" ;;
        arch)    pkg_install chafa || log_warn "chafa: недоступен" ;;
        alpine)  pkg_install chafa || log_warn "chafa: недоступен" ;;
        suse)    pkg_install chafa || log_warn "chafa: недоступен" ;;
    esac

    # DNS утилиты (разные имена)
    case "$OS_FAMILY" in
        debian)  pkg_install dnsutils   || log_warn "dnsutils: недоступен" ;;
        rhel)    pkg_install bind-utils || log_warn "bind-utils: недоступен" ;;
        arch)    pkg_install bind       || log_warn "bind: недоступен" ;;
        alpine)  pkg_install bind-tools || log_warn "bind-tools: недоступен" ;;
        suse)    pkg_install bind-utils || log_warn "bind-utils: недоступен" ;;
    esac

    # mtr, iotop, sysstat
    pkg_install mtr    || log_warn "mtr: недоступен"
    pkg_install iotop  || log_warn "iotop: недоступен"
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

    # eza / exa — современная замена ls
    case "$OS_FAMILY" in
        debian|rhel|suse)
            if ! pkg_install eza 2>/dev/null; then
                pkg_install exa 2>/dev/null || log_info "eza/exa: недоступен, используем ls"
            fi ;;
        arch)   pkg_install eza || pkg_install exa || log_info "eza: недоступен" ;;
        alpine) pkg_install eza 2>/dev/null || log_info "eza: недоступен в Alpine" ;;
    esac

    # net-tools
    pkg_install net-tools || log_warn "net-tools: недоступен"

    log_ok "Установка CLI-утилит завершена"

    # ── btop, fzf, zoxide, starship ──────────────────────────────────────────
    install_btop
    install_fzf
    install_zoxide
    install_starship
}

install_btop() {
    command -v btop &>/dev/null && { log_skip "btop уже установлен ($(btop --version 2>/dev/null | head -1))"; return 0; }
    log_step "Устанавливаем btop..."

    pkg_install btop && { log_ok "btop установлен через ${PKG_MGR}"; return 0; }

    # backports (Debian)
    [[ "$OS_FAMILY" == "debian" ]] && apt-get install -y -qq -t "*-backports" btop 2>/dev/null && {
        log_ok "btop установлен из backports"; return 0; }

    # GitHub API
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
        | head -1 | cut -d'"' -f4)

    [[ -z "$btop_url" ]] && { log_warn "btop: не удалось получить URL из GitHub API"; return 0; }

    local tmp_dir; tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN
    local ext="tbz"; [[ "$btop_url" == *".tar.bz2" ]] && ext="tar.bz2"

    if curl -fsSL "$btop_url" -o "${tmp_dir}/btop.${ext}"; then
        tar -xjf "${tmp_dir}/btop.${ext}" -C "$tmp_dir"
        local btop_bin; btop_bin=$(find "$tmp_dir" -name btop -type f | head -1)
        if [[ -n "$btop_bin" ]]; then
            install -Dm755 "$btop_bin" /usr/local/bin/btop
            log_ok "btop установлен из GitHub release"
        fi
    else
        log_warn "btop: не удалось загрузить"
    fi
}

install_fzf() {
    command -v fzf &>/dev/null && { log_skip "fzf уже установлен ($(fzf --version 2>/dev/null))"; return 0; }
    log_step "Устанавливаем fzf..."
    pkg_install fzf && { log_ok "fzf установлен через ${PKG_MGR}"; return 0; }

    # Официальный скрипт
    if [[ "$DRY_RUN" != "true" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git /tmp/fzf-install 2>/dev/null || true
        if [[ -d /tmp/fzf-install ]]; then
            bash /tmp/fzf-install/install --bin 2>/dev/null
            [[ -f /tmp/fzf-install/bin/fzf ]] && install -Dm755 /tmp/fzf-install/bin/fzf /usr/local/bin/fzf
            rm -rf /tmp/fzf-install
            log_ok "fzf установлен из GitHub"
        fi
    fi
}

install_zoxide() {
    command -v zoxide &>/dev/null && { log_skip "zoxide уже установлен ($(zoxide --version 2>/dev/null))"; return 0; }
    log_step "Устанавливаем zoxide..."
    pkg_install zoxide && { log_ok "zoxide установлен через ${PKG_MGR}"; return 0; }

    if run curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash; then
        log_ok "zoxide установлен через официальный скрипт"
    else
        log_warn "zoxide: не удалось установить"
    fi
}

install_starship() {
    command -v starship &>/dev/null && { log_skip "starship уже установлен ($(starship --version 2>/dev/null | head -1))"; return 0; }
    log_step "Устанавливаем starship..."

    # Arch: из репозитория
    [[ "$OS_FAMILY" == "arch" ]] && pkg_install starship && { log_ok "starship установлен через pacman"; return 0; }

    if run curl -fsSL https://starship.rs/install.sh | sh -s -- --yes; then
        log_ok "starship установлен"
    else
        log_warn "starship: не удалось установить"
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

    # Универсальное расположение для всех дистрибутивов: /etc/profile.d/
    # + отдельно /etc/bash.bashrc.d/ для Debian-совместимых
    local profile_d_file="/etc/profile.d/99-server-init.sh"

    log_step "Создаём глобальную конфигурацию bash"

    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p /etc/profile.d

        cat > "$profile_d_file" << 'BASHRC'
# ============================================================
#  /etc/profile.d/99-server-init.sh — Terminal Ergonomics
#  Загружается всеми sh-совместимыми оболочками при логине
#  и bash в интерактивном режиме.
# ============================================================

# Только для интерактивных сессий bash
[ -z "$BASH_VERSION" ] && return
[[ $- != *i* ]] && return

# ─── Редактор по умолчанию ───────────────────────────────────────────────────
export EDITOR="${EDITOR:-nano}"
export VISUAL="$EDITOR"

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
# Полный список в MOTD cheatsheet (команда: cheatsheet)
bind '"\e[A": history-search-backward' 2>/dev/null || true  # ↑ с фильтром
bind '"\e[B": history-search-forward'  2>/dev/null || true  # ↓ с фильтром
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
alias cheatsheet='bash /etc/profile.d/99-cheatsheet.sh 2>/dev/null || echo "cheatsheet не найден"'

# ─── ФУНКЦИЯ mkcd ────────────────────────────────────────────────────────────
mkcd() { mkdir -p "$1" && cd "$1" || return 1; }

# ─── ФУНКЦИЯ extract ─────────────────────────────────────────────────────────
extract() {
    [[ -z "$1" ]] && { echo "Использование: extract <файл>"; return 1; }
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

        # ── Debian: /etc/bash.bashrc.d/ (интерактивные non-login оболочки) ──
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

        # ── RHEL: /etc/bashrc.d/ ──────────────────────────────────────────────
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

        # Экспорт STARSHIP_CONFIG в profile.d
        if ! grep -q 'STARSHIP_CONFIG' "$profile_d_file" 2>/dev/null; then
            echo 'export STARSHIP_CONFIG="/etc/starship/starship.toml"' >> "$profile_d_file"
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

    # Путь к cheatsheet-скрипту (универсальный)
    local cheatsheet_script="/etc/profile.d/99-cheatsheet.sh"

    # Отключить шумные Debian MOTD
    if [[ "$OS_FAMILY" == "debian" ]]; then
        for f in /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news \
                 /etc/update-motd.d/80-esm /etc/update-motd.d/91-contract-ua-esm-status; do
            [[ -f "$f" && -x "$f" ]] && { run chmod -x "$f"; log_info "Отключён: $(basename "$f")"; }
        done
        # MOTD-скрипт для Debian
        [[ "$DRY_RUN" != "true" ]] && ln -sf "$cheatsheet_script" /etc/update-motd.d/99-cheatsheet 2>/dev/null || true
    fi

    # RHEL/Arch/Alpine: добавляем вызов в /etc/profile (выполняется при логине)
    if [[ "$OS_FAMILY" != "debian" && "$DRY_RUN" != "true" ]]; then
        if [[ -f /etc/profile ]] && ! grep -q '99-cheatsheet' /etc/profile; then
            echo "[ -f /etc/profile.d/99-cheatsheet.sh ] && bash /etc/profile.d/99-cheatsheet.sh" >> /etc/profile
        fi
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "$cheatsheet_script" << 'MOTD'
#!/usr/bin/env bash
# /etc/profile.d/99-cheatsheet.sh — динамическая памятка при логине
# Запуск вручную: cheatsheet

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
SWAP_INFO=$(free -h 2>/dev/null | awk 'NR==3{if($2=="0B")print "— не настроен"; else printf "%s / %s",$3,$2}')
DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s занято из %s (%s)",$3,$2,$5}')
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
USERS_N=$(who 2>/dev/null | wc -l || echo "?")
MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}' 2>/dev/null); [[ -z "$MY_IP" ]] && MY_IP="local"
COLS=$(tput cols 2>/dev/null || echo 80)
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

        chmod +x "$cheatsheet_script"
        log_ok "MOTD Cheatsheet: ${cheatsheet_script}"
    else
        echo -e "  ${DIM}[dry-run] создан ${cheatsheet_script}${RESET}"
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

# ─── 9. SSH Hardening ─────────────────────────────────────────────────────────
harden_ssh() {
    log_section "9 · SSH Hardening"

    local sshd_cfg="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_cfg" ]] && { log_warn "sshd_config не найден — SSH не установлен"; return 0; }

    # Резервная копия
    if [[ ! -f "${sshd_cfg}.bak" ]]; then
        run cp "$sshd_cfg" "${sshd_cfg}.bak"
        log_ok "Резервная копия: ${sshd_cfg}.bak"
    else
        log_skip "Резервная копия уже существует"
    fi

    # Проверяем и очищаем authorized_keys
    local root_keys="/root/.ssh/authorized_keys"
    if [[ -f "$root_keys" ]] && grep -qvE '^(ssh-|ecdsa-|sk-|#|$)' "$root_keys" 2>/dev/null; then
        log_step "Очищаем мусорные строки из authorized_keys..."
        grep -E '^(ssh-|ecdsa-|sk-)' "$root_keys" | awk '!seen[$0]++' > "${root_keys}.tmp"
        mv "${root_keys}.tmp" "$root_keys"
        log_ok "authorized_keys очищен"
    fi

    local key_count; key_count=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$root_keys" 2>/dev/null || echo 0)
    if (( key_count == 0 )); then
        log_warn "ВНИМАНИЕ: нет валидных ключей в authorized_keys!"
        log_warn "Добавьте ключ ПЕРЕД закрытием текущей сессии — иначе потеряете доступ."
        log_warn "Пропускаем отключение пароля."
        return 0
    fi
    log_ok "authorized_keys: ${key_count} валидных ключей"

    if [[ "$DRY_RUN" != "true" ]]; then
        sshd_set() {
            local d="$1" v="$2"
            if grep -qE "^#?[[:space:]]*${d}[[:space:]]" "$sshd_cfg"; then
                sed -i -E "s|^#?[[:space:]]*${d}[[:space:]].*|${d} ${v}|" "$sshd_cfg"
            else
                echo "${d} ${v}" >> "$sshd_cfg"
            fi
        }

        sshd_set "PermitRootLogin"                "prohibit-password"
        sshd_set "PasswordAuthentication"         "no"
        sshd_set "PubkeyAuthentication"           "yes"
        sshd_set "AuthorizedKeysFile"             ".ssh/authorized_keys"
        sshd_set "PermitEmptyPasswords"           "no"
        sshd_set "ChallengeResponseAuthentication" "no"
        sshd_set "KbdInteractiveAuthentication"   "no"
        sshd_set "X11Forwarding"                  "no"
        sshd_set "PrintMotd"                      "no"
        sshd_set "MaxAuthTries"                   "3"
        sshd_set "MaxSessions"                    "10"
        sshd_set "ClientAliveInterval"            "300"
        sshd_set "ClientAliveCountMax"            "2"
        sshd_set "LoginGraceTime"                 "30"
        sshd_set "LogLevel"                       "VERBOSE"

        if sshd -t 2>/dev/null; then
            # SSH_SERVICE определён detect_os() — ssh или sshd
            svc_reload "$SSH_SERVICE"
            log_ok "SSH перезагружен: пароли отключены, только ключи"
        else
            log_error "Ошибка синтаксиса sshd_config — откат"
            cp "${sshd_cfg}.bak" "$sshd_cfg"
            return 1
        fi
    fi

    log_ok "SSH hardening применён"
    log_info "PermitRootLogin: prohibit-password | PasswordAuthentication: no"
    log_info "MaxAuthTries: 3 | LoginGraceTime: 30s | ClientAlive: 5min"
}

# ─── 10. Fail2ban + Recidive ──────────────────────────────────────────────────
install_fail2ban() {
    log_section "10 · Fail2ban (SSH + Recidive)"

    [[ "$SKIP_PACKAGES" == "true" ]] && { log_warn "Пропущено (--skip-packages)"; return 0; }

    # Alpine использует другие механизмы защиты (nftables + cron скрипты)
    if [[ "$OS_FAMILY" == "alpine" ]]; then
        log_info "Alpine: fail2ban не поддерживает OpenRC напрямую"
        log_info "Альтернатива: apk add sshguard && rc-update add sshguard default"
        pkg_install sshguard && svc_enable sshguard && svc_start sshguard \
            && log_ok "sshguard установлен (аналог fail2ban для Alpine)" \
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

    if [[ "$DRY_RUN" != "true" ]]; then
        # ВАЖНО: fail2ban не поддерживает inline-комментарии после значений!
        cat > /etc/fail2ban/jail.local << 'F2B'
# /etc/fail2ban/jail.local
# Внимание: НЕ используйте inline-комментарии (# ...) после значений!

[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction          = iptables-multiport
banaction_allports = iptables-allports
backend            = auto
usedns             = warn
logencoding        = auto
enabled            = false

# ─── SSH ──────────────────────────────────────────────────────────────────────
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 5
bantime  = 1h
findtime = 10m

# ─── RECIDIVE ─────────────────────────────────────────────────────────────────
# IP попал в бан 5+ раз за сутки → блокировка на 2 недели
[recidive]
enabled   = true
filter    = recidive
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime   = 2w
findtime  = 1d
maxretry  = 5
F2B

        log_ok "Создан /etc/fail2ban/jail.local"

        # Убедиться, что лог-файл существует (нужен для recidive)
        touch /var/log/fail2ban.log 2>/dev/null || true

        # Фильтр recidive (если отсутствует)
        if [[ ! -f /etc/fail2ban/filter.d/recidive.conf ]]; then
            cat > /etc/fail2ban/filter.d/recidive.conf << 'RECIDIVE'
[Definition]
failregex = ^%(__prefix_line)s(?:NOTICE  |WARNING |CRITICAL)?(?:\[\d+\])? Ban <HOST>$
ignoreregex =
RECIDIVE
            log_ok "Создан фильтр recidive.conf"
        fi

        svc_enable fail2ban
        svc_restart fail2ban
        sleep 3

        if svc_is_active fail2ban; then
            log_ok "fail2ban запущен и включён в автозагрузку"
        else
            log_warn "fail2ban не запустился — лог:"
            journalctl -u fail2ban --no-pager -n 15 2>/dev/null \
                | grep -v "^--" | tail -10 \
                | while read -r line; do echo -e "  ${RED}│${RESET} ${DIM}${line}${RESET}"; done
        fi

        sleep 1
        log_info "Статус джейлов:"
        fail2ban-client status 2>/dev/null | grep -E 'Jail|Number' \
            | while read -r line; do log_info "  $line"; done || true
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
            local ver; ver=$(eval "$cmd" 2>&1 | head -1 | grep -oP '[\d.]+' | head -1 || echo "ok")
            printf "  ${GREEN}✔${RESET}  %-16s  ${DIM}%-8s${RESET}  %s\n" "$name" "OK" "$ver"
        else
            printf "  ${RED}✘${RESET}  %-16s  ${RED}%-8s${RESET}\n" "$name" "MISSING"
        fi
    done

    echo ""
    local configs=(
        "/etc/profile.d/99-server-init.sh"
        "/etc/profile.d/99-cheatsheet.sh"
        "/usr/local/bin/view-pdf"
        "/etc/tmux.conf"
        "/etc/starship/starship.toml"
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
  │  1.  Таймзона → Europe/Moscow, NTP синхронизация                    │
  │  2.  Локали: LANG=en_US.UTF-8 + ru_RU.UTF-8                        │
  │  3.  Дополнительные репозитории (EPEL/backports/community)          │
  │  4.  CLI-стек: btop, htop, ncdu, rg, fd, jq, tmux, fzf, zoxide     │
  │  5.  Промпт starship с git, языками и временем выполнения           │
  │  6.  view-pdf: просмотр PDF в терминале (графика + текст)           │
  │  7.  chafa: отображение изображений в SSH-сессии                    │
  │  8.  MOTD cheatsheet при логине + алиас cheatsheet                  │
  │  9.  Глобальный profile.d: алиасы, горячие клавиши, функции        │
  │  10. Конфигурация tmux с vim-клавишами и статусной строкой          │
  │  11. SSH hardening: только ключи, без паролей                       │
  │  12. fail2ban: SSH + recidive (5 банов → 2 недели блокировки)       │
  └─────────────────────────────────────────────────────────────────────┘

SUMMARY

    echo -e "  ${BOLD}${GREEN}Следующие шаги:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Перезайдите в SSH или выполните: ${BOLD}source /etc/profile${RESET}"
    echo -e "  ${CYAN}2.${RESET} Попробуйте памятку:              ${BOLD}cheatsheet${RESET}"
    echo -e "  ${CYAN}3.${RESET} Проверьте промпт starship:       ${BOLD}exec bash${RESET}"
    echo -e "  ${CYAN}4.${RESET} Статус fail2ban:                 ${BOLD}fail2ban-client status${RESET}"
    echo -e "  ${CYAN}5.${RESET} Просмотр изображения:            ${BOLD}chafa image.png${RESET}"
    echo ""
    echo -e "  ${BOLD}${RED}⚠  ВАЖНО:${RESET} SSH-пароли отключены."
    echo -e "     Убедитесь, что ваш публичный ключ в ${BOLD}~/.ssh/authorized_keys${RESET}"
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

    preflight_checks       # detect_os() вызывается здесь
    setup_system
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
