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
if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Ошибка: Docker не установлен. Установите Docker перед запуском.${NC}"
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
DEPLOY_DIR="$HOME/openhands-deploy"
WORKSPACE_DIR="$DEPLOY_DIR/workspace"

echo -e "\n${YELLOW}[1/6] Создание структуры папок в $DEPLOY_DIR...${NC}"
mkdir -p "$DEPLOY_DIR"/{ssl,nginx,workspace}
cd "$DEPLOY_DIR"

# 4. Генерация SSL-сертификата
echo -e "${YELLOW}[2/6] Генерация самоподписанного SSL-сертификата...${NC}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout ssl/openhands.key \
  -out ssl/openhands.crt \
  -subj "/C=RU/O=OpenHands/CN=$DOMAIN_OR_IP" 2>/dev/null

# 5. Генерация файла паролей (.htpasswd)
echo -e "${YELLOW}[3/6] Настройка базовой HTTP-авторизации...${NC}"
# Используем легковесный образ httpd для генерации хэша, чтобы не мусорить пакетами в системе
docker run --rm httpd:alpine htpasswd -bn "$USERNAME" "$ADMIN_PASS" > nginx/.htpasswd

# 6. Создание .env файла
echo -e "${YELLOW}[4/6] Создание .env файла...${NC}"
cat << EOF > .env
DOMAIN_OR_IP=$DOMAIN_OR_IP
WORKSPACE_BASE=$WORKSPACE_DIR
EOF

# 7. Генерация конфига Nginx
echo -e "${YELLOW}[5/6] Создание конфигурации Nginx...${NC}"
cat << 'EOF' > nginx/nginx.conf
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate /etc/nginx/ssl/openhands.crt;
        ssl_certificate_key /etc/nginx/ssl/openhands.key;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        auth_basic "Restricted Access to OpenHands";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Убираем таймауты, чтобы сессия не рвалась, пока ИИ выполняет долгую задачу
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;

        location / {
            proxy_pass http://openhands:3000;
        }

        # Маршрутизация к динамическим портам песочниц
        location ~ ^/sandbox/(?<sandbox_port>\d+)/(.*)$ {
            proxy_pass http://host.docker.internal:$sandbox_port/$2$is_args$args;
        }

        location ~ ^/sandbox/(?<sandbox_port>\d+)$ {
            proxy_pass http://host.docker.internal:$sandbox_port/;
        }
    }
}
EOF

# 8. Создание docker-compose.yml
echo -e "${YELLOW}[6/6] Создание docker-compose.yml...${NC}"
cat << 'EOF' > docker-compose.yml
services:
  openhands:
    image: ghcr.io/openhands/openhands:main
    container_name: openhands
    environment:
      - WORKSPACE_MOUNT_PATH=${WORKSPACE_BASE}
      - OH_WEB_URL=https://${DOMAIN_OR_IP}
      - SANDBOX_CONTAINER_URL_PATTERN=https://${DOMAIN_OR_IP}/sandbox/{port}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ~/.openhands-state:/.openhands-state
      - ${WORKSPACE_BASE}:/opt/workspace_base
    extra_hosts:
      - "host.docker.internal:host-gateway"
    stdin_open: true
    tty: true
    pull_policy: always
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    container_name: openhands-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./nginx/.htpasswd:/etc/nginx/.htpasswd:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - openhands
    restart: unless-stopped
EOF

# 9. Запуск
echo -e "\n${GREEN}🚀 Запуск контейнеров (при первом запуске скачивание образов займет несколько минут)...${NC}"
if docker compose version &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
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
