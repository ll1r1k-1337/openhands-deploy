#!/bin/bash
set -e

# Цвета для удобства чтения
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}    Автоматическое развертывание OpenHands       ${NC}"
echo -e "${BLUE}=================================================${NC}\n"

# 1. Проверка зависимостей
if ! command -v uv &> /dev/null; then
    echo -e "${RED}❌ Ошибка: uv не установлен. Установите uv перед запуском.${NC}"
    exit 1
fi
if ! command -v openssl &> /dev/null; then
    echo -e "${RED}❌ Ошибка: OpenSSL не установлен. Пожалуйста, установите OpenSSL.${NC}"
    exit 1
fi

# 2. Ввод данных от пользователя
read -p "🌐 Введите внешний IP-адрес сервера или домен: " DOMAIN_OR_IP
if [ -z "$DOMAIN_OR_IP" ]; then
    echo -e "${RED}❌ Ошибка: IP/домен не может быть пустым!${NC}"
    exit 1
fi

read -p "👤 Введите логин для входа [по умолчанию: admin]: " USERNAME
USERNAME=${USERNAME:-admin}

while true; do
    read -s -p "🔑 Придумайте пароль: " ADMIN_PASS
    echo
    read -s -p "🔑 Повторите пароль: " ADMIN_PASS_CONFIRM
    echo
    if [ -z "$ADMIN_PASS" ]; then
        echo -e "${RED}❌ Ошибка: Пароль не может быть пустым!${NC}"
    elif [ "$ADMIN_PASS" != "$ADMIN_PASS_CONFIRM" ]; then
        echo -e "${RED}❌ Ошибка: Пароли не совпадают! Попробуйте снова.${NC}"
    else
        break
    fi
done

# 3. Настройка директорий
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$HOME/openhands-deploy"
WORKSPACE_DIR="$DEPLOY_DIR/workspace"

echo -e "\n${YELLOW}[1/6] Создание структуры папок в $DEPLOY_DIR...${NC}"
mkdir -p "$DEPLOY_DIR"/{ssl,nginx,workspace}
# Do not change directory permanently if it complicates relative paths, 
# or just use absolute paths. 
# Let's keep the cd but fix the references.

# 4. Генерация SSL-сертификата
echo -e "${YELLOW}[2/6] Генерация самоподписанного SSL-сертификата...${NC}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$DEPLOY_DIR/ssl/openhands.key" \
  -out "$DEPLOY_DIR/ssl/openhands.crt" \
  -subj "/C=RU/O=OpenHands/CN=$DOMAIN_OR_IP" 2>/dev/null

# 5. Генерация файла паролей (.htpasswd)
echo -e "${YELLOW}[3/6] Настройка базовой HTTP-авторизации...${NC}"
# Используем openssl для генерации хэша
# Changed -crypt to -1 (MD5 crypt) or try to detect
printf "%s:%s\n" "$USERNAME" "$(openssl passwd -1 "$ADMIN_PASS")" > "$DEPLOY_DIR/nginx/.htpasswd"

# 6. Создание .env файла
echo -e "${YELLOW}[4/6] Создание .env файла...${NC}"
cat << EOF > "$DEPLOY_DIR/.env"
DOMAIN_OR_IP=$DOMAIN_OR_IP
WORKSPACE_BASE=$WORKSPACE_DIR
EOF

# 7. Генерация конфига Nginx
echo -e "${YELLOW}[5/6] Создание конфигурации Nginx...${NC}"
read -p "📂 Введите basepath для Nginx [по умолчанию: /openhands]: " BASE_PATH
BASE_PATH=${BASE_PATH:-/openhands}
export BASE_PATH
envsubst < "$SCRIPT_DIR/templates/nginx.conf.template" > "$DEPLOY_DIR/nginx/nginx.conf"

# 8. Развертывание приложения через uv
echo -e "${YELLOW}[6/6] Развертывание OpenHands через uv...${NC}"
# Устанавливаем и запускаем OpenHands через uv
# Примечание: Убедитесь, что необходимый репозиторий или пакет доступен
cd "$DEPLOY_DIR"
# Create a virtual environment for openhands to ensure it can be found
uv venv .venv
# Source the venv, but we need to make sure the script continues or runs within this context
# On CI, "source" might be tricky inside a subshell, so we might need to rely on uv explicitly.
# Instead of source, just use uv run directly which should handle venv.
if uv pip install openhands &>/dev/null; then
    uv run python -m openhands.app &
else
    echo -e "${RED}❌ Ошибка: Не удалось запустить OpenHands.${NC}"
fi





echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}✅ Установка успешно завершена!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "🌐 Адрес для входа:      ${BLUE}https://$DOMAIN_OR_IP${NC}"
echo -e "👤 Логин:                ${YELLOW}$USERNAME${NC}"
echo -e "📂 Рабочая папка агента: ${YELLOW}$WORKSPACE_DIR${NC}"
echo -e "----------------------------------------------------------------"
echo -e "${RED}⚠️ ВАЖНОЕ ЗАМЕЧАНИЕ ПО БЕЗОПАСНОСТИ БРАУЗЕРА:${NC}"
echo -e "При первом переходе по ссылке браузер выдаст ошибку сертификата (т.к. он самоподписанный)."
echo -e "👉 ${YELLOW}В Chrome / Яндекс / Edge:${NC} кликните левой кнопкой мыши по пустому месту"
echo -e "   на странице с ошибкой, переключитесь на английскую раскладку и"
echo -e "   вслепую напечатайте слово ${YELLOW}thisisunsafe${NC} (без пробелов)."
echo -e "👉 ${YELLOW}В Firefox:${NC} нажмите 'Дополнительно' -> 'Принять риск и продолжить'."
echo -e "================================================================\n"
