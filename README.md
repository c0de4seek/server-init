# 🛠 server-init.sh

**Универсальный bash-скрипт первичной инициализации Linux-сервера** — превращает «чистый» VPS в защищённый, оптимизированный и эргономичный инструмент для работы.

---

## ⚡ Быстрый старт

```bash
# Скачать и запустить одной командой
curl -fsSL https://raw.githubusercontent.com/c0de4seek/server-init/master/server-init.sh | sudo bash

# Добавить дополнительный SSH-ключ при запуске
curl -fsSL https://raw.githubusercontent.com/c0de4seek/server-init/master/server-init.sh | sudo bash -s -- --ssh-key "ssh-ed25519 AAAA..."

# Предпросмотр без внесения изменений
sudo bash server-init.sh --dry-run
```

После выполнения — **перезайдите в SSH** или выполните `source /etc/profile`.

---

## 🐧 Поддерживаемые дистрибутивы

| Семейство | Дистрибутивы | Пакетный менеджер | Доп. репозитории |
|-----------|--------------|-------------------|------------------|
| **Debian** | Debian 11/12/13, Ubuntu 20.04+, Mint, Kali, Pop!_OS | `apt` | `contrib`, `non-free`, `non-free-firmware`, `backports` (`archive.debian.org` для Debian 11) |
| **RHEL** | RHEL, CentOS, AlmaLinux, Rocky, Oracle, Fedora, Amazon Linux | `dnf` / `yum` | `EPEL` + `CRB` / `PowerTools` |
| **Arch** | Arch Linux, Manjaro, EndeavourOS, Garuda | `pacman` | — |
| **Alpine** | Alpine Linux (OpenRC) | `apk` | `community` + `sshguard` |
| **SUSE** | openSUSE Leap / Tumbleweed | `zypper` | — |

---

## 📦 Что устанавливается и настраивается

### 1. Системная подготовка и оптимизация VPS
| Компонент | Что делает |
|-----------|------------|
| **Таймзона и NTP** | `Europe/Moscow` + `systemd-timesyncd` (российские и европейские пулы) / `chronyd` |
| **Локали** | `LANG=en_US.UTF-8` (основная, без багов кодировки) + `ru_RU.UTF-8` (формат дат и чисел) |
| **Лимит `journald`** | `/etc/systemd/journald.conf.d/99-server-init.conf` — `SystemMaxUse=200M` |
| **Авто-Swap** | Автоматически создаёт и подключает `/swapfile` на **2 ГБ**, если swap отсутствует и ОЗУ ≤ 4 ГБ |
| **TCP BBR + sysctl** | `/etc/sysctl.d/99-server-init.conf` — включает `bbr` + `fq`, `vm.swappiness=10`, базовую сетевую защиту |

### 2. Безопасность: SSH-ключи, Hardening и Fail2ban

#### Автоматическая установка SSH-ключей
- Автоматически прописывает встроенные публичные ключи владельца (`ed25519` + `RSA KostiaevVI`) в `~/.ssh/authorized_keys` для `root` и `$SUDO_USER`.
- Разделяет «слипшиеся» на одной строке ключи, удаляет мусорные строки (например, от роутеров Keenetic/панелей) и дедуплицирует записи.
- Выставляет строгие права `700` на `~/.ssh` и `600` на `authorized_keys`.

#### SSH Hardening
- Записывает приоритетный конфиг `/etc/ssh/sshd_config.d/00-server-init.conf` (перекрывая `50-cloud-init.conf` от хостера) и обновляет `/etc/ssh/sshd_config`:
  - `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `PubkeyAuthentication yes`
  - `MaxAuthTries 2`, `MaxStartups 3:50:10`, `LoginGraceTime 20`
- Проверяет валидность через `sshd -t` перед перезагрузкой с автоматическим откатом при ошибке.

#### Fail2ban (защита от распределённых и медленных ботнетов)
- Автоматически определяет фаервол (`nftables-multiport` или `iptables-multiport`) и источник логов (`systemd` journal или `/var/log/auth.log`).
- **`[DEFAULT]`**: прогрессивное увеличение времени бана (`bantime.increment = true`, `bantime.factor = 2`, `bantime.maxtime = 5w`) и случайный разброс времени разбана (`bantime.rndtime = 15m`) против синхронизированных таймеров ботов.
- **`[sshd]`**: `mode = aggressive` (блокирует также preauth-сканеры), `maxretry = 2` (бан с первого же подключения бота из 2 событий `Found`), `findtime = 1h`, базовый `bantime = 4h`.
- **`[recidive]`**: 3 бана за 7 дней (`findtime = 7d`, `maxretry = 3`) → полная блокировка всех портов на **4 недели** (`bantime = 4w`).

### 3. CLI-стек

| Утилита | Назначение |
|---------|------------|
| `btop` | Мониторинг CPU/RAM/диск/сеть в реальном времени |
| `htop` | Классический интерактивный просмотр процессов |
| `ncdu` | ncurses-визуализатор дискового пространства |
| `ripgrep` (`rg`) | Сверхбыстрая замена `grep` с поддержкой regex |
| `fd-find` (`fd`) | Современная замена `find` |
| `jq` | Обработка и форматирование JSON |
| `tmux` | Мультиплексор терминала: окна, панели, сессии |
| `fzf` | Интерактивный fuzzy-поиск по истории и файлам |
| `zoxide` | Умный `cd`: запоминает часто посещаемые директории |
| `starship` | Быстрый информативный shell-промпт |
| `chafa` | Рендеринг изображений прямо в терминале по SSH |
| `bat` / `batcat` | `cat` с подсветкой синтаксиса |
| `eza` / `exa` | Современная замена `ls` с иконками и git-статусом |

### 4. Утилита `view-pdf`

Просмотр PDF-файлов в терминале без GUI:

```bash
view-pdf doc.pdf              # постраничный графический просмотр (pdftoppm + chafa)
view-pdf doc.pdf --text       # извлечение текстового слоя (pdftotext)
view-pdf doc.pdf --page 3     # конкретная страница
view-pdf doc.pdf --width 120  # ширина в символах
view-pdf doc.pdf --dpi 200    # DPI рендеринга (по умолчанию: 150)
```

### 5. Эргономика Bash и MOTD Cheatsheet

#### Алиасы и функции
```bash
..          # cd ..
...         # cd ../..
-           # cd - (вернуться назад)
please      # sudo <последняя команда>
mkcd <dir>  # mkdir + cd
extract <f> # распаковать архив любого формата
myip        # показать внутренний и внешний IP
sysinfo     # краткая системная сводка
cheatsheet  # вызвать полную памятку (/usr/local/bin/cheatsheet)
```

#### Горячие клавиши
| Сочетание | Действие |
|-----------|----------|
| `Ctrl+A` / `Home` | В начало строки |
| `Ctrl+E` / `End` | В конец строки |
| `Alt+B` / `Alt+F` | Назад/вперёд на слово |
| `Ctrl+W` | Удалить слово слева |
| `Ctrl+U` / `Ctrl+K` | Удалить до начала / до конца строки |
| `Ctrl+Y` | Вставить удалённое (yank) |
| `Ctrl+_` | Отменить (undo) |
| `Ctrl+R` | Поиск по истории (через `fzf`) |
| `Ctrl+T` / `Alt+C` | Вставить файл / перейти в папку через `fzf` |
| `Alt+.` | Вставить последний аргумент |
| `Ctrl+X Ctrl+E` | Открыть текущую команду в `$EDITOR` |
| `↑` / `↓` | История с фильтром по набранному префиксу |

---

## 🗂 Созданные файлы

| Файл | Назначение |
|------|------------|
| `/etc/profile.d/99-server-init.sh` | Глобальная конфигурация bash (алиасы, функции, интеграции) |
| `/usr/local/bin/cheatsheet` | Утилита вывода системной сводки и шпаргалки |
| `/usr/local/bin/view-pdf` | Утилита просмотра PDF в терминале |
| `/etc/starship/starship.toml` | Конфигурация Starship промпта |
| `/etc/tmux.conf` | Конфигурация tmux |
| `/etc/nanorc` | Настройки редактора nano |
| `/etc/sysctl.d/99-server-init.conf` | Конфигурация TCP BBR и параметров ядра |
| `/etc/systemd/journald.conf.d/99-server-init.conf` | Ограничение логов systemd-journald (200 МБ) |
| `/etc/ssh/sshd_config.d/00-server-init.conf` | Приоритетный конфиг SSH hardening |
| `/etc/fail2ban/jail.local` | Конфигурация Fail2ban (`sshd` aggressive + `recidive`) |

---

## 🔧 Аргументы командной строки

```text
sudo bash server-init.sh [опции]

  --dry-run            Показать что будет сделано без реальных изменений
  --skip-packages      Пропустить установку пакетов (только конфиги)
  --ssh-key "<ключ>"   Добавить дополнительный публичный SSH-ключ
  --replace-keys       Заменить authorized_keys только ключами из скрипта
  --help, -h           Показать справку
```
