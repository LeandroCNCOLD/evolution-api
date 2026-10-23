#!/usr/bin/env bash
# =============================================================================
# CN Cold WhatsApp — instalação do servidor (Evolution API + Postgres + Redis + HTTPS)
#
# Uso (como root, no terminal da VPS):
#   bash install.sh whatsapp.cncold.tech [email-opcional-para-o-certificado]
#
# O que faz:
#   1. Instala o Docker (se faltar) e libera só as portas 22, 80 e 443.
#   2. Cria /opt/cncold-whatsapp com senhas e chave de API fortes, geradas aqui.
#   3. Sobe Evolution API 2.3.7, Postgres 16, Redis 7 e Caddy (HTTPS automático).
#   4. Agenda backup diário do banco (guarda 14 dias).
#
# Pode rodar de novo sem perder nada: senhas já criadas são mantidas.
# Antes de rodar: o DNS do domínio (registro A) precisa apontar para o IP desta VPS.
# =============================================================================
set -euo pipefail

DOMINIO="${1:-}"
EMAIL="${2:-}"
PASTA="${CNCOLD_DIR:-/opt/cncold-whatsapp}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"   # 1 = só gera os arquivos (usado em testes)
EVOLUTION_VERSAO="v2.3.7"

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
erro()  { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "$DOMINIO" ]] || read -rp "Domínio (ex.: whatsapp.cncold.com.br): " DOMINIO
[[ "$DOMINIO" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || erro "domínio inválido: $DOMINIO"
[[ -z "$EMAIL" || "$EMAIL" == *@* ]] || erro "e-mail inválido: $EMAIL"

if [[ "$SKIP_DOCKER" != "1" ]]; then
  [[ $EUID -eq 0 ]] || erro "rode como root (sudo bash install.sh ...)"
fi

segredo() { openssl rand -hex "${1:-32}"; }

# --- 1. Docker e firewall ----------------------------------------------------
if [[ "$SKIP_DOCKER" != "1" ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    azul "Instalando Docker..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    if ! apt-get install -y docker.io docker-compose-v2; then
      curl -fsSL https://get.docker.com | sh
    fi
    systemctl enable --now docker
  fi
  docker compose version >/dev/null 2>&1 || erro "docker compose não encontrado"

  if command -v ufw >/dev/null 2>&1; then
    azul "Configurando firewall (22, 80, 443)..."
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw --force enable >/dev/null
  fi
fi

# --- 2. Pasta e segredos -----------------------------------------------------
mkdir -p "$PASTA/backups"
chmod 700 "$PASTA"
cd "$PASTA"

if [[ -f .env ]]; then
  azul "Mantendo senhas existentes de $PASTA/.env"
  POSTGRES_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2- || true)"
  AUTHENTICATION_API_KEY="$(grep -E '^AUTHENTICATION_API_KEY=' .env | cut -d= -f2- || true)"
fi
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(segredo 24)}"
EVOLUTION_API_KEY="${AUTHENTICATION_API_KEY:-$(segredo 32)}"

cat > .env <<EOF
# Gerado por install.sh em $(date -Iseconds). NÃO compartilhe este arquivo.
DOMINIO=$DOMINIO
EMAIL_HTTPS=$EMAIL

POSTGRES_USER=evolution
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=evolution

# --- Evolution API ---
SERVER_TYPE=http
SERVER_PORT=8080
SERVER_URL=https://$DOMINIO
CORS_ORIGIN=https://$DOMINIO
CORS_METHODS=GET,POST,PUT,DELETE
CORS_CREDENTIALS=true
TELEMETRY_ENABLED=false
LOG_LEVEL=ERROR,WARN,INFO
LOG_COLOR=false
LOG_BAILEYS=error
DEL_INSTANCE=false
LANGUAGE=pt-BR

AUTHENTICATION_API_KEY=$EVOLUTION_API_KEY
AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true

DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=postgresql://evolution:$POSTGRES_PASSWORD@postgres:5432/evolution?schema=evolution_api
DATABASE_CONNECTION_CLIENT_NAME=cncold_whatsapp
DATABASE_SAVE_DATA_INSTANCE=true
DATABASE_SAVE_DATA_NEW_MESSAGE=true
DATABASE_SAVE_MESSAGE_UPDATE=true
DATABASE_SAVE_DATA_CONTACTS=true
DATABASE_SAVE_DATA_CHATS=true
DATABASE_SAVE_DATA_LABELS=true
DATABASE_SAVE_DATA_HISTORIC=false
DATABASE_SAVE_IS_ON_WHATSAPP=true
DATABASE_SAVE_IS_ON_WHATSAPP_DAYS=7
DATABASE_DELETE_MESSAGE=false

CACHE_REDIS_ENABLED=true
CACHE_REDIS_URI=redis://redis:6379/6
CACHE_REDIS_TTL=604800
CACHE_REDIS_PREFIX_KEY=evolution
CACHE_REDIS_SAVE_INSTANCES=false
CACHE_LOCAL_ENABLED=false

CONFIG_SESSION_PHONE_CLIENT="CN Cold"
CONFIG_SESSION_PHONE_NAME=Chrome
QRCODE_LIMIT=30
QRCODE_COLOR="#0B3D91"

WEBHOOK_GLOBAL_ENABLED=false
WEBHOOK_REQUEST_TIMEOUT_MS=30000
WEBHOOK_RETRY_MAX_ATTEMPTS=10
WEBHOOK_RETRY_INITIAL_DELAY_SECONDS=5
WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF=true
WEBHOOK_RETRY_MAX_DELAY_SECONDS=300

RABBITMQ_ENABLED=false
SQS_ENABLED=false
WEBSOCKET_ENABLED=false
PUSHER_ENABLED=false
KAFKA_ENABLED=false
NATS_ENABLED=false
TYPEBOT_ENABLED=false
CHATWOOT_ENABLED=false
OPENAI_ENABLED=false
DIFY_ENABLED=false
N8N_ENABLED=false
EVOAI_ENABLED=false
FLOWISE_ENABLED=false
S3_ENABLED=false
PROMETHEUS_METRICS=false
EOF
chmod 600 .env

# --- 3. docker-compose e Caddy ----------------------------------------------
cat > docker-compose.yml <<EOF
name: cncold-whatsapp
services:
  evolution:
    image: evoapicloud/evolution-api:$EVOLUTION_VERSAO
    restart: unless-stopped
    env_file: .env
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_started }
    volumes:
      - evolution_instances:/evolution/instances
    expose: ["8080"]
    logging: { driver: json-file, options: { max-size: "20m", max-file: "5" } }

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - redis_data:/data

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on: [evolution]
    ports: ["80:80", "443:443"]
    environment:
      DOMINIO: \${DOMINIO}
      EMAIL_HTTPS: \${EMAIL_HTTPS}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  evolution_instances:
  postgres_data:
  redis_data:
  caddy_data:
  caddy_config:
EOF

if [[ -n "$EMAIL" ]]; then printf '{\n\temail {$EMAIL_HTTPS}\n}\n\n' > Caddyfile; else : > Caddyfile; fi
cat >> Caddyfile <<'EOF'
{$DOMINIO} {
	encode gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options nosniff
		-Server
	}
	request_body {
		max_size 64MB
	}
	reverse_proxy evolution:8080
}
EOF

# --- 4. Backup diário --------------------------------------------------------
cat > backup.sh <<'EOF'
#!/usr/bin/env bash
# Backup diário do banco da Evolution (guarda 14 dias em /opt/cncold-whatsapp/backups)
set -euo pipefail
cd "$(dirname "$0")"
POSTGRES_USER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-)"
POSTGRES_DB="$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2-)"
ARQ="backups/evolution-$(date +%F).sql.gz"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$ARQ"
find backups -name 'evolution-*.sql.gz' -mtime +14 -delete
EOF
chmod +x backup.sh

if [[ "$SKIP_DOCKER" != "1" ]]; then
  ( crontab -l 2>/dev/null | grep -v "$PASTA/backup.sh" ; echo "30 3 * * * $PASTA/backup.sh >> $PASTA/backups/backup.log 2>&1" ) | crontab -

  azul "Baixando imagens e subindo os serviços (pode levar alguns minutos)..."
  docker compose pull
  docker compose up -d

  azul "Aguardando a Evolution responder..."
  for _ in $(seq 1 60); do
    if docker compose exec -T evolution wget -qO- http://localhost:8080 >/dev/null 2>&1; then break; fi
    sleep 3
  done
fi

verde "=============================================================="
verde " Pronto! Evolution API em: https://$DOMINIO"
verde "=============================================================="
echo
echo "Copie os dois valores abaixo para o Lovable (projeto CN Cold WhatsApp → Cloud → Secrets)."
echo "NÃO cole em chat, e-mail ou WhatsApp."
echo
echo "  EVOLUTION_URL     = https://$DOMINIO"
echo "  EVOLUTION_API_KEY = $EVOLUTION_API_KEY"
echo
echo "Para ver a chave de novo depois:  grep AUTHENTICATION_API_KEY $PASTA/.env"
echo "Status dos serviços:              cd $PASTA && docker compose ps"
