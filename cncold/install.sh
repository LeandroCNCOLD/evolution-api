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
#   3. Sobe Evolution API 2.3.7, Postgres 16, Redis 7, serviço de mídias e Caddy (HTTPS automático).
#      Mídias (fotos, vídeos, áudios, documentos de todos os números) ficam na VPS: /midia/* no mesmo domínio.
#   4. Agenda backup diário do banco (guarda 14 dias).
#
# Pode rodar de novo sem perder nada: senhas já criadas são mantidas.
# Trocar a chave da Evolution e o segredo das mídias (se vazaram):  TROCAR_CHAVES=1 bash install.sh <domínio>
# Antes de rodar: o DNS do domínio (registro A) precisa apontar para o IP desta VPS.
# =============================================================================
set -euo pipefail
trap 'printf "\033[1;31mERRO na linha %s: %s\033[0m\nMande um print desta tela.\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

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
    # nunca interrompe a instalação por causa do firewall (o painel da Hostinger também tem firewall)
    { ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable; } >/dev/null 2>&1 \
      && echo "Firewall ativo." \
      || echo "Aviso: não foi possível ativar o firewall do Ubuntu (seguindo assim mesmo)."
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
  MIDIA_SEGREDO="$(grep -E '^MIDIA_SEGREDO=' .env | cut -d= -f2- || true)"
fi
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(segredo 24)}"
if [[ "${TROCAR_CHAVES:-0}" == "1" ]]; then
  azul "Gerando chave da Evolution e segredo das mídias NOVOS (atualize os Secrets do Lovable depois)."
  AUTHENTICATION_API_KEY=""
  MIDIA_SEGREDO=""
fi
EVOLUTION_API_KEY="${AUTHENTICATION_API_KEY:-$(segredo 32)}"
MIDIA_SEGREDO="${MIDIA_SEGREDO:-$(segredo 32)}"

cat > .env <<EOF
# Gerado por install.sh em $(date -Iseconds). NÃO compartilhe este arquivo.
DOMINIO=$DOMINIO
EMAIL_HTTPS=$EMAIL

POSTGRES_USER=evolution
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=evolution

# --- Serviço de mídias (vps/midia/servidor.mjs) ---
MIDIA_SEGREDO=$MIDIA_SEGREDO
MIDIA_LIMITE_MB=100

# --- Evolution API ---
SERVER_TYPE=http
SERVER_PORT=8080
SERVER_URL=https://$DOMINIO
# "*" é obrigatório: a Evolution 2.3.7 recusa (erro 500) chamadas sem cabeçalho Origin — justamente as do servidor do Lovable.
# A proteção real é a chave de API (AUTHENTICATION_API_KEY), não o CORS.
CORS_ORIGIN=*
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
# guarda o histórico importado do celular (necessário para baixar mídias antigas depois)
DATABASE_SAVE_DATA_HISTORIC=true
DATABASE_SAVE_IS_ON_WHATSAPP=true
DATABASE_SAVE_IS_ON_WHATSAPP_DAYS=7
DATABASE_DELETE_MESSAGE=false

CACHE_REDIS_ENABLED=true
CACHE_REDIS_URI=redis://redis:6379/6
CACHE_REDIS_TTL=604800
CACHE_REDIS_PREFIX_KEY=evolution
CACHE_REDIS_SAVE_INSTANCES=false
CACHE_LOCAL_ENABLED=false

# "Desktop" faz o celular enviar o HISTÓRICO COMPLETO ao conectar (navegador comum recebe só o recente).
# No celular o aparelho aparece como "Mac OS".
CONFIG_SESSION_PHONE_CLIENT="Mac OS"
CONFIG_SESSION_PHONE_NAME=Desktop
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

  midia:
    image: node:22-alpine
    restart: unless-stopped
    command: ["node", "/app/servidor.mjs"]
    environment:
      MIDIA_SEGREDO: \${MIDIA_SEGREDO}
      MIDIA_LIMITE_MB: \${MIDIA_LIMITE_MB}
      MIDIA_PASTA: /dados
      MIDIA_PORTA: "3000"
    volumes:
      - ./midia:/app:ro
      - midia_dados:/dados
    expose: ["3000"]
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on: [evolution, midia]
    ports: ["80:80", "443:443"]
    environment:
      DOMINIO: \${DOMINIO}
      EMAIL_HTTPS: \${EMAIL_HTTPS}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  midia_dados:
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
		max_size 110MB
	}
	handle /midia/* {
		reverse_proxy midia:3000
	}
	handle {
		reverse_proxy evolution:8080
	}
}
EOF

# --- 3b. Serviço de mídias ----------------------------------------------------
mkdir -p midia
cat > midia/servidor.mjs <<'EOF_MIDIA'
// CN Cold WhatsApp — serviço de mídias na VPS (fotos, vídeos, áudios, documentos de todos os números).
// Só Node 22, sem dependências. Roda no Docker atrás do Caddy em https://<domínio>/midia/...
//
//   PUT    /midia/<caminho>          Authorization: Bearer <MIDIA_SEGREDO>; Content-Type; corpo = arquivo  → grava
//   GET    /midia/<caminho>?exp=&sig=[&nome=]                                                             → baixa (link temporário)
//   DELETE /midia/<caminho>          Authorization: Bearer <MIDIA_SEGREDO>                                → apaga
//   GET    /midia/_espaco            Authorization: Bearer <MIDIA_SEGREDO>                                → uso do disco
//   GET    /midia/_saude                                                                                  → "ok"
//
// Link temporário: sig = HMAC-SHA256(MIDIA_SEGREDO, `${caminho}\n${exp}\n${nome}`) em hex; exp = unix (segundos).
// Quem gera os links é a central (Lovable), que tem o mesmo segredo. Nada é público sem assinatura.
import { createHmac, timingSafeEqual } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, rename, rm, stat, statfs, writeFile } from "node:fs/promises";
import http from "node:http";
import { dirname, join, normalize } from "node:path";
import { pipeline } from "node:stream/promises";

const SEGREDO = process.env.MIDIA_SEGREDO ?? "";
const PASTA = process.env.MIDIA_PASTA ?? "/dados";
const PORTA = Number(process.env.MIDIA_PORTA ?? 3000);
const LIMITE = Number(process.env.MIDIA_LIMITE_MB ?? 100) * 1024 * 1024;

if (SEGREDO.length < 32) {
  console.error("MIDIA_SEGREDO ausente ou curto demais (mínimo 32 caracteres).");
  process.exit(1);
}

const CAMINHO_OK = /^[A-Za-z0-9][A-Za-z0-9/_.\-]{0,400}$/;

export function assinar(segredo, caminho, exp, nome = "") {
  return createHmac("sha256", segredo).update(`${caminho}\n${exp}\n${nome}`).digest("hex");
}

function iguais(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

function responder(res, status, corpo, tipo = "application/json") {
  const txt = typeof corpo === "string" ? corpo : JSON.stringify(corpo);
  res.writeHead(status, { "content-type": tipo, "cache-control": "no-store" });
  res.end(txt);
}

function caminhoSeguro(bruto) {
  let c;
  try {
    c = decodeURIComponent(bruto);
  } catch {
    return null;
  }
  if (!CAMINHO_OK.test(c) || c.includes("..") || c.includes("//") || c.endsWith(".meta.json")) return null;
  const abs = normalize(join(PASTA, c));
  if (!abs.startsWith(normalize(PASTA) + "/")) return null;
  return { rel: c, abs };
}

const autorizado = (req) => iguais(req.headers.authorization ?? "", `Bearer ${SEGREDO}`);

function nomeSeguro(n) {
  return String(n ?? "").replace(/[^\w.\- ()À-ÿ]/g, "_").slice(0, 150);
}

export const servidor = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", "http://x");
    if (!url.pathname.startsWith("/midia/")) return responder(res, 404, { erro: "não encontrado" });
    const resto = url.pathname.slice("/midia/".length);

    if (resto === "_saude") return responder(res, 200, "ok", "text/plain");
    if (resto === "_espaco") {
      if (!autorizado(req)) return responder(res, 401, { erro: "não autorizado" });
      const s = await statfs(PASTA);
      return responder(res, 200, { total: s.blocks * s.bsize, livre: s.bavail * s.bsize });
    }

    const c = caminhoSeguro(resto);
    if (!c) return responder(res, 400, { erro: "caminho inválido" });

    if (req.method === "PUT") {
      if (!autorizado(req)) return responder(res, 401, { erro: "não autorizado" });
      const tamanho = Number(req.headers["content-length"] ?? 0);
      if (tamanho > LIMITE) return responder(res, 413, { erro: "arquivo grande demais" });
      await mkdir(dirname(c.abs), { recursive: true });
      const tmp = `${c.abs}.${process.pid}.${Date.now()}.tmp`;
      let recebidos = 0;
      req.on("data", (p) => {
        recebidos += p.length;
        if (recebidos > LIMITE) req.destroy(new Error("limite"));
      });
      try {
        await pipeline(req, createWriteStream(tmp));
      } catch {
        await rm(tmp, { force: true });
        return responder(res, recebidos > LIMITE ? 413 : 400, { erro: "falha ao receber o arquivo" });
      }
      await rename(tmp, c.abs);
      const mime = String(req.headers["content-type"] ?? "application/octet-stream").slice(0, 120);
      await writeFile(`${c.abs}.meta.json`, JSON.stringify({ mime, bytes: recebidos, gravado_em: new Date().toISOString() }));
      return responder(res, 201, { ok: true, caminho: c.rel, bytes: recebidos });
    }

    if (req.method === "DELETE") {
      if (!autorizado(req)) return responder(res, 401, { erro: "não autorizado" });
      await rm(c.abs, { force: true });
      await rm(`${c.abs}.meta.json`, { force: true });
      return responder(res, 200, { ok: true });
    }

    if (req.method === "GET" || req.method === "HEAD") {
      const exp = url.searchParams.get("exp") ?? "";
      const sig = url.searchParams.get("sig") ?? "";
      const nome = url.searchParams.get("nome") ?? "";
      if (!/^\d+$/.test(exp) || Number(exp) < Math.floor(Date.now() / 1000)) return responder(res, 403, { erro: "link expirado" });
      if (!iguais(assinar(SEGREDO, c.rel, exp, nome), sig)) return responder(res, 403, { erro: "assinatura inválida" });
      let info;
      try {
        info = await stat(c.abs);
      } catch {
        return responder(res, 404, { erro: "arquivo não encontrado" });
      }
      let mime = "application/octet-stream";
      try {
        mime = JSON.parse(await readFile(`${c.abs}.meta.json`, "utf8")).mime ?? mime;
      } catch {
        /* sem metadados */
      }
      const cab = {
        "content-type": mime,
        "content-length": String(info.size),
        "cache-control": "private, max-age=3600",
        "x-content-type-options": "nosniff",
        "accept-ranges": "none",
      };
      if (nome) cab["content-disposition"] = `attachment; filename*=UTF-8''${encodeURIComponent(nomeSeguro(nome))}`;
      res.writeHead(200, cab);
      if (req.method === "HEAD") return res.end();
      return pipeline(createReadStream(c.abs), res).catch(() => res.destroy());
    }

    return responder(res, 405, { erro: "método não permitido" });
  } catch (e) {
    console.error(e);
    if (!res.headersSent) responder(res, 500, { erro: "erro interno" });
    else res.destroy();
  }
});

if (process.env.MIDIA_NAO_INICIAR !== "1") {
  await mkdir(PASTA, { recursive: true });
  servidor.listen(PORTA, () => console.log(`midia: ouvindo na porta ${PORTA}, pasta ${PASTA}`));
}
EOF_MIDIA

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
  # backup diário às 03:30 (arquivo próprio em /etc/cron.d; não mexe no crontab do root)
  command -v cron >/dev/null 2>&1 || apt-get install -y cron >/dev/null 2>&1 || true
  echo "30 3 * * * root $PASTA/backup.sh >> $PASTA/backups/backup.log 2>&1" > /etc/cron.d/cncold-whatsapp-backup
  chmod 644 /etc/cron.d/cncold-whatsapp-backup
  systemctl enable --now cron >/dev/null 2>&1 || true

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
echo "Copie os valores abaixo para o Lovable (projeto CN Cold WhatsApp → Cloud → Secrets)."
echo "NÃO cole em chat, e-mail ou WhatsApp."
echo
echo "  EVOLUTION_URL     = https://$DOMINIO"
echo "  EVOLUTION_API_KEY = $EVOLUTION_API_KEY"
echo "  MIDIA_URL         = https://$DOMINIO"
echo "  MIDIA_SEGREDO     = $MIDIA_SEGREDO"
echo
echo "Para ver de novo depois:          grep -E 'AUTHENTICATION_API_KEY|MIDIA_SEGREDO' $PASTA/.env"
echo "Status dos serviços:              cd $PASTA && docker compose ps"
