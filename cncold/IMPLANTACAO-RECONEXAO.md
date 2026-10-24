# CN COLD — implantação controlada da correção de reconexão

Esta versão corrige o agendamento de reconexão do Baileys. **Não significa que o QR Code foi validado em produção.**

## Pré-requisitos
- Conferir que o PR passou na CI, inclusive segurança, e revisar a alteração.
- Marcar janela de manutenção: todos os números da mesma Evolution podem sofrer desconexão temporária.
- Garantir acesso ao console da VPS e backup independente do banco e dos volumes.
- Confirmar disponibilidade de espaço em disco. Nunca executar `docker compose down -v`.

## Preparação (não altera produção)

Executar no terminal da VPS, como root:

```bash
cd /opt/cncold-whatsapp
date -Is
docker compose ps
docker compose config --images
docker image inspect evoapicloud/evolution-api:v2.3.7 --format '{{.Id}}' 
mkdir -p /root/cncold-backups
cp -a docker-compose.yml /root/cncold-backups/docker-compose.before-baileys.yml
cp -a .env /root/cncold-backups/evolution-env.before-baileys
chmod 600 /root/cncold-backups/evolution-env.before-baileys
bash backup.sh
```

Confirmar manualmente que o backup foi criado, que possui tamanho não nulo e que é possível restaurá-lo. Os volumes de sessões e mídias também precisam de cópia consistente; o backup SQL sozinho **não os cobre**.

## Build isolado

Este fork inclui um Dockerfile próprio. Construir em diretório separado, **sem usar `cncold/install.sh` e sem substituir a imagem oficial**:

```bash
cd /opt
git clone --branch fix/cncold-baileys-reconnect-loop --single-branch https://github.com/LeandroCNCOLD/evolution-api.git evolution-api-cncold-fix
cd evolution-api-cncold-fix
docker build -t cncold/evolution-api:baileys-reconnect-fix .
```

O build **não** aplica migrações no banco de produção; a imagem gerada executa a rotina de deploy de banco ao iniciar, por isso é obrigatório revisar compatibilidade das migrations antes do rollout.

## Implantação após homologação

Não alterar o instalador principal enquanto a estratégia de imagem customizada não estiver consolidada. Criar um arquivo de override apenas na VPS:

```yaml
# /opt/cncold-whatsapp/docker-compose.fix.yml
services:
  evolution:
    image: cncold/evolution-api:baileys-reconnect-fix
```

Depois de validar backup e compatibilidade do banco:

```bash
cd /opt/cncold-whatsapp
docker compose -f docker-compose.yml -f docker-compose.fix.yml config --images
docker compose -f docker-compose.yml -f docker-compose.fix.yml up -d --no-deps evolution
docker compose -f docker-compose.yml -f docker-compose.fix.yml ps
```

## Verificação após implantação

Consultar `docker compose -f docker-compose.yml -f docker-compose.fix.yml logs --since=2m evolution` e o endpoint `connectionState`, sem divulgar QR, tokens ou credenciais. Confirmar queda expressiva na taxa de `Browser: Mac OS` e conexão estável. Testar QR uma única vez.

## Rollback

Caso a versão corrigida falhe, restaurar a imagem oficial previamente registrada e recriar **somente** o serviço Evolution usando o compose original:

```bash
cd /opt/cncold-whatsapp
docker compose -f docker-compose.yml up -d --no-deps --force-recreate evolution
docker compose ps
```

Este rollback de container não reverte automaticamente alterações no esquema de banco. Não aplicar rollout até confirmar compatibilidade ou procedimento seguro de recuperação do banco.

## Notas

- O `cncold/install.sh` atual fixa `evoapicloud/evolution-api:v2.3.7`. Executá-lo novamente pode reverter a imagem corrigida.
- Nunca remover instância Engenharia, arquivos de autenticação, volumes ou mídias para tentar gerar QR.
- Se o loop persistir mesmo com limitação de reconexões, investigar chamadas externas e eventos de fechamento; não forçar versão de protocolo WhatsApp sem teste.
