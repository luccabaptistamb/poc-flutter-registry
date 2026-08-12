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

### Verificações da fase

**1. Base URL do Nexus.** O `archive_url` observado no Plano 1 é derivado da
requisição:

```text
archive_url: http://localhost:8081/repository/pub-ingestion/api/archives/dio-5.11.0.tar.gz
```

Através do túnel precisa virar o hostname do túnel. Se o Nexus estiver com Base
URL fixa apontando para outro lugar, o pub recebe URLs de arquivo inalcançáveis e
falha no download, mesmo com a metadata correta.

**2. `dart pub token add` exige HTTPS.** Não é possível autenticar por token em
`http://`, o que torna o TLS do túnel requisito funcional, não apenas de
segurança.

**3. Reescrita de `archive_url` através do túnel**, confirmada com um GET real
de metadata e um download do arquivo.

---

## Fase 1 — Identidade

| Onde | Nome | Valor |
|---|---|---|
| Variable | `NEXUS_BASE_URL` | `https://<hostname-estável>` |
| Variable | `NEXUS_INGESTION_REPO` | `pub-ingestion` |
| Variable | `NEXUS_PRODUCTION_REPO` | `pub-production` |
| Variable | `FLUTTER_VERSION` | `3.44.9` |
| **Repository** secret | `NEXUS_INGEST_TOKEN` | `base64(ci-ingestion:senha)` |
| **Environment** secret | `NEXUS_PROMOTION_TOKEN` | `base64(ci-promotion:senha)` |

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

## Checklist

### Fase 2 — promoção local

- [ ] `scripts/nexus-promote-packages.sh` criado com a interface `<tsv> [label]`
- [ ] skip de versão já existente em production
- [ ] download via `archive_url` da metadata do ingestion
- [ ] upload via components API com `pub.name`/`pub.version`/`pub.asset`
- [ ] `sha256` conferido após cada upload
- [ ] validado contra `localhost:8081` com um TSV de 3 packages
- [ ] reexecução resulta em todos `skipped`

### Fase 0 — exposição

- [ ] túnel com hostname estável e TLS
- [ ] hostname escolhido é o do deploy definitivo (ou aceito o custo de regerar)
- [ ] controle de acesso no túnel
- [ ] Base URL do Nexus coerente com o túnel
- [ ] `archive_url` reescrito para o hostname do túnel, confirmado por GET
- [ ] download de arquivo funciona pelo túnel
- [ ] `dart pub token add` aceita a URL (HTTPS)

### Fase 1 — identidade

- [ ] 4 repository variables criadas
- [ ] `NEXUS_INGEST_TOKEN` como repository secret
- [ ] `NEXUS_PROMOTION_TOKEN` como **Environment** secret
- [ ] confirmado que o job de ingestão não lê o secret de promoção
- [ ] Environment com required reviewer mantido

### Fase 3 — workflows

- [ ] `ingest-package.yml` migrado
- [ ] `verify-setup.yml` migrado
- [ ] `promote-sdk-baseline.yml` migrado
- [ ] `permissions: id-token: write` removido
- [ ] `sed` do lockfile com o novo par de URLs

### Fase 4 — validação

- [ ] testes A a E
- [ ] baseline do SDK promovido
- [ ] `flutter pub get` contra production apenas
- [ ] `dart pub get --enforce-lockfile` contra production apenas
- [ ] package não promovido falha
