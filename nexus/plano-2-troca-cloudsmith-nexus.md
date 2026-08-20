# Plano 2 — Trocar Cloudsmith por Nexus

> Pré-requisito: Plano 1 concluído. Ver `nexus/README.md` para os achados, a
> tabela de equivalência e as armadilhas encontradas.

## O que não muda

A arquitetura sobrevive intacta:

```text
dois repositórios físicos       ingestion com upstream, production sem
promoção explícita              artifact copiado, não referenciado
gate no GitHub Environment      aprovação manual antes de promover
pubspec.lock como evidência     versões + content hashes concretos
--enforce-lockfile              verificação final contra production
```

Também não mudam o probe temporário, o `dart pub deps --json`, o `packages.tsv`,
o Job Summary de aprovação nem o artifact de evidência.

Mudam três mecanismos: **identidade**, **promoção** e **exposição de rede**.

---

## Fase 0 — Exposição estável

Primeira fase porque uma decisão dela contamina toda a evidência produzida.

O `pubspec.lock` grava o **host** do registry em cada entrada:

```yaml
description:
  name: dio
  sha256: ...
  url: "https://<host>/repository/pub-ingestion/"
source: hosted
```

Com túnel de URL efêmera (ngrok gratuito, quick tunnel), cada restart invalida
todos os lockfiles já aprovados e o `--enforce-lockfile` passa a falhar por
divergência de URL, não por integridade.

Requisitos:

- hostname **estável** e **TLS** — Cloudflare Tunnel nomeado com domínio próprio,
  ou Tailscale com MagicDNS;
- de preferência **o mesmo hostname do deploy definitivo**, para os lockfiles
  produzidos na POC continuarem válidos depois;
- controle de acesso no próprio túnel (service token). Um Nexus com credencial
  estática exposto na internet é superfície demais.

**Decidido: Tailscale, com o client em container.** O host é um Windows
corporativo travado, onde não é possível instalar o client — o que não bloqueia
nada, porque a imagem `tailscale/tailscale` usa **userspace networking** por
default, sem `/dev/net/tun` e sem `NET_ADMIN`. O sidecar está no
`nexus/docker-compose.yml` atrás do profile `tailnet`, com `tailscale serve`
terminando TLS e proxyando para `http://nexus:8081`.

Cloudflare Tunnel foi descartado por dois motivos, não por dificuldade de
montar a imagem — o sidecar `cloudflared` seria igualmente simples:

- túnel nomeado exige domínio próprio na Cloudflare; sem domínio sobra o quick
  tunnel com URL efêmera, que é exatamente o que esta fase rejeita;
- **o controle de acesso do túnel não é usável pelo cliente pub.** A doc do Dart
  é explícita: o `pub` anexa *um* secret token às requisições, e o spec v2 manda
  como `Authorization: Bearer`. O Access para automação exige
  `CF-Access-Client-Id` e `CF-Access-Client-Secret` em header. Ou se põe bypass
  nos paths do pub, deixando um Nexus de credencial estática alcançável
  publicamente, ou o `flutter pub get` toma 403.

O Tailscale não tem esse problema porque autentica na camada de rede, antes do
HTTP, então não depende do que o cliente pub sabe enviar.

Consequências aceitas:

- **o runner precisa entrar na tailnet.** As três workflows têm o step
  `tailscale/github-action@v3` com OAuth client, que registra nó efêmero;
- o hostname é o da tailnet, não o do deploy definitivo. Os lockfiles aprovados
  na POC valem só para a POC; a evidência será regerada quando o Nexus tiver o
  endereço final. Custo aceito porque a POC prova o desenho, não produz o
  inventário aprovado de verdade;
- **risco medido e afastado:** a preocupação era a interceptação de TLS do egress
  do container quebrar a validação de certificado do `tailscaled`. Medido em
  2026-08-20 de dentro do container: `controlplane`, `login` e `derp1` vêm com
  certificado Let's Encrypt real e `curl` valida os três com o truststore
  default. A interceptação vista em 12/08 era intermitente. Continua valendo
  reconferir se o sidecar não subir.

### Verificações da fase

**1. Base URL do Nexus.** O `archive_url` observado no Plano 1 é derivado da
requisição:

```text
archive_url: http://localhost:8081/repository/pub-ingestion/api/archives/dio-5.11.0.tar.gz
```

Através do túnel precisa virar o hostname do túnel. Se o Nexus estiver com Base
URL fixa apontando para outro lugar, o pub recebe URLs de arquivo inalcançáveis e
falha no download, mesmo com a metadata correta.

O mecanismo é a capability `baseurl`, e o `bootstrap.sh` já a configura quando
`NEXUS_PUBLIC_URL` é passada (create ou update, idempotente, validado contra
`localhost:8081`). O `nexus-verify-setup.yml` falha se o `archive_url` não sair
com esse hostname.

**2. `dart pub token add` exige HTTPS.** Não é possível autenticar por token em
`http://`, o que torna o TLS do túnel requisito funcional, não apenas de
segurança.

**3. Reescrita de `archive_url` através do túnel**, confirmada com um GET real
de metadata e um download do arquivo.

---

## Fase 1 — Identidade

| Onde | Nome | Valor |
|---|---|---|
| Variable | `NEXUS_BASE_URL` | `https://nexus-pub-poc.kudu-nessie.ts.net` |
| Variable | `NEXUS_INGESTION_REPO` | `pub-ingestion` |
| Variable | `NEXUS_PRODUCTION_REPO` | `pub-production` |
| Variable | `FLUTTER_VERSION` | `3.44.9` |
| Variable | `TAILSCALE_CI_TAG` | `tag:ci` (default se ausente) |
| Variable | `TS_CLIENT_ID` | client id da federated identity |
| Variable | `TS_AUDIENCE` | `api.tailscale.com/<client id>` |

`TS_CLIENT_ID` e `TS_AUDIENCE` são **variables, não secrets**: a própria doc da
Tailscale diz que os dois são públicos e ficam visíveis no admin console. Guardar
como secret só dificultaria debugar.

### Federated identity da tailnet (OIDC do GitHub)

Substitui o OAuth client estático: o runner troca o JWT do GitHub por um token
de curta duração, então não existe secret de longa duração para o Tailscale.
Configurar em **Trust credentials → Credential → OpenID Connect**:

```text
Issuer   https://token.actions.githubusercontent.com
Subject  repo:luccabaptistamb@254526108/poc-flutter-registry@1331259250:*

Custom claims
  repository        luccabaptistamb/poc-flutter-registry
  job_workflow_ref  luccabaptistamb/poc-flutter-registry/.github/workflows/nexus-*@refs/heads/poc/nexus

Tags     tag:ci          (apenas esta)
Scopes   auth_keys
```

**O `sub` deste repositório carrega os IDs numéricos.** Medido pela workflow de
diagnóstico, o valor emitido é:

```text
sub               repo:luccabaptistamb@254526108/poc-flutter-registry@1331259250:ref:refs/heads/poc/nexus
repository        luccabaptistamb/poc-flutter-registry
job_workflow_ref  luccabaptistamb/poc-flutter-registry/.github/workflows/nexus-*@refs/heads/poc/nexus
```

Ou seja, `owner@ownerId/repo@repoId` no `sub`, e nome simples em `repository` e
`job_workflow_ref`. Um subject escrito como `repo:<owner>/<repo>:*`, que é o
formato de toda a documentação, **não casa** — o token exchange devolve 403 sem
dizer por quê, e o motivo só aparece em Trust credentials no admin console.

**A credencial deve ter exatamente uma tag.** Com `tag:ci` e `tag:ci-nexus`
selecionadas, a criação da auth key falha:

```text
unexpected error while creating authkey: Status: 400,
Message: "requested tags [tag:ci] are invalid or not permitted"
```

A doc de OAuth clients explica: para uma tag só, a credencial precisa ter aquela
tag e o chamador precisa pedir aquela tag. Para **mais de uma**, é obrigatório o
padrão de tag proprietária:

```json
"tagOwners": {
  "tag:ci-owner": ["autogroup:admin"],
  "tag:ci":       ["tag:ci-owner"],
  "tag:ci-nexus": ["tag:ci-owner"]
}
```

com a credencial tendo `tag:ci-owner`. Como o runner só precisa de `tag:ci` — o
sidecar usa auth key própria com `tag:ci-nexus` —, o caminho mais simples e de
menor privilégio é deixar **só `tag:ci`** na credencial.

Dois pontos observados ao criar a credencial em 2026-08-20:

- **o campo Tags só aparece quando a tag já existe em `tagOwners`** e o scope de
  auth keys está selecionado. Criar as tags em Access controls antes;
- **scope `all read and write` é largo demais.** A credencial só precisa emitir
  auth key para registrar nó (`auth_keys`). Com escrita total, um JWT do GitHub
  que satisfaça as claims pode alterar a ACL, remover devices e criar outras
  credenciais — ou seja, o gate de aprovação do Environment deixaria de ser o
  ponto mais fraco.

**O `*` no subject não é preguiça, é necessidade.** O `sub` do GitHub muda de
formato conforme o job declare ou não um environment:

```text
ingest / resolve-baseline / verify   repo:<owner>/<repo>:ref:refs/heads/poc/nexus
promote-and-verify / promote-baseline repo:<owner>/<repo>:environment:cloudsmith-production
```

Um `sub` exato cobriria um dos dois e quebraria o outro — o mesmo erro que a POC
do Cloudsmith documentou ao declarar `environment` nos claims. Como os claims
são exigidos em AND, o aperto vem das custom claims, que existem nos dois
tokens. A alternativa seria criar duas credenciais, uma por formato de `sub`.

O `job_workflow_ref` prende as três workflows *e* a branch numa única claim. Ao
promover para `main`, trocar o sufixo `@refs/heads/poc/nexus`; se ele ficar
desatualizado, o token é recusado e a mensagem de erro fica no admin console, não
no log do runner.

O `aud` não entra como custom claim: a Tailscale gera a audience
(`api.tailscale.com/<client id>`), a action a envia pelo input `audience`, e a
validação é feita pela própria Tailscale.

### ACL da tailnet

```json
{
  "tagOwners": {
    "tag:ci":       ["autogroup:admin"],
    "tag:ci-nexus": ["autogroup:admin"]
  },
  "grants": [
    { "src": ["tag:ci"], "dst": ["tag:ci-nexus"], "ip": ["tcp:443"] }
  ]
}
```

`tag:ci-nexus` é o nó do sidecar (default de `TS_EXTRA_ARGS` no compose) e
`tag:ci` é o runner. A 443 é o `tailscale serve`, não o 8081 do Nexus, que nunca
é exposto na tailnet.
| **Repository** secret | `NEXUS_INGEST_TOKEN` | `base64(ci-ingestion:senha)` |
| **Repository** secret | `NEXUS_CONSUMER_TOKEN` | `base64(pub-consumer:senha)` |
| **Environment** secret | `NEXUS_PROMOTION_TOKEN` | `base64(ci-promotion:senha)` |

O `NEXUS_CONSUMER_TOKEN` não estava previsto e foi acrescentado na Fase 3: o
teste negativo precisa da identidade **read-only em production** que um developer
ou um build de aplicação tem. Com o token de ingestão, production responde 403 em
vez de 404 e o teste passaria pelo motivo errado; com o de promoção, o
`verify-setup` passaria a exigir aprovação.

A distinção repository/environment é central, não conveniência: secrets de
Environment só são injetados em jobs que declaram `environment:`, e esse job só
inicia após a aprovação. Portanto o job de ingestão **não consegue ler** a
credencial que escreve em production. É o que recupera, via enforcement do
GitHub, parte da propriedade que os claims OIDC do Cloudsmith davam.

O mesmo token serve para a API do Nexus (`Authorization: Bearer`) e para o
`dart pub token add --env-var`, porque o realm `PubToken` decodifica
`base64(user:senha)`.

Gerar o token a partir de `nexus/.credentials`:

```bash
printf '%s:%s' ci-promotion "$NEXUS_CI_PROMOTION_PASSWORD" | base64 -w0
```

---

## Fase 2 — `scripts/nexus-promote-packages.sh`

Mesma interface do `promote-packages.sh` (`<packages.tsv> [label]`), para as
workflows não precisarem saber qual registry está por trás.

Por package:

```text
existe em production?  → skip
não existe             → GET /repository/<ingestion>/api/packages/<name>
                       → download do archive_url da versão
                       → POST /service/rest/v1/components?repository=<production>
                         -F pub.name=<name> -F pub.version=<version> -F pub.asset=@<tarball>
                       → reler metadata de production e conferir o sha256
```

Duas simplificações em relação à versão Cloudsmith:

- **não há espera de sincronização** — o upload é síncrono e retorna 204, então
  todo o helper `wait_for_package_sync` desaparece;
- não há `slug_perm` a resolver: `name` e `version` são explícitos no upload.

E uma melhoria: o `sha256` passa a ser **conferido a cada package promovido**, em
vez de confiado à operação de cópia.

Atenção ao `writePolicy: ALLOW_ONCE` do hosted: reenviar uma versão existente
retorna erro em vez de sobrescrever. A checagem de existência antes do upload não
é otimização, é o que mantém a idempotência.

**Esta fase é validável sem túnel**, contra `localhost:8081`. Recomendado fazer
antes da Fase 0, para separar as fontes de falha — foi o que mais economizou
tempo na POC do Cloudsmith.

---

## Fase 3 — Workflows

Alterações cirúrgicas, preservando a estrutura de dois jobs:

| Hoje | Depois |
|---|---|
| `cloudsmith-io/cloudsmith-cli-action@v3` | step que exporta o token do secret |
| `dart pub token add … --env-var CLOUDSMITH_API_KEY` | idem com `--env-var NEXUS_TOKEN` |
| `https://dart.cloudsmith.io/mb-lucca/<repo>/` | `${NEXUS_BASE_URL}/repository/<repo>/` |
| `scripts/promote-packages.sh` | `scripts/nexus-promote-packages.sh` |
| `verify-setup.yml` (Cloudsmith) | versão Nexus, reaproveitando `nexus/verify-setup.sh` |

O `sed` que reescreve a URL no lockfile continua idêntico em mecânica; muda só o
par de URLs. O `promote-sdk-baseline.yml` muda apenas o script de promoção.

Some o `oidc-audience`, somem os `verify-auth`/`export-auth-token`, e some
`permissions: id-token: write`.

---

## Fase 4 — Validação

Os mesmos testes da POC original, agora contra o Nexus:

> Run 32398072600 (`nexus-verify-setup`, 2026-08-20): os dois jobs verdes. Prova
> o join por federation, o isolamento da credencial de promoção, acesso anônimo
> recusado, `archive_url` no hostname da tailnet, ingestão sem acesso a
> production, production sem upstream, e o Teste D — que também é a primeira
> confirmação de `dart pub token add` contra HTTPS real.

| Teste | O que prova |
|---|---|
| A | happy path com transitivos |
| B | package que usa Flutter SDK |
| C | aprovação bloqueia a promoção |
| D | package não aprovado falha contra production |
| E | reexecução: existentes são `skipped` |
| baseline | `flutter pub get` funciona com production como único host |
| final | `dart pub get --enforce-lockfile` e `flutter pub get --enforce-lockfile` |

---

## Riscos específicos desta troca

**O runner passa a ser o caminho dos dados.** No Cloudsmith o `copy` era
server-side; aqui cada package trafega download + upload pelo túnel. O baseline
do SDK são ~109 packages, e `analyzer`/`dwds` são de MBs. Tráfego estimado na
casa de centenas de MB e tempo maior que os ~35 min que o Cloudsmith levou para
95 cópias. A idempotência dá resumabilidade se o túnel cair no meio.

**Decisão recomendada desde já:** no deploy definitivo, rodar o job de promoção
em runner **co-localizado com o Nexus**, mantendo o caminho de dados local. Para
a POC, runner hospedado do GitHub prova o desenho e é mais simples — mas essa não
é a topologia final.

**Teto de 40.000 componentes do CE.** O proxy acumula tudo que já foi pedido.
Acompanhar pelo Usage Center antes de concluir que CE serve em produção.

**Credencial estática.** Sem expiração automática e sem vínculo com
`repository`/`ref`. A rotação manual precisa entrar na documentação operacional,
não só neste plano.

**Base URL no lockfile.** Se o hostname mudar entre POC e deploy, toda a
evidência aprovada precisa ser regerada. É o argumento para escolher o hostname
definitivo na Fase 0.

---

## Sequência

```text
Fase 2  nexus-promote-packages.sh validado contra localhost      (sem rede nova)
Fase 0  túnel estável + Base URL + verificações de HTTPS e archive_url
Fase 1  variables e secrets, promoção em Environment secret
Fase 3  as três workflows
Fase 4  testes A-E + baseline + verificações finais
```

Fase 2 antes da Fase 0 de propósito: valida a promoção sem introduzir a variável
de rede.

---

## Estado da implementação

**Fase 2 concluída e validada contra `localhost:8081`** em 2026-08-19.
`scripts/nexus-promote-packages.sh`, mesma interface do script do Cloudsmith.
Evidência da validação:

```text
3 packages   promoted=2 skipped=1     (path já estava em production)
reexecução   promoted=0 skipped=3
10 packages  promoted=10 em 4s        (inclui analyzer e dwds, loopback)
versão inexistente        exit 1, nada enviado
token de ingestão         exit 1 no primeiro read de production (403)
```

Uma correção em relação ao plano: o upload **não** aceita `Bearer`. Ver o item 5
do `nexus/README.md`. O script usa `Authorization: Basic` em todas as chamadas,
com o mesmo valor de token.

**Fase 3 concluída como arquivos paralelos**, não substituição:

```text
.github/workflows/nexus-ingest-package.yml
.github/workflows/nexus-promote-sdk-baseline.yml
.github/workflows/nexus-verify-setup.yml
```

As três workflows do Cloudsmith continuam intactas, então a POC original segue
executável para comparação. Trocar por substituição é um `git mv` depois de a
Fase 4 passar.

Duas decisões tomadas na migração:

- **o Environment continua sendo `cloudsmith-production`.** O nome ficou
  impróprio, mas é o gate que já existe com reviewer configurado; renomear é
  cosmético e invalidaria a configuração atual;
- **o isolamento da credencial é verificado, não presumido.** O job de ingestão
  referencia `secrets.NEXUS_PROMOTION_TOKEN` e **falha se ele tiver valor**. Como
  Environment secrets não são injetados em job sem `environment:`, isso
  transforma o item de checklist "confirmado que o job de ingestão não lê o secret
  de promoção" em asserção automática.

Falta a Fase 0 (túnel), a Fase 1 (criar as variables e secrets no GitHub) e a
Fase 4. Nada do lado do cliente pub foi exercitado ainda: `dart pub token add`
exige HTTPS, então a resolução contra o Nexus só roda depois do túnel.

---

## Checklist

### Fase 2 — promoção local

- [x] `scripts/nexus-promote-packages.sh` criado com a interface `<tsv> [label]`
- [x] skip de versão já existente em production
- [x] download via `archive_url` da metadata do ingestion
- [x] upload via components API com `pub.name`/`pub.version`/`pub.asset`
- [x] `sha256` conferido após cada upload
- [x] validado contra `localhost:8081` com um TSV de 3 packages
- [x] reexecução resulta em todos `skipped`

### Fase 0 — exposição

- [x] provedor escolhido: Tailscale com MagicDNS
- [x] client em container (userspace), sem instalar nada no host Windows
- [x] sidecar no compose atrás do profile `tailnet`, com `serve` para o 8081
- [x] `bootstrap.sh` configura a capability `baseurl` via `NEXUS_PUBLIC_URL`
- [x] step de join na tailnet nas seis jobs das três workflows
- [x] tailnet com MagicDNS e HTTPS Certificates habilitados
- [x] auth key do sidecar no `.env` como `TAILSCALE_AUTH_KEY`
- [x] ACL com `tagOwners`, e auth key autorizada para `tag:ci-nexus`
- [x] sidecar registrado como `nexus-pub-poc.kudu-nessie.ts.net`, cert ACME emitido
- [x] `tailscale serve` publicando `https://.../` para `http://nexus:8081`
- [x] Base URL fixada e **Nexus reiniciado** (sem o restart o pub ignora)
- [x] `archive_url` sai com o hostname da tailnet, confirmado por GET
- [x] download de arquivo pela tailnet, com sha256 conferido
- [x] federated identity com `tag:ci` e scope `auth_keys`
- [x] grant de `tag:ci` para `tag:ci-nexus` na 443
- [x] `dart pub token add` aceita a URL (exercitado pelo Teste D no runner)

> Tentativa de 2026-08-20: o sidecar sobe, alcança o control plane e gera
> nodekey, e então falha com `requested tags [tag:ci-nexus] are invalid or not
> permitted`. A tag precisa existir em `tagOwners` **e** a auth key precisa poder
> usá-la (uma key criada sem tag não consegue advertise). Alternativa para um
> teste rápido: `TS_EXTRA_ARGS=` vazio registra o nó sem tag, mas aí nenhum grant
> por tag se aplica e o nó passa a ser um device pessoal — não é o desenho.
- [ ] sidecar sobe (confirma que a interceptação de TLS não quebra o tailscaled)
- [ ] `archive_url` sai com o hostname da tailnet, confirmado por GET
- [ ] download de arquivo funciona pela tailnet
- [ ] `dart pub token add` aceita a URL (HTTPS)

### Fase 1 — identidade

- [x] variables criadas (`gh variable set`)
- [x] `NEXUS_INGEST_TOKEN` como repository secret
- [x] `NEXUS_CONSUMER_TOKEN` como repository secret
- [x] `NEXUS_PROMOTION_TOKEN` como **Environment** secret
- [x] `permissions: id-token: write` de volta, agora para a Tailscale
- [x] confirmado que o job de ingestão não lê o secret de promoção
      (asserção automática nos jobs sem `environment:`)
- [x] Environment com required reviewer mantido

### Fase 3 — workflows

- [x] `ingest-package.yml` migrado (`nexus-ingest-package.yml`)
- [x] `verify-setup.yml` migrado (`nexus-verify-setup.yml`)
- [x] `promote-sdk-baseline.yml` migrado (`nexus-promote-sdk-baseline.yml`)
- [x] `permissions: id-token: write` removido
- [x] `sed` do lockfile com o novo par de URLs

### Fase 4 — validação

- [ ] testes A a E
- [ ] baseline do SDK promovido
- [ ] `flutter pub get` contra production apenas
- [ ] `dart pub get --enforce-lockfile` contra production apenas
- [ ] package não promovido falha
