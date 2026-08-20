# Nexus Repository local — Plano 1

Instância local de Sonatype Nexus Repository Community Edition para avaliar a
troca do Cloudsmith, espelhando o desenho de dois repositórios.

```text
pub-ingestion    pub proxy    remote https://pub.dev
pub-production   pub hosted   sem proxy, sem group
```

Sem repositório `group` de propósito: um group contendo o ingestion permitiria
que um package não aprovado resolvesse por fallback, que é exatamente o bypass
que o desenho evita.

## Uso

```bash
docker compose -f nexus/docker-compose.yml up -d   # 2-3 min para subir
NEXUS_ACCEPT_EULA=yes nexus/bootstrap.sh
nexus/trust-outbound-ca.sh                         # só se a rede intercepta TLS
nexus/verify-setup.sh
```

Credenciais geradas ficam em `nexus/.credentials` (gitignored). Nada secreto é
impresso pelos scripts.

### Expor na tailnet

O host aqui é um Windows corporativo travado, onde não se instala o client do
Tailscale. Não é impedimento: o sidecar roda em container e a imagem usa
**userspace networking** por default, sem `/dev/net/tun` e sem `NET_ADMIN`.

```bash
# TAILSCALE_AUTH_KEY vem do .env da raiz; compose procura .env ao lado do
# arquivo, então o --env-file é necessário
docker compose --env-file .env -f nexus/docker-compose.yml --profile tailnet up -d

# archive_url e o host gravado no pubspec.lock passam a ser o nome da tailnet
NEXUS_PUBLIC_URL=https://nexus-pub-poc.<tailnet>.ts.net \
  NEXUS_ACCEPT_EULA=yes nexus/bootstrap.sh
```

O profile `tailnet` mantém o `docker compose up -d` puro funcionando como antes.
Do lado da tailnet é preciso MagicDNS e HTTPS Certificates habilitados — sem
certificado não há URL HTTPS, e `dart pub token add` recusa `http://`.

## Conclusão da avaliação

**CE é suficiente para a POC.** Os 15 checks do `verify-setup.sh` passam,
incluindo o experimento que decidia a questão.

### O que foi comprovado

| Questão | Resultado |
|---|---|
| `pub` proxy + hosted em CE | ✅ nativo, endpoints REST `/v1/repositories/pub/{proxy,hosted,group}` |
| Proxy cacheia o tarball | ✅ vira componente no repo, então há o que promover |
| Promoção sem staging do Pro | ✅ download do proxy + upload via components API |
| **`sha256` preservado na promoção** | ✅ **byte-identical, então `--enforce-lockfile` funciona** |
| Auth do `dart pub` | ✅ via realm `PubToken` |
| Production sem upstream | ✅ 404 para package nunca promovido |
| Least privilege | ✅ `ci-ingestion` não lê production (403) |

O `sha256` preservado é o achado que dispensa o Pro: `cloudsmith copy` não tem
equivalente em CE, mas baixar do proxy e subir no hosted mantém o artifact
idêntico, que é tudo que o modelo de evidência exige.

## Sete coisas que não estão na documentação e custaram tempo

**1. A EULA bloqueia tudo.** Antes de aceitá-la, *toda* requisição a repositório
retorna 403 com uma mensagem sobre o onboarding wizard — parece erro de
permissão. Há endpoint REST (`POST /v1/system/eula`), e o `bootstrap.sh` exige
opt-in explícito via `NEXUS_ACCEPT_EULA=yes` porque é um aceite jurídico:
https://links.sonatype.com/products/nxrm/ce-eula

**2. O realm `PubToken` vem desativado.** O `dart pub` só sabe enviar
`Authorization: Bearer <token>`. Sem o realm ativo, todo Bearer é 401,
independente do que se configure no cliente. Com ele ativo:

```text
Bearer base64(user:password)   -> 200   ← é isto que dart pub token add guarda
Bearer user:password           -> 401
Bearer senha pura              -> 401
basic auth                     -> 200
```

Ou seja, o "token" é base64 reversível das credenciais: **obfuscação, não
tokenização**. Guardá-lo equivale a guardar a senha.

**3. O truststore do Nexus é ignorado por default.** Em rede com interceptação
TLS, adicionar o CA em `Security → SSL Certificates` não basta: é preciso
`httpClient.connection.useTrustStore: true` **no repositório**. Sem isso o proxy
falha com `PKIX path building failed` mesmo com o CA instalado.

Nesta máquina o host **não** é interceptado e o container **é**:

```text
host WSL   → pub.dev por Google Trust Services (WR3)
container  → pub.dev por Akamai Enterprise (SL) 281191
```

Isso faz o problema parecer ser do Nexus. O `trust-outbound-ca.sh` lê o
certificado que o container realmente recebe, instala o CA emissor e habilita o
`useTrustStore`.

**Remedido em 2026-08-20: a interceptação não estava ativa.** Do mesmo container,
naquele momento:

```text
pub.dev                      Google Trust Services (WR3)
controlplane.tailscale.com   Let's Encrypt (YE2)
login.tailscale.com          Let's Encrypt (YE1)
derp1.tailscale.com          Let's Encrypt (YE1)
```

Ou seja, a interceptação é intermitente — depende da rede em que a máquina está,
não do container. Duas consequências: o `useTrustStore` continua necessário porque
a interceptação pode voltar, e o sidecar do Tailscale não é bloqueado por ela
(nenhum endpoint do control plane apareceu interceptado, e `curl` valida os três
com o truststore default).

**4. Negative cache de 24h esconde a correção.** O default do Nexus faz uma
falha transitória de saída continuar respondendo 404 por um dia, e um remote com
erro deixa o repositório em `AUTO_BLOCKED_UNAVAILABLE`. Depois de corrigir
qualquer coisa de rede é obrigatório invalidar o cache e esperar o bloqueio
expirar, senão parece que nada melhorou. O bootstrap usa TTL de 5 minutos.

**5. O realm `PubToken` não vale para a REST API.** Descoberto na Fase 2 do
Plano 2: o mesmo token que autentica nos endpoints `/repository` é recusado com
403 no `/service/rest/v1/components`, que é por onde a promoção sobe o artifact.

```text
POST /service/rest/v1/components   Authorization: Bearer base64(user:senha)  -> 403
POST /service/rest/v1/components   Authorization: Basic  base64(user:senha)  -> 204
GET  /repository/.../api/packages  Authorization: Basic  base64(user:senha)  -> 200
```

Como o "token" é literalmente `base64(user:senha)`, ou seja, exatamente o valor
de um header Basic, **um único secret serve para os dois usos** — desde que
enviado como `Basic`, não `Bearer`. O `nexus-promote-packages.sh` usa `Basic` em
todas as chamadas por isso.

**6. A API de capabilities tem duas armadilhas.** A Base URL é uma capability
(`type: baseurl`), e é o que faz o Nexus anunciar o hostname externo em vez de
derivar da requisição. Configurá-la por API custou dois erros enganosos:

```text
body com "attributes": { "url": ... }   -> 400 "url must not be blank"
body com "properties": { "url": ... }   -> 201        ← o schema é properties
PUT sem repetir "id" no body            -> 500 NullPointerException
PUT com "id" no body                    -> 204
```

A mensagem do 400 aponta para o campo certo pelo motivo errado, e o 500 parece
bug do servidor quando é validação faltando. O `bootstrap.sh` faz create ou
update conforme o caso, e é idempotente.

**7. A Base URL só chega ao plugin pub depois de restart.** Com a capability
`active` e o valor correto, o `archive_url` continuou saindo com o host antigo —
inclusive para packages nunca pedidos antes, então não era cache de metadata. O
que expõe a diferença é comparar com a REST API na mesma requisição:

```text
                                     REST /v1/repositories      pub archive_url
via localhost                        localhost:8081             localhost:8081
via tailnet, antes do restart        ts.net  (correto)          localhost:8081
via tailnet, depois do restart       ts.net                     ts.net
```

Ou seja, a camada REST usa o escopo da requisição e o plugin pub não; ele lê a
Base URL na inicialização. Sem o restart, um consumidor recebe metadata correta
com URLs de arquivo inalcançáveis — o modo de falha mais confuso possível, porque
`pub get` falha no download e não na resolução.

Depois do restart, nem é preciso invalidar cache: a URL é gerada por resposta, e
os packages já cacheados passaram a anunciar o host novo.

## Equivalência Cloudsmith → Nexus CE

Base para o Plano 2. O que muda não é a arquitetura, são três mecanismos:

| Conceito | Cloudsmith | Nexus CE |
|---|---|---|
| Repo de entrada | `flutter-ingestion`, upstream `pub.dev` em Cache and Proxy | `pub-ingestion`, pub proxy com remote `https://pub.dev` |
| Repo aprovado | `flutter-production`, sem upstream | `pub-production`, pub hosted |
| Privacidade | `Visibility: Private` (opt-in) | acesso anônimo desabilitado (**opt-out**) |
| Identidade de CI | OIDC, token temporário, claims `repository` + `ref` | credencial estática (usuário/senha) |
| Auth do cliente pub | `dart pub token add --env-var CLOUDSMITH_API_KEY` | idem, com token = `base64(user:senha)` e realm `PubToken` ativo |
| **Promoção** | `cloudsmith copy <ns>/<repo>/<id> <dest>` | **download do proxy + `POST /v1/components`** |
| Espera de sync | `cloudsmith ls pkg` + `is_sync_completed` | não observado; o upload é síncrono |
| Imutabilidade | — | `writePolicy: ALLOW_ONCE` no hosted |
| Busca exata | `name:^x$ AND version:^y$` | `GET /api/packages/<name>` + filtro por versão |
| Identificador | `slug_perm` | `name` + `version` explícitos no upload |

O ponto mais delicado da tradução é a identidade: perde-se expiração automática e
o vínculo com `repository`/`ref`. Mitigação principal, sem custo: a credencial de
promoção como **Environment secret** do `cloudsmith-production`, não repository
secret, de modo que o job de ingestão não consiga lê-la. O gate de aprovação
passa a ser o que dá acesso à credencial, com enforcement do GitHub.

## Registro de decisões e ações

**EULA do CE aceita em 2026-08-12** durante a implementação do Plano 1, para
desbloquear a validação, com opt-in explícito (`NEXUS_ACCEPT_EULA=yes`). É um
acordo jurídico e o contexto é corporativo: se houver processo de revisão
interna, este é o item a levar. https://links.sonatype.com/products/nxrm/ce-eula

**Escolhido o conjunto mínimo em vez do Pro.** `cloudsmith copy` não tem
equivalente em CE, e a alternativa avaliada seria o Staging do Pro. Descartada
porque download + upload preserva o `sha256`, que é a única propriedade que o
modelo de evidência exige.

## Ambiente: proxy do Docker Desktop malformado

Independente do Nexus, e vai reaparecer. O proxy do Docker Desktop nesta máquina
falha assim:

```text
connecting to http=127.0.0.1:8380: dial tcp: lookup http=127.0.0.1: no such host
```

O valor está na sintaxe legada do WinINET (`http=host:port;https=...`) e o Docker
Desktop trata a string inteira como hostname. Não está no `settings-store.json`,
então vem do proxy de sistema do Windows — provavelmente posto pelo agente
corporativo. Sintomas observados:

- o primeiro `docker pull` falhou; o segundo funcionou (intermitente);
- `http://http.docker.internal:3128` responde `HTTP/1.0 500` com o erro acima.

Não foi alterado: é configuração da máquina do usuário. O contorno aplicado foi
dar ao Nexus o CA interceptador, o que resolve o egress do Nexus mas não o do
`docker pull`.

## Limites e lacunas conhecidos

**Teto do CE: 40.000 componentes e 100.000 requests/dia.** A POC usa poucos, mas
só o toolchain do Flutter trouxe ~100 no Cloudsmith, e um proxy de pub.dev em uso
real cresce. Vale acompanhar pelo Usage Center.

**User Token não disponível.** O endpoint interno responde 404 nesta instância,
consistente com a documentação que o lista como recurso Pro. Não muda o desenho:
seria credencial estática de todo jeito.

**Sem OIDC em nenhuma edição.** A autenticação de CI é credencial estática, então
perde-se a expiração automática e o vínculo com `repository`/`ref` que o provider
OIDC do Cloudsmith impõe. Mitigação principal: a credencial de promoção como
**Environment secret**, não repository secret, de modo que o job de ingestão não
consiga lê-la.

**`writePolicy: ALLOW_ONCE`** no hosted impede sobrescrever uma versão já
publicada. A promoção já pula versões existentes, e isso protege a
imutabilidade do que foi aprovado.

**Este é um ambiente local.** Runners hospedados do GitHub não alcançam
`localhost:8081`; a conectividade fica para o Plano 2.
