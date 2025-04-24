#!/bin/bash
# Логирование всего вывода в файл
LOGFILE="$HOME/fastpanel_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === UI-функции ===
info()    { echo -e "${BLUE}➤ $1${NC}"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "${RED}✖ $1${NC}" >&2; }
pause()   { read -rp "🔸 Нажмите Enter для продолжения..."; }
confirm() {
    read -rp "❓ $1 [y/N]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# === Переменные ===
HOME_DIR="$HOME/fastpaneltmp"
SCRIPT_FILE="$HOME_DIR/install_fastpanel.sh"
paneluser="adminpanel"
mailuser="mailpanel"
OLD_INSTALL_CMD='    apt-get install -qq -y fastpanel2 || InstallationFailed'
LOCK_FILES=(
    "/var/lib/apt/lists/lock"
    "/var/lib/dpkg/lock"
    "/var/lib/dpkg/lock-frontend"
    "/var/cache/apt/archives/lock"
)

# === Разблокировка APT ===
function unlock_Files {
    info "Проверка заблокированных APT-файлов..."
    for LOCK in "${LOCK_FILES[@]}"; do
        if [ -f "$LOCK" ]; then
            warning "Lock-файл найден: $LOCK"
            PID=$(lsof "$LOCK" 2>/dev/null | awk 'NR==2 {print $2}')
            if [ -n "$PID" ]; then
                info "Процесс удерживает файл: PID=$PID ($(ps -p $PID -o cmd=))"
                ELAPSED=$(ps -p "$PID" -o etimes=)
                if [ "$ELAPSED" -gt 120 ]; then
                    warning "Процесс завис. Завершаем $PID..."
                    sudo kill -9 "$PID"
                else
                    warning "Процесс свежий, лучше подождать."
                    continue
                fi
            fi
            sudo rm -f "$LOCK"
            success "Удалён: $LOCK"
        fi
    done
    sudo dpkg --configure -a
    sudo apt update
    success "APT разблокирован"
    pause
}

# === Удаление конфликтных пакетов ===
function uninstall_pack {
    info "Проверка установленных сервисов..."
    for package in nginx apache2 fastpanel2 mysql-server mariadb-server percona-server-server percona-server-server-5.6 percona-server-server-5.7; do
        if dpkg -l "$package" 2>/dev/null | grep -q '^ii'; then
            warning "Обнаружен: $package"
            if confirm "Удалить $package?"; then
                sudo apt-get remove --purge -y "$package"
                success "Удалено: $package"
            else
                info "Пропущено: $package"
            fi
        else
            success "Не найден: $package"
        fi
    done
    sudo apt-get autoremove --purge -y
    sudo apt-get autoclean
    success "Очистка завершена"
    pause
}

# === Сборка модифицированного install_fastpanel.sh ===
function set_new_cmd {
    read -r -d '' NEW_INSTALL_CMD <<EOF
sudo apt-get update
sudo apt-get install -y dpkg-dev devscripts build-essential
sudo apt-get install --download-only fastpanel2 -f -y
Message "Разбор пакета..."
sudo dpkg-deb -R "\$(ls /var/cache/apt/archives/fastpanel2_1*.deb | head -n 1)" $HOME_DIR
Message "Внесение изменений..."
sed -i "s/fastuser/$paneluser/g" $HOME_DIR/etc/init.d/fastpanel2
sed -i "s/passwd fastmail/passwd \\\`generatePassword\\\`/" $HOME_DIR/DEBIAN/postinst
sed -i "s/--system fastmail/--system $mailuser/" $HOME_DIR/DEBIAN/postinst
sed -i "s/--username=fastuser/--username=$paneluser/" $HOME_DIR/DEBIAN/postinst
Message "Сборка пакета..."
sudo dpkg-deb -b $HOME_DIR $HOME_DIR/fastpanel2_modified.deb
Message "Установка зависимостей..."
sudo dpkg --configure -a
sudo apt update
sudo dpkg -i $HOME_DIR/fastpanel2_modified.deb
sudo apt-get install -f -y
EOF
}

function check_script_update{
# === Автообновление скрипта ===
REMOTE_URL="https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install_fastpanel_custom.sh"
SELF_PATH="$(realpath "$0")"

info "Проверка наличия обновлений..."

REMOTE_HASH=$(curl -s "$REMOTE_URL" | sha256sum | awk '{print $1}')
LOCAL_HASH=$(sha256sum "$SELF_PATH" | awk '{print $1}')

if [ "$REMOTE_HASH" != "$LOCAL_HASH" ]; then
    warning "Доступна новая версия скрипта!"
    if confirm "Обновить скрипт сейчас?"; then
        curl -s "$REMOTE_URL" -o "$SELF_PATH"
        chmod +x "$SELF_PATH"
        success "Скрипт обновлён. Перезапуск..."
        exec "$SELF_PATH" "$@"
        exit 0
    else
        warning "Вы используете устаревшую версию. Продолжаем..."
    fi
else
    success "У вас последняя версия скрипта."
fi
}

# === Главный процесс ===
check_script_update
unlock_Files
uninstall_pack

# Подготовка директории
info "Подготовка временной директории..."
rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR"

# Загрузка скрипта
info "Загрузка оригинального install_fastpanel.sh"
if ! wget --quiet https://repo.fastpanel.direct/install/debian.sh -O "$SCRIPT_FILE"; then
    error "Не удалось загрузить скрипт установки FastPanel"
    exit 1
fi
success "Скрипт загружен"

# Модификация
info "Модификация скрипта"
sed -i "s/chpasswd -u fastuser/chpasswd -u $paneluser/" "$SCRIPT_FILE"
sed -i 's/PACKAGES="nginx apache2 "/local PACKAGES="nginx "/' "$SCRIPT_FILE"
sed -i "s/Debug/Message/g"

set_new_cmd

TMP_SCRIPT="$SCRIPT_FILE.tmp"
touch "$TMP_SCRIPT"

while IFS= read -r line; do
    if [[ "$line" == "$OLD_INSTALL_CMD" ]]; then
        echo "$NEW_INSTALL_CMD" >> "$TMP_SCRIPT"
    else
        echo "$line" >> "$TMP_SCRIPT"
    fi
done < "$SCRIPT_FILE"

mv "$TMP_SCRIPT" "$SCRIPT_FILE"
success "Скрипт модифицирован"

# Запуск
if confirm "Готовы начать установку модифицированного FastPanel?"; then
    sudo bash "$SCRIPT_FILE"
else
    info "Установка отменена пользователем."
    exit 0
fi

