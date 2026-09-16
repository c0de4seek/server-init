#!/usr/bin/env bash
# ==============================================================================
#  server-init.sh — Первичная инициализация «чистого» Debian/Ubuntu сервера
#
#  Что делает скрипт:
#    1. Системная подготовка: таймзона, NTP, локали
#    2. Установка современного CLI-стека: btop, htop, ncdu, ripgrep, fd-find,
#       jq, tmux, zoxide, fzf, starship
#    3. Терминальный просмотр медиа: chafa, view-pdf (pdftoppm + chafa),
#       pdftotext
#    4. Эргономика командной строки: алиасы, горячие клавиши
#    5. MOTD Cheatsheet: динамическая памятка при логине
#
#  Использование:
#    sudo bash server-init.sh [--dry-run] [--skip-packages] [--help]
#
#  Требования:
#    - Debian 11+ / Ubuntu 20.04+
#    - Запуск с правами root (sudo)
#    - Наличие интернет-соединения
#
#  Идемпотентность: скрипт безопасно запускать повторно — уже выполненные
#  шаги будут пропущены без ошибок.
# ==============================================================================

set -euo pipefail

# ─── Цвета и вспомогательные функции ─────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'

log_section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${RESET}"; echo -e "${BOLD}${BLUE}  $1${RESET}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════════${RESET}"; }
log_ok()      { echo -e "  ${GREEN}✔${RESET}  $1"; }
log_skip()    { echo -e "  ${DIM}–  $1 (пропущено, уже выполнено)${RESET}"; }
log_info()    { echo -e "  ${CYAN}ℹ${RESET}  $1"; }
log_warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
log_error()   { echo -e "  ${RED}✘${RESET}  $1" >&2; }
log_step()    { echo -e "  ${YELLOW}→${RESET}  $1"; }

die() { log_error "$1"; exit 1; }

# ─── Разбор аргументов ────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_PACKAGES=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=true ;;
        --skip-packages) SKIP_PACKAGES=true ;;
        --help|-h)
            echo "Использование: sudo bash server-init.sh [--dry-run] [--skip-packages]"
            echo ""
            echo "  --dry-run        Показать что будет сделано без реальных изменений"
            echo "  --skip-packages  Пропустить установку пакетов (только конфиги)"
            exit 0
            ;;
        *) die "Неизвестный аргумент: $arg. Используйте --help." ;;
    esac
done

# Обёртка для команд в dry-run режиме
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[dry-run] $*${RESET}"
    else
        "$@"
    fi
}

# ─── Предварительные проверки ─────────────────────────────────────────────────
preflight_checks() {
    log_section "Предварительные проверки"

    # Root
    if [[ $EUID -ne 0 ]]; then
        die "Скрипт должен быть запущен с правами root: sudo bash $0"
    fi
    log_ok "Запущен от root"

    # ОС
    if [[ ! -f /etc/debian_version ]]; then
        die "Поддерживаются только Debian/Ubuntu системы"
    fi
    local os_id; os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    local os_ver; os_ver=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "unknown")
    log_ok "ОС: ${os_id} ${os_ver}"

    # Интернет
    if ! curl -fsS --connect-timeout 5 https://debian.org > /dev/null 2>&1; then
        log_warn "Нет доступа к debian.org — проверьте интернет-соединение"
    else
        log_ok "Интернет-соединение в порядке"
    fi

    # Пространство на диске (минимум 2 ГБ)
    local free_kb; free_kb=$(df /usr --output=avail | tail -1)
    local free_gb; free_gb=$(( free_kb / 1024 / 1024 ))
    if (( free_kb < 2097152 )); then
        log_warn "Мало свободного места: ${free_gb} ГБ (рекомендуется ≥2 ГБ)"
    else
        log_ok "Свободное место: ${free_gb} ГБ"
    fi
}

# ─── 1. Системная подготовка ──────────────────────────────────────────────────
setup_system() {
    log_section "1 · Системная подготовка"

    # Таймзона
    local current_tz; current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
    if [[ "$current_tz" == "Europe/Moscow" ]]; then
        log_skip "Таймзона уже Europe/Moscow"
    else
        log_step "Устанавливаем таймзону Europe/Moscow (было: ${current_tz})"
        run timedatectl set-timezone Europe/Moscow
        log_ok "Таймзона → Europe/Moscow"
    fi

    # NTP через systemd-timesyncd
    log_step "Настраиваем NTP (systemd-timesyncd)"
    run mkdir -p /etc/systemd/timesyncd.conf.d
    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/systemd/timesyncd.conf.d/custom.conf << 'EOF'
[Time]
NTP=0.ru.pool.ntp.org 1.ru.pool.ntp.org 0.europe.pool.ntp.org
FallbackNTP=time.cloudflare.com ntp.ubuntu.com
EOF
    fi
    run systemctl enable --now systemd-timesyncd 2>/dev/null || true
    run timedatectl set-ntp true 2>/dev/null || true
    log_ok "NTP синхронизация включена"

    # Локали
    log_step "Настраиваем локали (en_US.UTF-8 + ru_RU.UTF-8)"
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        if [[ -f /etc/locale.gen ]]; then
            run sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
            run sed -i 's/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
            run locale-gen
        fi
    else
        log_skip "Локаль en_US.UTF-8 уже сгенерирована"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/locale.conf << 'EOF'
LANG=en_US.UTF-8
LC_MESSAGES=en_US.UTF-8
LC_TIME=ru_RU.UTF-8
LC_MONETARY=ru_RU.UTF-8
LC_NUMERIC=ru_RU.UTF-8
LC_COLLATE=en_US.UTF-8
EOF
    fi
    run update-locale LANG=en_US.UTF-8 2>/dev/null || true
    log_ok "Локали настроены: LANG=en_US.UTF-8, ru_RU.UTF-8 как вспомогательная"

    # Обновление индекса пакетов
    log_step "Обновляем индекс пакетов apt"
    run apt-get update -qq
    log_ok "apt-get update выполнен"
}

# ─── 2. Установка пакетов ─────────────────────────────────────────────────────
install_packages() {
    log_section "2 · Установка CLI-утилит"

    if [[ "$SKIP_PACKAGES" == "true" ]]; then
        log_warn "Установка пакетов пропущена (--skip-packages)"
        return 0
    fi

    # ── Базовые зависимости ──
    local base_deps=(
        curl wget git ca-certificates gnupg apt-transport-https
        build-essential software-properties-common unzip
        poppler-utils  # pdftoppm + pdftotext
    )

    log_step "Устанавливаем базовые зависимости..."
    run apt-get install -y -qq "${base_deps[@]}"
    log_ok "Базовые зависимости установлены"

    # ── Системные утилиты мониторинга и диагностики ──
    local cli_tools=(
        htop          # интерактивный просмотр процессов
        ncdu          # ncurses-визуализация дискового пространства
        jq            # обработка JSON в командной строке
        tmux          # мультиплексор терминала
        ripgrep       # сверхбыстрый grep (rg)
        fd-find       # современная замена find
        chafa         # рендеринг изображений в терминале
        less          # постраничный просмотр
        tree          # древовидный вывод директорий
        file          # определение типа файла
        lsof          # список открытых файлов
        net-tools     # ifconfig, netstat
        dnsutils      # dig, nslookup
        mtr           # улучшенный traceroute
        iotop         # мониторинг дискового ввода-вывода
        sysstat       # iostat, mpstat, sar
        strace        # трассировка системных вызовов
        pv            # прогресс-бар для потоков данных
        bc            # калькулятор
        xz-utils      # работа с .xz архивами
        zip unzip     # работа с .zip
        p7zip-full    # работа с 7z архивами
        rsync         # синхронизация файлов
        socat         # мультипоточный сокет
        bat           # cat с подсветкой синтаксиса (batcat)
        exa           # современная замена ls (если доступен)
    )

    log_step "Устанавливаем CLI-утилиты..."
    # Устанавливаем по одному, чтобы один недоступный пакет не прервал всё
    for pkg in "${cli_tools[@]}"; do
        if run apt-get install -y -qq "$pkg" 2>/dev/null; then
            :
        else
            log_warn "Пакет '${pkg}' не найден в репозиториях — пропущен"
        fi
    done
    log_ok "CLI-утилиты установлены"

    # ── btop (из GitHub если нет в репо) ──
    install_btop

    # ── fzf ──
    install_fzf

    # ── zoxide ──
    install_zoxide

    # ── starship ──
    install_starship
}

install_btop() {
    if command -v btop &>/dev/null; then
        log_skip "btop уже установлен ($(btop --version 2>/dev/null | head -1))"
        return 0
    fi

    log_step "Устанавливаем btop..."
    # Пробуем через apt сначала
    if apt-get install -y -qq btop 2>/dev/null; then
        log_ok "btop установлен через apt"
        return 0
    fi

    # Fallback: скачиваем бинарник с GitHub
    local arch; arch=$(uname -m)
    local btop_url
    case "$arch" in
        x86_64)  btop_url="https://github.com/aristocratos/btop/releases/latest/download/btop-x86_64-linux-musl.tbz" ;;
        aarch64) btop_url="https://github.com/aristocratos/btop/releases/latest/download/btop-aarch64-linux-musl.tbz" ;;
        *)
            log_warn "btop: неподдерживаемая архитектура ${arch}"
            return 0
            ;;
    esac

    local tmp_dir; tmp_dir=$(mktemp -d)
    if run curl -fsSL "$btop_url" -o "${tmp_dir}/btop.tbz"; then
        run tar -xjf "${tmp_dir}/btop.tbz" -C "$tmp_dir"
        run install -Dm755 "${tmp_dir}/btop/bin/btop" /usr/local/bin/btop
        log_ok "btop установлен из GitHub release"
    else
        log_warn "Не удалось загрузить btop с GitHub"
    fi
    rm -rf "$tmp_dir"
}

install_fzf() {
    if command -v fzf &>/dev/null; then
        log_skip "fzf уже установлен ($(fzf --version 2>/dev/null))"
        return 0
    fi

    log_step "Устанавливаем fzf..."
    if apt-get install -y -qq fzf 2>/dev/null; then
        log_ok "fzf установлен через apt"
        return 0
    fi

    # Fallback: официальный установщик через Git
    if [[ "$DRY_RUN" != "true" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git /tmp/fzf-install 2>/dev/null || true
        if [[ -d /tmp/fzf-install ]]; then
            bash /tmp/fzf-install/install --bin
            install -Dm755 /tmp/fzf-install/bin/fzf /usr/local/bin/fzf
            rm -rf /tmp/fzf-install
            log_ok "fzf установлен из GitHub"
        fi
    else
        echo -e "  ${DIM}[dry-run] git clone + install fzf${RESET}"
    fi
}

install_zoxide() {
    if command -v zoxide &>/dev/null; then
        log_skip "zoxide уже установлен ($(zoxide --version 2>/dev/null))"
        return 0
    fi

    log_step "Устанавливаем zoxide..."
    if apt-get install -y -qq zoxide 2>/dev/null; then
        log_ok "zoxide установлен через apt"
        return 0
    fi

    # Официальный установщик
    if run curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash; then
        log_ok "zoxide установлен через официальный скрипт"
    else
        log_warn "Не удалось установить zoxide"
    fi
}

install_starship() {
    if command -v starship &>/dev/null; then
        log_skip "starship уже установлен ($(starship --version 2>/dev/null | head -1))"
        return 0
    fi

    log_step "Устанавливаем starship..."
    if run curl -fsSL https://starship.rs/install.sh | sh -s -- --yes; then
        log_ok "starship установлен"
    else
        log_warn "Не удалось установить starship"
    fi
}

# ─── 3. Утилита view-pdf ──────────────────────────────────────────────────────
install_view_pdf() {
    log_section "3 · Установка утилиты view-pdf"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /usr/local/bin/view-pdf << 'SCRIPT'
#!/usr/bin/env bash
# view-pdf — просмотр PDF-файлов в терминале через chafa (графика) или pdftotext (текст)
#
# Использование:
#   view-pdf file.pdf              # постраничный рендеринг изображений
#   view-pdf file.pdf --text       # извлечение текстового слоя
#   view-pdf file.pdf --page 3     # конкретная страница
#   view-pdf file.pdf --width 120  # ширина в символах
#
# Зависимости: poppler-utils (pdftoppm, pdftotext), chafa

set -euo pipefail

usage() {
    echo "Использование: view-pdf <file.pdf> [опции]"
    echo ""
    echo "Опции:"
    echo "  --text          Вывести текстовый слой PDF (через pdftotext)"
    echo "  --page N        Показать только страницу N (начиная с 1)"
    echo "  --width N       Ширина вывода в символах (по умолчанию: ширина терминала)"
    echo "  --dpi N         DPI рендеринга (по умолчанию: 150)"
    echo "  --help, -h      Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  view-pdf doc.pdf                  # все страницы"
    echo "  view-pdf doc.pdf --page 2         # только страница 2"
    echo "  view-pdf doc.pdf --text           # текстовый режим"
    echo "  view-pdf doc.pdf --text --page 1  # текст первой страницы"
}

# Проверка зависимостей
check_deps() {
    local missing=()
    command -v pdftoppm  &>/dev/null || missing+=(pdftoppm)
    command -v pdftotext &>/dev/null || missing+=(pdftotext)
    command -v chafa     &>/dev/null || missing+=(chafa)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Ошибка: не найдены утилиты: ${missing[*]}" >&2
        echo "Установите: sudo apt-get install poppler-utils chafa" >&2
        exit 1
    fi
}

# Разбор аргументов
PDF_FILE=""
TEXT_MODE=false
PAGE_NUM=""
WIDTH=$(tput cols 2>/dev/null || echo 120)
DPI=150

while [[ $# -gt 0 ]]; do
    case "$1" in
        --text)        TEXT_MODE=true; shift ;;
        --page)        PAGE_NUM="$2"; shift 2 ;;
        --width)       WIDTH="$2"; shift 2 ;;
        --dpi)         DPI="$2"; shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        -*)            echo "Неизвестная опция: $1" >&2; usage; exit 1 ;;
        *)
            if [[ -z "$PDF_FILE" ]]; then PDF_FILE="$1"
            else echo "Лишний аргумент: $1" >&2; usage; exit 1; fi
            shift
            ;;
    esac
done

[[ -z "$PDF_FILE" ]] && { usage; exit 1; }
[[ ! -f "$PDF_FILE" ]] && { echo "Файл не найден: $PDF_FILE" >&2; exit 1; }
[[ "$PDF_FILE" != *.pdf && "$PDF_FILE" != *.PDF ]] && echo "Предупреждение: файл не имеет расширения .pdf" >&2

check_deps

# Общее количество страниц
TOTAL_PAGES=$(pdfinfo "$PDF_FILE" 2>/dev/null | grep 'Pages:' | awk '{print $2}' || echo "?")

# ── Текстовый режим ──────────────────────────────────────────────────────────
if [[ "$TEXT_MODE" == "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📄  $(basename "$PDF_FILE")  [текстовый режим]  (всего страниц: ${TOTAL_PAGES})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -n "$PAGE_NUM" ]]; then
        pdftotext -f "$PAGE_NUM" -l "$PAGE_NUM" "$PDF_FILE" - 2>/dev/null
    else
        pdftotext "$PDF_FILE" - 2>/dev/null
    fi
    exit 0
fi

# ── Графический режим (через chafa) ─────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

render_page() {
    local page_n="$1"
    local img_prefix="${TMP_DIR}/page"

    # Рендерим страницу в PNG
    pdftoppm -r "$DPI" -f "$page_n" -l "$page_n" -png "$PDF_FILE" "$img_prefix" 2>/dev/null

    # pdftoppm добавляет суффикс вида -001.png
    local img_file; img_file=$(ls "${img_prefix}"*.png 2>/dev/null | head -1)

    if [[ -z "$img_file" ]]; then
        echo "Ошибка: не удалось отрендерить страницу ${page_n}" >&2
        return 1
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  📄  %s  │  Страница %d из %s\n" "$(basename "$PDF_FILE")" "$page_n" "$TOTAL_PAGES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    chafa --size "${WIDTH}x9999" "$img_file"

    # Очистить временный файл
    rm -f "$img_file"
}

if [[ -n "$PAGE_NUM" ]]; then
    render_page "$PAGE_NUM"
else
    # Интерактивный постраничный просмотр
    current_page=1
    if [[ "$TOTAL_PAGES" == "?" ]]; then
        TOTAL_PAGES=999  # защитная граница
    fi

    while true; do
        render_page "$current_page"
        echo ""
        echo -n "  [←/h — назад | →/l — вперёд | q — выход | страница N: введите число]: "
        read -r input </dev/tty

        case "$input" in
            q|Q|exit) break ;;
            h|H|b|B|prev|"") (( current_page > 1 )) && (( current_page-- )) ;;
            l|L|n|N|next)
                (( current_page < TOTAL_PAGES )) && (( current_page++ ))
                ;;
            ''*([0-9])|[0-9]*)
                if [[ "$input" =~ ^[0-9]+$ ]]; then
                    if (( input >= 1 && input <= TOTAL_PAGES )); then
                        current_page=$input
                    else
                        echo "  Страница должна быть от 1 до ${TOTAL_PAGES}"
                    fi
                fi
                ;;
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
    log_section "4 · Настройка Bash (глобальная конфигурация)"

    local bashrc_global="/etc/bash.bashrc.d/99-server-init.sh"
    run mkdir -p /etc/bash.bashrc.d

    log_step "Создаём глобальную конфигурацию bash"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "$bashrc_global" << 'BASHRC'
# ============================================================
#  /etc/bash.bashrc.d/99-server-init.sh
#  Глобальная конфигурация bash — ergonomics server-init
#  Применяется ко всем пользователям системы.
# ============================================================

# Ничего не делать в неинтерактивной сессии
[[ $- != *i* ]] && return

# ─── Редактор по умолчанию ───────────────────────────────────────────────────
# nano — для начинающих; смените на 'vim' или 'micro' по желанию
export EDITOR="${EDITOR:-nano}"
export VISUAL="$EDITOR"

# ─── АЛИАСЫ БЫСТРОЙ НАВИГАЦИИ ────────────────────────────────────────────────
# Переход на один / два / три уровня вверх
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Вернуться в предыдущую директорию (аналог «cd -»)
alias -- -='cd -'

# ─── «SUDO PLEASE» ───────────────────────────────────────────────────────────
# Перезапустить последнюю команду с sudo.
# Аналог 'sudo !!' — но без истории bash, которая не раскрывает !! в алиасах.
alias please='sudo $(fc -ln -1)'

# ─── УДОБНЫЙ ls ──────────────────────────────────────────────────────────────
if command -v eza &>/dev/null || command -v exa &>/dev/null; then
    # eza — современная замена ls с иконками и git-интеграцией
    _eza_bin=$(command -v eza 2>/dev/null || command -v exa)
    alias ls="$_eza_bin --color=auto --group-directories-first --icons 2>/dev/null || ls --color=auto"
    alias ll="$_eza_bin -alF --color=auto --group-directories-first --icons --git 2>/dev/null || ls -alF"
    alias la="$_eza_bin -a --color=auto --group-directories-first --icons 2>/dev/null || ls -a"
    alias lt="$_eza_bin --tree --color=auto --icons --level=2 2>/dev/null || tree"
else
    alias ls='ls --color=auto --group-directories-first'
    alias ll='ls -alFh --color=auto --group-directories-first'
    alias la='ls -Ah --color=auto'
fi

# ─── АЛИАСЫ ОБЩЕГО НАЗНАЧЕНИЯ ────────────────────────────────────────────────
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'
alias df='df -h'           # читаемый вывод дискового пространства
alias du='du -h'           # читаемый вывод размеров
alias free='free -h'       # читаемый вывод памяти

# bat / batcat (замена cat с подсветкой синтаксиса)
if command -v batcat &>/dev/null; then
    alias bat='batcat'
    alias cat='batcat --paging=never'
elif command -v bat &>/dev/null; then
    alias cat='bat --paging=never'
fi

# fd-find → fd
if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    alias fd='fdfind'
fi

# Безопасный rm (просит подтверждения при удалении > 3 файлов или рекурсивно)
alias rm='rm -i'

# Копирование с прогрессом
alias cp='cp -i'

# История без дубликатов
alias history='history | sort -k2 -k1rn | uniq -f1 | sort -n'

# Быстрый просмотр JSON
alias jqp='jq . | less -R'

# ─── ИСТОРИЯ BASH ────────────────────────────────────────────────────────────
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups  # не записывать дубли и команды с пробелом
export HISTTIMEFORMAT='%F %T  '          # временны́е метки в истории
shopt -s histappend                      # дописывать историю, не перезаписывать

# ─── ГОРЯЧИЕ КЛАВИШИ (readline / inputrc) ────────────────────────────────────
# Эти привязки работают в bash через bind; сохраняются стандартные сочетания.
#
# ╔══════════════════════════════════════════════════════════╗
# ║  Перемещение по строке                                   ║
# ║  Ctrl+A / Home   — в начало строки                       ║
# ║  Ctrl+E / End    — в конец строки                        ║
# ║  Alt+B / Alt+←   — назад на слово                        ║
# ║  Alt+F / Alt+→   — вперёд на слово                       ║
# ║  Ctrl+← / Ctrl+→  — назад/вперёд на слово (терминал)    ║
# ╠══════════════════════════════════════════════════════════╣
# ║  Редактирование строки                                   ║
# ║  Ctrl+W          — удалить слово слева                   ║
# ║  Alt+D           — удалить слово справа                  ║
# ║  Ctrl+U          — удалить от курсора до начала          ║
# ║  Ctrl+K          — удалить от курсора до конца           ║
# ║  Ctrl+Y          — вставить удалённое (yank)             ║
# ║  Ctrl+_          — отмена последнего действия (undo)     ║
# ╠══════════════════════════════════════════════════════════╣
# ║  История команд                                          ║
# ║  Ctrl+R          — поиск по истории (reverse-i-search)   ║
# ║  Ctrl+S          — поиск по истории вперёд               ║
# ║  Alt+.           — вставить последний аргумент           ║
# ╠══════════════════════════════════════════════════════════╣
# ║  Управление процессом                                    ║
# ║  Ctrl+C          — прервать текущую команду              ║
# ║  Ctrl+Z          — приостановить, bg/fg для управления   ║
# ║  Ctrl+D          — закрыть сессию (EOF)                  ║
# ║  Ctrl+L          — очистить экран (как clear)            ║
# ╠══════════════════════════════════════════════════════════╣
# ║  Продвинутые                                             ║
# ║  Ctrl+X Ctrl+E   — открыть текущую строку в $EDITOR      ║
# ║  Ctrl+X Ctrl+R   — перечитать ~/.inputrc                 ║
# ╚══════════════════════════════════════════════════════════╝
#
# Дополнительные привязки:
bind '"\e[A": history-search-backward' 2>/dev/null || true  # ↑ с фильтром
bind '"\e[B": history-search-forward'  2>/dev/null || true  # ↓ с фильтром
bind 'set completion-ignore-case on'   2>/dev/null || true  # Tab без учёта регистра
bind 'set show-all-if-ambiguous on'    2>/dev/null || true  # показать все варианты
bind 'set colored-stats on'            2>/dev/null || true  # цветной Tab-список

# ─── ОПЦИИ BASH ──────────────────────────────────────────────────────────────
shopt -s checkwinsize   # обновлять LINES/COLUMNS при изменении окна
shopt -s cdspell        # исправлять опечатки в cd
shopt -s autocd         # вводить директорию — зайти в неё без cd
shopt -s globstar       # ** для рекурсивных glob-шаблонов
shopt -s cmdhist        # сохранять многострочные команды в одну строку истории

# ─── fzf ИНТЕГРАЦИЯ ──────────────────────────────────────────────────────────
if command -v fzf &>/dev/null; then
    # Ctrl+R — поиск по истории через fzf (вместо стандартного reverse-search)
    if [[ -f /usr/share/doc/fzf/examples/key-bindings.bash ]]; then
        source /usr/share/doc/fzf/examples/key-bindings.bash
    elif [[ -f /usr/share/fzf/key-bindings.bash ]]; then
        source /usr/share/fzf/key-bindings.bash
    elif [[ -f ~/.fzf.bash ]]; then
        source ~/.fzf.bash
    fi
    # Ctrl+T — поиск файла
    # Alt+C  — переход в директорию через fzf
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'
    export FZF_CTRL_R_OPTS='--sort --exact'
fi

# ─── ZOXIDE — умный cd ───────────────────────────────────────────────────────
# Вместо «cd /some/long/path» можно написать «z path» — zoxide запомнит
# часто посещаемые директории и перейдёт в нужную по частичному совпадению.
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init bash)"
    # zi — интерактивный выбор через fzf (если установлен)
fi

# ─── STARSHIP ПРОМПТ ─────────────────────────────────────────────────────────
# Starship показывает: текущую директорию, git-ветку и статус, язык/версию
# проекта (Python, Node, Rust...), код возврата последней команды.
if command -v starship &>/dev/null; then
    eval "$(starship init bash)"
fi

# ─── АЛИАС cheatsheet ────────────────────────────────────────────────────────
alias cheatsheet='bash /etc/update-motd.d/99-cheatsheet 2>/dev/null || echo "MOTD cheatsheet не найден"'

# ─── ФУНКЦИЯ mkcd ────────────────────────────────────────────────────────────
# Создать директорию и сразу перейти в неё
mkcd() {
    mkdir -p "$1" && cd "$1" || return 1
}

# ─── ФУНКЦИЯ extract ─────────────────────────────────────────────────────────
# Универсальный распаковщик архивов: extract file.tar.gz
extract() {
    if [[ -z "$1" ]]; then
        echo "Использование: extract <файл_архива>"
        return 1
    fi
    if [[ ! -f "$1" ]]; then
        echo "Файл не найден: $1"
        return 1
    fi
    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1"     ;;
        *.tar.gz|*.tgz)   tar xzf "$1"     ;;
        *.tar.xz|*.txz)   tar xJf "$1"     ;;
        *.tar.zst)        tar --zstd -xf "$1" ;;
        *.tar)            tar xf "$1"      ;;
        *.bz2)            bunzip2 "$1"     ;;
        *.gz)             gunzip "$1"      ;;
        *.xz)             unxz "$1"        ;;
        *.zip)            unzip "$1"       ;;
        *.7z)             7z x "$1"        ;;
        *.rar)            unrar x "$1" 2>/dev/null || 7z x "$1" ;;
        *.Z)              uncompress "$1"  ;;
        *)
            echo "Неизвестный формат архива: $1"
            echo "Поддерживаются: tar.gz, tar.bz2, tar.xz, tar.zst, tar, gz, bz2, xz, zip, 7z, rar"
            return 1
            ;;
    esac
}

# ─── ФУНКЦИЯ myip ────────────────────────────────────────────────────────────
# Показать внутренний и внешний IP-адреса
myip() {
    echo "── Внутренние IP-адреса ────────────────────────"
    hostname -I | tr ' ' '\n' | grep -v '^$' | while read -r ip; do
        printf "  %s\n" "$ip"
    done
    echo ""
    echo "── Внешний IP-адрес ────────────────────────────"
    curl -fsS --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null && echo || echo "  (нет доступа к сети)"
}

# ─── ФУНКЦИЯ sysinfo ─────────────────────────────────────────────────────────
# Краткая сводка о системе
sysinfo() {
    echo "── Система ─────────────────────────────────────"
    printf "  %-16s %s\n" "Хост:"     "$(hostname -f)"
    printf "  %-16s %s\n" "ОС:"       "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    printf "  %-16s %s\n" "Ядро:"     "$(uname -r)"
    printf "  %-16s %s\n" "Архит.:"   "$(uname -m)"
    printf "  %-16s %s\n" "Uptime:"   "$(uptime -p)"
    printf "  %-16s %s\n" "Загрузка:" "$(cut -d' ' -f1-3 /proc/loadavg)"
    echo ""
    echo "── Память ──────────────────────────────────────"
    free -h | grep -E 'Mem|Swap' | while read -r line; do printf "  %s\n" "$line"; done
    echo ""
    echo "── Диск (/) ────────────────────────────────────"
    df -h / | tail -1 | awk '{printf "  Всего: %s | Занято: %s | Свободно: %s (%s)\n", $2, $3, $4, $5}'
}

BASHRC

        log_ok "Глобальная конфигурация создана: ${bashrc_global}"

        # Подключение /etc/bash.bashrc.d/*.sh в основной /etc/bash.bashrc
        if ! grep -q 'bash.bashrc.d' /etc/bash.bashrc 2>/dev/null; then
            cat >> /etc/bash.bashrc << 'EOF'

# Загрузка файлов конфигурации из /etc/bash.bashrc.d/
if [[ -d /etc/bash.bashrc.d ]]; then
    for _f in /etc/bash.bashrc.d/*.sh; do
        [[ -r "$_f" ]] && source "$_f"
    done
    unset _f
fi
EOF
            log_ok "Добавлена загрузка /etc/bash.bashrc.d/*.sh в /etc/bash.bashrc"
        else
            log_skip "Загрузка /etc/bash.bashrc.d уже подключена в /etc/bash.bashrc"
        fi
    else
        echo -e "  ${DIM}[dry-run] создан ${bashrc_global}${RESET}"
    fi
}

# ─── 5. Конфигурация starship ─────────────────────────────────────────────────
configure_starship() {
    log_section "5 · Конфигурация Starship"

    local config_dir="/etc/starship"
    run mkdir -p "$config_dir"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > "${config_dir}/starship.toml" << 'TOML'
# ============================================================
#  /etc/starship/starship.toml — конфигурация Starship
#  Устанавливается через STARSHIP_CONFIG в глобальном bashrc
# ============================================================

# Формат строки приглашения
format = """
$username$hostname$directory$git_branch$git_status$python$nodejs$rust$golang$java$cmd_duration
$character"""

# ── Имя пользователя ──────────────────────────────────────────────────────────
[username]
show_always = false  # показывать только если root или SSH
style_user = "bold green"
style_root = "bold red"
format = "[$user]($style)@"

# ── Хост ──────────────────────────────────────────────────────────────────────
[hostname]
ssh_only = true  # показывать только в SSH-сессии
format = "[$hostname](bold cyan) "

# ── Директория ────────────────────────────────────────────────────────────────
[directory]
style = "bold blue"
truncate_to_repo = false
truncation_length = 4
truncation_symbol = "…/"
home_symbol = "~"

# ── Git ───────────────────────────────────────────────────────────────────────
[git_branch]
symbol = " "
style = "bold purple"
format = "on [$symbol$branch]($style) "

[git_status]
format = '([\[$all_status$ahead_behind\]]($style) )'
style = "bold yellow"
conflicted = "⚔"
ahead = "↑${count}"
behind = "↓${count}"
diverged = "⇕"
untracked = "?"
stashed = "⚑"
modified = "!"
staged = "+"
renamed = "»"
deleted = "✘"

# ── Языки/рантаймы ────────────────────────────────────────────────────────────
[python]
symbol = "🐍 "
style = "yellow bold"
format = "[$symbol$version]($style) "

[nodejs]
symbol = " "
style = "green bold"
format = "[$symbol$version]($style) "

[rust]
symbol = "🦀 "
style = "bold red"
format = "[$symbol$version]($style) "

[golang]
symbol = "🐹 "
style = "bold cyan"
format = "[$symbol$version]($style) "

# ── Время выполнения команды ──────────────────────────────────────────────────
[cmd_duration]
min_time = 2000  # показывать если команда выполнялась дольше 2 сек
format = "took [$duration](bold yellow) "

# ── Символ приглашения ────────────────────────────────────────────────────────
[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold yellow)"

# ── Время ─────────────────────────────────────────────────────────────────────
[time]
disabled = false
format = "[$time]($style) "
time_format = "%H:%M"
style = "dimmed"
TOML

        # Добавить STARSHIP_CONFIG в глобальный bashrc.d
        if ! grep -q 'STARSHIP_CONFIG' /etc/bash.bashrc.d/99-server-init.sh 2>/dev/null; then
            echo 'export STARSHIP_CONFIG="/etc/starship/starship.toml"' >> /etc/bash.bashrc.d/99-server-init.sh
        fi
        log_ok "Конфигурация Starship создана: ${config_dir}/starship.toml"
    else
        echo -e "  ${DIM}[dry-run] создан ${config_dir}/starship.toml${RESET}"
    fi
}

# ─── 6. MOTD Cheatsheet ───────────────────────────────────────────────────────
install_motd() {
    log_section "6 · MOTD Cheatsheet"

    # Отключить дефолтные MOTD-скрипты Ubuntu (они шумные)
    local motd_parts=(
        /etc/update-motd.d/10-help-text
        /etc/update-motd.d/50-motd-news
        /etc/update-motd.d/80-esm
        /etc/update-motd.d/91-contract-ua-esm-status
        /etc/update-motd.d/95-hwe-eol
    )
    for f in "${motd_parts[@]}"; do
        if [[ -f "$f" && -x "$f" ]]; then
            run chmod -x "$f"
            log_info "Отключён: $(basename "$f")"
        fi
    done

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/update-motd.d/99-cheatsheet << 'MOTD'
#!/usr/bin/env bash
# /etc/update-motd.d/99-cheatsheet — динамическая памятка при логине
# Запуск вручную: cheatsheet
#
# Цвета: безопасно использовать printf с \e[...] — они корректно
# раскрываются в printf, в отличие от echo без -e.

# Отступ 2 пробела для всех блоков
I="  "

# ── Цвета (ANSI escape без одиночных кавычек внутри heredoc) ──────────────
RESET=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
CYAN=$'\e[0;36m'
MAGENTA=$'\e[0;35m'
WHITE=$'\e[1;37m'
BG_DARK=$'\e[48;5;235m'

# ── Сбор системных данных ─────────────────────────────────────────────────────
HOST=$(hostname -s 2>/dev/null || echo "unknown")
FQDN=$(hostname -f 2>/dev/null || echo "$HOST")
OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime)
LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?")
DATE_STR=$(date '+%A, %d %B %Y  %H:%M %Z' 2>/dev/null || date)
TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "?")

# Память
MEM_INFO=$(free -h 2>/dev/null | awk 'NR==2{printf "%s / %s (своб. %s)", $3, $2, $4}')
SWAP_INFO=$(free -h 2>/dev/null | awk 'NR==3{if($2=="0B")print "— не настроен"; else printf "%s / %s", $3, $2}')

# Диск
DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s занято из %s (%s)", $3, $2, $5}')

# Внутренний IP
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "?")

# Сессии
USERS_N=$(who 2>/dev/null | wc -l || echo "?")
MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}' 2>/dev/null)
[[ -z "$MY_IP" ]] && MY_IP="local"

# Ширина терминала
COLS=$(tput cols 2>/dev/null || echo 80)
LINE=$(printf '%*s' "$COLS" '' | tr ' ' '─')

# ── ШАПКА ─────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
printf "${BOLD}${WHITE}${BG_DARK}  🖥  %-*s${RESET}\n" $(( COLS - 5 )) "  $FQDN  ·  $OS"
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
echo ""

# ── СИСТЕМНАЯ СВОДКА ──────────────────────────────────────────────────────────
printf "${BOLD}${YELLOW}${I}СИСТЕМА${RESET}\n"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Дата / Время:"  "$DATE_STR"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Таймзона:"       "$TIMEZONE"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Ядро:"           "$KERNEL  ($ARCH)"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Аптайм:"         "$UPTIME"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Нагрузка:"       "$LOAD"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Память:"         "$MEM_INFO"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Своп:"           "$SWAP_INFO"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Диск (/):"       "$DISK_INFO"
printf "${I}${DIM}%-18s${RESET}%s\n"  "IP-сервера:"     "$LOCAL_IP"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Ваш IP:"         "$MY_IP"
printf "${I}${DIM}%-18s${RESET}%s\n"  "Сессий:"         "$USERS_N"
echo ""

printf "${BOLD}${CYAN}${I}%s${RESET}\n" "$LINE"

# ── БЛОК 1: АЛИАСЫ И НАВИГАЦИЯ ────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}${I}📁  НАВИГАЦИЯ И АЛИАСЫ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  ".."               "перейти на уровень выше (cd ..)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "..."              "перейти на два уровня выше"
printf "${I}%-24s${DIM}%s${RESET}\n"  "-"                "вернуться в предыдущую директорию"
printf "${I}%-24s${DIM}%s${RESET}\n"  "mkcd <dir>"       "создать папку и сразу войти в неё"
printf "${I}%-24s${DIM}%s${RESET}\n"  "autocd"           "войти в папку без cd: просто введите путь"

# ── БЛОК 2: zoxide ────────────────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}${I}🚀  ZOXIDE — умный cd${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "z <часть_пути>"   "перейти в часто посещаемую папку"
printf "${I}%-24s${DIM}%s${RESET}\n"  "zi"               "интерактивный выбор через fzf"
printf "${I}%-24s${DIM}%s${RESET}\n"  "z -"              "вернуться в предыдущую директорию"
printf "${I}%-24s${DIM}%s${RESET}\n"  "zoxide query -l"  "список всех запомненных путей"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Принцип:"         "zoxide ранжирует пути по частоте и давности"

# ── БЛОК 3: fzf ───────────────────────────────────────────────────────────────
printf "\n${BOLD}${GREEN}${I}🔍  FZF — интерактивный поиск${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+R"           "поиск по истории команд через fzf"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+T"           "найти файл и вставить в строку"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Alt+C"            "перейти в директорию через fzf"
printf "${I}%-24s${DIM}%s${RESET}\n"  "fzf"              "запустить fzf на stdin"
printf "${I}%-24s${DIM}%s${RESET}\n"  "ls | fzf"         "интерактивный выбор из вывода ls"

# ── БЛОК 4: ГОРЯЧИЕ КЛАВИШИ ───────────────────────────────────────────────────
printf "\n${BOLD}${YELLOW}${I}⌨  ГОРЯЧИЕ КЛАВИШИ BASH / READLINE${RESET}\n"
printf "${BOLD}${I}  Перемещение по строке:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+A / Home"    "перейти в начало строки"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+E / End"     "перейти в конец строки"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Alt+B"            "назад на одно слово"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Alt+F"            "вперёд на одно слово"
echo ""
printf "${BOLD}${I}  Редактирование:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+W"           "удалить слово слева от курсора"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Alt+D"            "удалить слово справа от курсора"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+U"           "удалить от курсора до начала строки"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+K"           "удалить от курсора до конца строки"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+Y"           "вставить ранее удалённый текст (yank)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+_"           "отменить последнее действие (undo)"
echo ""
printf "${BOLD}${I}  История:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+R"           "поиск по истории назад"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+S"           "поиск по истории вперёд"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Alt+."            "вставить последний аргумент пред. команды"
printf "${I}%-24s${DIM}%s${RESET}\n"  "↑ / ↓"           "навигация по истории с фильтром"
echo ""
printf "${BOLD}${I}  Продвинутые:${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+X Ctrl+E"    "открыть строку в EDITOR (nano/vim)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+L"           "очистить экран (аналог clear)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+D"           "закрыть сессию (EOF)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Ctrl+Z"           "остановить процесс, bg/fg вернуть"
printf "${I}%-24s${DIM}%s${RESET}\n"  "please"           "перезапустить последнюю команду с sudo"

# ── БЛОК 5: МОНИТОРИНГ ────────────────────────────────────────────────────────
printf "\n${BOLD}${MAGENTA}${I}📊  МОНИТОРИНГ И ДИАГНОСТИКА${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "btop"             "красивый топ: CPU, RAM, диск, сеть"
printf "${I}%-24s${DIM}%s${RESET}\n"  "htop"             "классический интерактивный top"
printf "${I}%-24s${DIM}%s${RESET}\n"  "ncdu"             "ncurses-визуализатор дискового пространства"
printf "${I}%-24s${DIM}%s${RESET}\n"  "iotop"            "мониторинг I/O по процессам"
printf "${I}%-24s${DIM}%s${RESET}\n"  "sysinfo"          "краткая системная сводка (функция)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "myip"             "показать внутренний и внешний IP"
printf "${I}%-24s${DIM}%s${RESET}\n"  "free -h"          "состояние памяти в читаемом виде"
printf "${I}%-24s${DIM}%s${RESET}\n"  "df -h"            "занятость дисков"
printf "${I}%-24s${DIM}%s${RESET}\n"  "du -sh *"         "размер файлов в текущей папке"

# ── БЛОК 6: ПОИСК ─────────────────────────────────────────────────────────────
printf "\n${BOLD}${MAGENTA}${I}🔎  ПОИСК ФАЙЛОВ И КОНТЕНТА${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "rg <паттерн>"     "ripgrep: быстрый поиск текста в файлах"
printf "${I}%-24s${DIM}%s${RESET}\n"  "rg -l <паттерн>"  "только имена файлов с совпадением"
printf "${I}%-24s${DIM}%s${RESET}\n"  "rg -i <паттерн>"  "без учёта регистра"
printf "${I}%-24s${DIM}%s${RESET}\n"  "fd <имя>"         "fd-find: найти файл по имени"
printf "${I}%-24s${DIM}%s${RESET}\n"  "fd -e py"         "найти файлы с расширением .py"
printf "${I}%-24s${DIM}%s${RESET}\n"  "fd -t d"          "найти только директории"
printf "${I}%-24s${DIM}%s${RESET}\n"  "jq . file.json"   "красивый вывод JSON"
printf "${I}%-24s${DIM}%s${RESET}\n"  "jq '.key' f.json" "извлечь поле из JSON"

# ── БЛОК 7: МЕДИА ─────────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}${I}🖼  МЕДИА В ТЕРМИНАЛЕ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "chafa image.png"  "отобразить изображение в терминале"
printf "${I}%-24s${DIM}%s${RESET}\n"  "chafa -s 80x40"   "указать размер в символах"
printf "${I}%-24s${DIM}%s${RESET}\n"  "view-pdf doc.pdf" "постраничный просмотр PDF-файла"
printf "${I}%-24s${DIM}%s${RESET}\n"  "view-pdf --text"  "извлечь текстовый слой PDF"
printf "${I}%-24s${DIM}%s${RESET}\n"  "view-pdf --page N" "показать конкретную страницу"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Chafa умеет:"     "ANSI, Unicode, Sixel, Kitty graphics"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Sixel/Kitty:"     "включаются в iTerm2, WezTerm, foot..."

# ── БЛОК 8: TMUX ──────────────────────────────────────────────────────────────
printf "\n${BOLD}${BLUE}${I}🖥  TMUX — мультиплексор терминала${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "tmux"             "новая сессия"
printf "${I}%-24s${DIM}%s${RESET}\n"  "tmux new -s имя"  "сессия с именем"
printf "${I}%-24s${DIM}%s${RESET}\n"  "tmux ls"          "список сессий"
printf "${I}%-24s${DIM}%s${RESET}\n"  "tmux a -t имя"    "подключиться к сессии (attach)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Prefix = Ctrl+B"  "префикс-клавиша tmux"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Prefix + c"       "создать новое окно"
printf "${I}%-24s${DIM}%s${RESET}\n"  'Prefix + %'       "разделить вертикально (панели)"
printf "${I}%-24s${DIM}%s${RESET}\n"  'Prefix + "'       "разделить горизонтально"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Prefix + d"       "отсоединиться (detach), сессия жива"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Prefix + [число]" "переключить окно"

# ── БЛОК 9: ПОЛЕЗНЫЕ ФУНКЦИИ ──────────────────────────────────────────────────
printf "\n${BOLD}${BLUE}${I}🛠  ВСТРОЕННЫЕ ФУНКЦИИ${RESET}\n"
printf "${I}%-24s${DIM}%s${RESET}\n"  "extract <файл>"   "распаковать архив любого формата"
printf "${I}%-24s${DIM}%s${RESET}\n"  "mkcd <папка>"     "mkdir + cd в одной команде"
printf "${I}%-24s${DIM}%s${RESET}\n"  "myip"             "показать все IP-адреса машины"
printf "${I}%-24s${DIM}%s${RESET}\n"  "sysinfo"          "системная сводка одной командой"
printf "${I}%-24s${DIM}%s${RESET}\n"  "cheatsheet"       "показать эту памятку в любой момент"

# ── БЛОК 10: STARSHIP ─────────────────────────────────────────────────────────
printf "\n${BOLD}${MAGENTA}${I}⭐  STARSHIP ПРОМПТ${RESET}\n"
printf "${I}${DIM}%s${RESET}\n" "Строка приглашения показывает:"
printf "${I}%-24s${DIM}%s${RESET}\n"  "~ папка"          "текущая директория (обрезается до 4 уровней)"
printf "${I}%-24s${DIM}%s${RESET}\n"  "on ✚ ветка"       "git-ветка и статус изменений"
printf "${I}%-24s${DIM}%s${RESET}\n"  "🐍 3.11.x"        "версия Python в проекте"
printf "${I}%-24s${DIM}%s${RESET}\n"  " 20.x"           "версия Node.js"
printf "${I}%-24s${DIM}%s${RESET}\n"  "took 5s"          "время выполнения команды > 2 сек"
printf "${I}%-24s${DIM}%s${RESET}\n"  "❯ (зелёный)"     "последняя команда выполнена успешно"
printf "${I}%-24s${DIM}%s${RESET}\n"  "❯ (красный)"     "последняя команда завершилась с ошибкой"
printf "${I}%-24s${DIM}%s${RESET}\n"  "Конфиг:"          "/etc/starship/starship.toml"

# ── ПОДВАЛ ────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
printf "${DIM}${I}Памятка: cheatsheet  │  Системная сводка: sysinfo  │  Конфиг: /etc/bash.bashrc.d/99-server-init.sh${RESET}\n"
printf "${BOLD}${CYAN}%s${RESET}\n" "$LINE"
echo ""
MOTD

        chmod +x /etc/update-motd.d/99-cheatsheet
        log_ok "MOTD Cheatsheet создан: /etc/update-motd.d/99-cheatsheet"

        # Подключение алиаса cheatsheet уже добавлено в bashrc-блоке выше
        log_ok "Алиас 'cheatsheet' доступен для всех пользователей"
    else
        echo -e "  ${DIM}[dry-run] создан /etc/update-motd.d/99-cheatsheet${RESET}"
    fi
}

# ─── 7. Конфигурация tmux ─────────────────────────────────────────────────────
configure_tmux() {
    log_section "7 · Конфигурация tmux"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/tmux.conf << 'TMUX'
# ============================================================
#  /etc/tmux.conf — глобальная конфигурация tmux
# ============================================================

# ── Префикс-клавиша ──────────────────────────────────────────────────────────
# Оставляем Ctrl+B (стандарт), дополнительно добавляем Ctrl+A
set -g prefix C-b
bind-key C-a send-prefix

# ── Нумерация с 1 (проще на клавиатуре) ──────────────────────────────────────
set -g base-index 1
setw -g pane-base-index 1

# ── Быстрый рестарт конфига ──────────────────────────────────────────────────
bind r source-file /etc/tmux.conf \; display "Конфиг перезагружен"

# ── Разделение панелей (интуитивные клавиши) ─────────────────────────────────
bind | split-window -h -c "#{pane_current_path}"  # вертикально (|)
bind - split-window -v -c "#{pane_current_path}"  # горизонтально (-)
bind c new-window -c "#{pane_current_path}"        # новое окно в текущей папке

# ── Навигация по панелям через vim-стрелки ───────────────────────────────────
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# ── Изменение размера панелей ────────────────────────────────────────────────
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# ── 256 цветов и true color ───────────────────────────────────────────────────
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# ── История (scroll buffer) ───────────────────────────────────────────────────
set -g history-limit 50000

# ── Мышь (прокрутка, выбор панели, resize) ───────────────────────────────────
set -g mouse on

# ── Минимальная задержка ESC (полезно для Vim) ───────────────────────────────
set -sg escape-time 10

# ── Автоматическая нумерация окон при закрытии ───────────────────────────────
set -g renumber-windows on

# ── Статусная строка ──────────────────────────────────────────────────────────
set -g status-interval 5
set -g status-position bottom
set -g status-left-length 40
set -g status-right-length 80

set -g status-style "bg=#1e2030 fg=#c8d3f5"
set -g status-left "#[fg=#82aaff,bold] ❐ #S #[fg=#444a73]│ "
set -g status-right "#[fg=#444a73]│ #[fg=#c8d3f5]%H:%M #[fg=#444a73]│ #[fg=#82aaff]#{host_short} "

setw -g window-status-format " #I:#W "
setw -g window-status-current-format "#[fg=#82aaff,bold,bg=#2d3153] #I:#W #[default]"

# ── Подсветка активной панели ─────────────────────────────────────────────────
set -g pane-border-style "fg=#444a73"
set -g pane-active-border-style "fg=#82aaff"

# ── Vim-режим в copy-mode ─────────────────────────────────────────────────────
setw -g mode-keys vi
bind Enter copy-mode
bind -T copy-mode-vi v send-keys -X begin-selection
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
TMUX

        log_ok "Конфигурация tmux создана: /etc/tmux.conf"
    else
        echo -e "  ${DIM}[dry-run] создан /etc/tmux.conf${RESET}"
    fi
}

# ─── 8. Конфигурация nano (минимальный комфорт) ────────────────────────────────
configure_nano() {
    log_section "8 · Конфигурация nano"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/nanorc << 'NANO'
# /etc/nanorc — глобальная конфигурация nano

set autoindent         # автоотступы
set tabsize 4          # размер таба = 4 пробела
set tabstospaces       # таб → пробелы
set linenumbers        # номера строк
set mouse              # поддержка мыши
set smooth             # плавная прокрутка
set cutfromcursor      # Ctrl+K срезает от курсора
set casesensitive      # поиск с учётом регистра
set historylog         # история поиска

# Syntax highlighting
include "/usr/share/nano/*.nanorc"
NANO

        log_ok "Конфигурация nano создана: /etc/nanorc"
    else
        echo -e "  ${DIM}[dry-run] создан /etc/nanorc${RESET}"
    fi
}

# ─── 9. Итоговая проверка ─────────────────────────────────────────────────────
verify_installation() {
    log_section "9 · Итоговая проверка"

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
    )

    local all_ok=true
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
            all_ok=false
        fi
    done

    echo ""
    if [[ "$all_ok" == "true" ]]; then
        log_ok "Все утилиты установлены успешно"
    else
        log_warn "Некоторые утилиты не были установлены — проверьте логи выше"
    fi

    # Проверка конфигов
    echo ""
    local configs=(
        "/etc/bash.bashrc.d/99-server-init.sh"
        "/etc/update-motd.d/99-cheatsheet"
        "/usr/local/bin/view-pdf"
        "/etc/tmux.conf"
        "/etc/starship/starship.toml"
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
  │  1. Таймзона → Europe/Moscow, NTP синхронизация                     │
  │  2. Локали: LANG=en_US.UTF-8 + ru_RU.UTF-8                         │
  │  3. CLI-стек: btop, htop, ncdu, rg, fd, jq, tmux, fzf, zoxide      │
  │  4. Промпт starship с git, языками и временем выполнения            │
  │  5. view-pdf: просмотр PDF в терминале (графика + текст)            │
  │  6. chafa: отображение изображений в SSH-сессии                     │
  │  7. MOTD cheatsheet при логине + алиас cheatsheet                   │
  │  8. Глобальный .bashrc.d: алиасы, горячие клавиши, функции         │
  │  9. Конфигурация tmux с vim-клавишами и статусной строкой           │
  └─────────────────────────────────────────────────────────────────────┘

SUMMARY

    echo -e "  ${BOLD}${GREEN}Следующие шаги:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Перезайдите в SSH или выполните: ${BOLD}source /etc/bash.bashrc${RESET}"
    echo -e "  ${CYAN}2.${RESET} Попробуйте памятку:              ${BOLD}cheatsheet${RESET}"
    echo -e "  ${CYAN}3.${RESET} Проверьте промпт starship:       ${BOLD}exec bash${RESET}"
    echo -e "  ${CYAN}4.${RESET} Откройте PDF:                    ${BOLD}view-pdf file.pdf${RESET}"
    echo -e "  ${CYAN}5.${RESET} Покажите изображение:            ${BOLD}chafa image.png${RESET}"
    echo ""
}

# ─── Главная точка входа ──────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║   🛠  server-init.sh — инициализация Linux-сервера       ║"
    echo "  ║   Debian/Ubuntu · Terminal Ergonomics Setup              ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}⚠  РЕЖИМ DRY-RUN: реальных изменений не будет${RESET}"
        echo ""
    fi

    preflight_checks
    setup_system
    install_packages
    install_view_pdf
    configure_bash
    configure_starship
    install_motd
    configure_tmux
    configure_nano
    verify_installation
    print_summary
}

main "$@"
