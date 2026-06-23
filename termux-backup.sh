#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# Полный бэкап/восстановление Termux с шифрованием (AES-256)
# Версия 2.0 — с pbkdf2, прогресс-баром и проверками
# ============================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Проверка необходимых утилит
check_deps() {
    for cmd in tar openssl; do
        if ! command -v $cmd &>/dev/null; then
            error "$cmd не найдена. Установите: pkg install $cmd"
        fi
    done
    # Проверяем pv (для прогресса)
    if ! command -v pv &>/dev/null; then
        warn "pv не установлен. Будет использован встроенный прогресс."
        read -p "Установить pv для красивого прогресс-бара? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            pkg install -y pv || warn "Не удалось установить pv, продолжаем без него."
        fi
    fi
}

# Проверка свободного места (нужно ~2x от размера данных)
check_space() {
    local needed=$1
    local available=$(df -P /data | awk 'NR==2 {print $4}')
    available=$((available * 1024)) # в байтах
    if [ $available -lt $needed ]; then
        error "Недостаточно места. Нужно ~$(numfmt --to=iec $needed), доступно $(numfmt --to=iec $available)"
    fi
}

# ------------------- БЭКАП -------------------
do_backup() {
    info "Начинаем создание полного бэкапа Termux..."

    # Определяем директорию сохранения
    if [ ! -d ~/storage ]; then
        warn "~/storage не найдена. Запустите termux-setup-storage"
        read -p "Продолжить без сохранения на внешнее хранилище? (y/N) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
        BACKUP_DIR="$HOME/backup_temp_$(date +%Y%m%d_%H%M%S)"
    else
        BACKUP_DIR="$HOME/storage/downloads/termux_backup_$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$BACKUP_DIR" || error "Не удалось создать $BACKUP_DIR"

    TMP_DIR=$(mktemp -d)
    info "Временная папка: $TMP_DIR"

    # 1. Список пакетов
    info "Сохранение списка пакетов..."
    pkg list-installed > "$TMP_DIR/packages.list" 2>/dev/null || \
        dpkg -l > "$TMP_DIR/packages.list" 2>/dev/null || \
        error "Не удалось получить список пакетов."

    # 2. Конфиги .termux
    info "Сохранение конфигураций..."
    mkdir -p "$TMP_DIR/config"
    [ -d ~/.termux ] && cp -r ~/.termux "$TMP_DIR/config/"

    # 3. Оценка размера для проверки места
    info "Оценка размера данных..."
    SIZE=$(du -sb /data/data/com.termux/files/home /data/data/com.termux/files/usr 2>/dev/null | awk '{sum+=$1} END {print sum}')
    SIZE=$((SIZE + 50*1024*1024)) # +50MB на метаданные
    check_space $SIZE

    # 4. Архивация с прогрессом
    info "Архивация /home и /usr (может занять время)..."
    cd /data/data/com.termux/files
    if command -v pv &>/dev/null; then
        tar -cf - home usr 2>/dev/null | pv -s $SIZE -p -e -r -b > "$TMP_DIR/termux_system.tar"
    else
        tar -cf "$TMP_DIR/termux_system.tar" \
            --checkpoint=1000 \
            --checkpoint-action='echo=# %u' \
            home usr 2>/dev/null || error "Ошибка создания архива."
    fi

    # Добавляем в архив дополнительные файлы
    cd "$TMP_DIR"
    tar -rf termux_system.tar packages.list config 2>/dev/null

    # Сжатие с прогрессом
    info "Сжатие архива..."
    if command -v pv &>/dev/null; then
        pv termux_system.tar | gzip > termux_system.tar.gz
    else
        gzip -v termux_system.tar
    fi
    ARCHIVE="$TMP_DIR/termux_system.tar.gz"

    # Шифрование
    info "Шифрование архива (AES-256-CBC с pbkdf2)..."
    read -s -p "Введите пароль: " PASS1; echo
    read -s -p "Повторите пароль: " PASS2; echo
    [[ "$PASS1" != "$PASS2" ]] && error "Пароли не совпадают."

    if command -v pv &>/dev/null; then
        pv "$ARCHIVE" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
            -out "$BACKUP_DIR/termux_backup.enc" -pass pass:"$PASS1"
    else
        openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
            -in "$ARCHIVE" -out "$BACKUP_DIR/termux_backup.enc" -pass pass:"$PASS1"
    fi

    # Очистка
    rm -rf "$TMP_DIR"

    info "✅ Бэкап создан: $BACKUP_DIR/termux_backup.enc"
    info "Размер: $(du -h "$BACKUP_DIR/termux_backup.enc" | cut -f1)"
    info "Пароль: (запомните его!)"
    info "Сохраните файл и скрипт на новом устройстве для восстановления."
}

# ------------------- ВОССТАНОВЛЕНИЕ -------------------
do_restore() {
    info "Восстановление из зашифрованного бэкапа."
    read -p "Путь к файлу .enc: " ENC_FILE
    [[ ! -f "$ENC_FILE" ]] && error "Файл не найден."

    read -s -p "Введите пароль: " PASS; echo

    TMP_DIR=$(mktemp -d)
    info "Расшифровка..."
    if command -v pv &>/dev/null; then
        pv "$ENC_FILE" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
            -out "$TMP_DIR/termux_system.tar.gz" -pass pass:"$PASS"
    else
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
            -in "$ENC_FILE" -out "$TMP_DIR/termux_system.tar.gz" -pass pass:"$PASS"
    fi

    # Проверяем, что распаковалось
    if [ ! -s "$TMP_DIR/termux_system.tar.gz" ]; then
        error "Расшифровка не удалась (возможно неверный пароль или повреждённый файл)"
    fi

    info "Распаковка в /data/data/com.termux/files..."
    cd /data/data/com.termux/files
    if command -v pv &>/dev/null; then
        pv "$TMP_DIR/termux_system.tar.gz" | tar -xz --overwrite
    else
        tar -xzf "$TMP_DIR/termux_system.tar.gz" --overwrite
    fi

    # Восстановление пакетов
    if [ -f "$TMP_DIR/packages.list" ]; then
        read -p "Установить пакеты из бэкапа? (y/N) " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Установка пакетов..."
            grep -vE "^(Package:| |$)" "$TMP_DIR/packages.list" | while read pkg; do
                pkg install -y "$pkg" 2>/dev/null || warn "Не удалось установить $pkg"
            done
        fi
    fi

    # Восстановление конфигов .termux
    [ -d "$TMP_DIR/config/.termux" ] && cp -r "$TMP_DIR/config/.termux" ~/

    rm -rf "$TMP_DIR"
    info "✅ Восстановление завершено! Перезапустите Termux (через уведомление или exit)."
}

# ------------------- ТОЧКА ВХОДА -------------------
main() {
    check_deps
    case "$1" in
        backup)  do_backup ;;
        restore) do_restore ;;
        *)
            echo "Использование: $0 {backup|restore}"
            exit 1
            ;;
    esac
}

main "$@"
