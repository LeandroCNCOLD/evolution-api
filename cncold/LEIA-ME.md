# CN Cold — instalação da Evolution API na VPS

Instala Evolution API 2.3.7 (imagem oficial), Postgres 16, Redis 7 e Caddy (HTTPS automático),
com chave de API forte gerada no próprio servidor e backup diário do banco.

No terminal da VPS (como root):

```bash
curl -fsSL https://raw.githubusercontent.com/LeandroCNCOLD/evolution-api/main/cncold/install.sh -o install.sh
bash install.sh whatsapp.cncold.tech
```

- O DNS `whatsapp.cncold.tech` (registro A) precisa apontar para o IP da VPS.
- Nenhum segredo fica neste repositório: senhas e chave são geradas na VPS em `/opt/cncold-whatsapp/.env`.
- Rodar de novo atualiza a configuração sem perder senhas, números conectados nem conversas.
