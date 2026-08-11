# POC — Governança de dependências Flutter/Dart com GitHub Actions + Cloudsmith

Controle de quais dependências públicas do `pub.dev` podem entrar no ecossistema
interno, usando GitHub Actions como plano de controle e Cloudsmith como registry.

Propriedade central:

> **Se uma versão não existe fisicamente em `flutter-production`, ela não está
> aprovada para consumo.**

`flutter-production` nunca tem upstream público.

---

## Arquitetura

```text
                         pub.dev
                            │ upstream (Cache and Proxy)
                            ▼
                 ┌─────────────────────┐
                 │ flutter-ingestion   │  private, upstream: pub.dev
                 └──────────┬──────────┘
                            │ resolve root + transitivos
                            ▼
                 ┌─────────────────────┐
                 │ GitHub Actions      │  pubspec.lock + evidência
                 └──────────┬──────────┘
                            ▼
                 ┌─────────────────────┐
                 │ GitHub Environment  │  aprovação manual
                 └──────────┬──────────┘
                            │ cloudsmith copy
                            ▼
                 ┌─────────────────────┐
                 │ flutter-production  │  private, upstream: NENHUM
                 └──────────┬──────────┘
                            ▼
              flutter pub get --enforce-lockfile
```

---

## Workflows

| Workflow | Para que serve |
|---|---|
| `.github/workflows/ingest-package.yml` | fluxo principal: resolve, pede aprovação, promove, verifica |
| `.github/workflows/verify-setup.yml` | preflight do setup Cloudsmith + teste negativo (Teste D) |

### `ingest-package.yml`

Dois jobs.

**`ingest`** — sem aprovação:

```text
setup Flutter → OIDC Cloudsmith → probe pubspec.yaml → flutter pub get
→ dart pub deps --json → valida sources → packages.tsv → job summary → artifact
```

**`promote-and-verify`** — bloqueado pelo Environment `cloudsmith-production`:

```text
download evidência → OIDC Cloudsmith → cloudsmith copy (por package)
→ troca a URL no lockfile → flutter pub get --enforce-lockfile
```

O segundo job **não recalcula** o grafo. Ele promove exatamente o grafo que foi
apresentado ao reviewer.

---

## Como executar

```text
Actions → Ingest Flutter/Dart package → Run workflow
```

Inputs:

| Input | Exemplo | Regra |
|---|---|---|
| `package` | `dio` | nome exato, `^[a-z][a-z0-9_]*$` |
| `version` | `5.9.0` | versão **exata**; `^5.9.0`, `>=5.0.0 <6.0.0` e `any` são rejeitados |
| `reason` | `HTTP client required by mobile application` | texto livre, vai para a evidência |

Depois:

1. o job `ingest` termina e publica o Job Summary com a lista de packages;
2. `promote-and-verify` fica em **Waiting**;
3. o reviewer revisa a lista e aprova o Environment;
4. a promoção roda e a verificação final contra production precisa passar.

---

## Configuração

### Repository variables

```text
Settings → Secrets and variables → Actions → Variables
```

| Variable | Valor |
|---|---|
| `CLOUDSMITH_NAMESPACE` | `mb-lucca` |
| `CLOUDSMITH_INGESTION_REPO` | `flutter-ingestion` |
| `CLOUDSMITH_PRODUCTION_REPO` | `flutter-production` |
| `CLOUDSMITH_INGEST_SERVICE` | `github-flutter-package-poc` |
| `CLOUDSMITH_PROMOTION_SERVICE` | `github-flutter-package-poc` |
| `FLUTTER_VERSION` | `3.44.9` |

As duas variables de service account são separadas de propósito. Na POC apontam
para o mesmo service account; o hardening futuro troca os valores sem alterar as
workflows.

**Nenhum secret é usado.** A autenticação com o Cloudsmith é via OIDC.

### GitHub Environment

```text
Settings → Environments → cloudsmith-production
Required reviewers: 1
Prevent self-review: desabilitado (conta pessoal: o requester é o único reviewer)
```

### Cloudsmith

```text
mb-lucca/flutter-ingestion    private, upstream Dart https://pub.dev (Cache and Proxy)
mb-lucca/flutter-production   private, sem upstream
```

Service account `github-flutter-package-poc` com `Write` nos dois repositories, e
a ação `Copy packages` satisfeita por `Write` (sem `Admin`).

### OIDC

```text
Provider URL: https://token.actions.githubusercontent.com

claims:
{
  "repository": "luccabaptistamb/poc-flutter-registry",
  "ref": "refs/heads/main"
}
```

As workflows fixam `oidc-audience: api.cloudsmith.io`. O default da
`cloudsmith-cli-action@v3` é `https://github.com/<owner>`, então **não** declare
`aud` nos claims sem alinhar os dois valores.

Também **não** declare `environment` nos claims: o job `ingest` roda sem
environment e o `promote-and-verify` roda com `cloudsmith-production`. Como os
claims declarados são exigidos em AND, declarar `environment` quebraria o job
`ingest`.

---

## Evidência

Cada run produz o artifact `package-approval-evidence` (30 dias):

| Arquivo | Conteúdo |
|---|---|
| `pubspec.yaml` | o probe exato que foi resolvido |
| `pubspec.lock` | versões concretas + content hashes SHA-256 + repository URL |
| `deps.json` | grafo completo (`dart pub deps --json`) |
| `packages.tsv` | `nome<TAB>versão` dos packages hosted a promover |

O restante da auditoria fica no próprio run do GitHub (requester, inputs, reason,
reviewer, aprovação, logs) e no Cloudsmith (packages e operações de cópia).

O artifact de aprovação **não é modificado**. A troca de URL do lockfile acontece
sobre a cópia baixada no job de promoção.

---

## Testes

| Teste | Como | Esperado |
|---|---|---|
| **A** happy path com transitivos | `ingest-package` com `dio` / `5.9.0` | promove root + transitivos, verificação final passa |
| **B** package Flutter | `ingest-package` com um package que usa Flutter SDK | resolve pelo ingestion; sources `sdk` não são promovidas |
| **C** approval | qualquer run válido | `promote-and-verify` fica em `Waiting`; nada em production antes da aprovação |
| **D** package não aprovado | `verify-setup` | `flutter pub get` contra production falha |
| **E** reexecução | repetir o mesmo package/version | packages já presentes são `skipped`; verificação passa |

O Teste D é automatizado no `verify-setup.yml`, que também valida OIDC, acesso aos
repositories e a ausência de upstream em production.

---

## Limitações conhecidas

**A promoção não é atômica.** `cloudsmith copy` opera um package por vez. Durante
a promoção production pode ficar temporariamente incompleto. Um consumer que
resolver nesse intervalo deve falhar. A solução oficial deve usar `concurrency`
para serializar promoções.

**O probe não representa os constraints de todas as aplicações.** A POC prova que
o package tem uma closure resolvível para o SDK configurado. Uma aplicação com
constraints próprios pode exigir outra versão transitiva, que precisará passar
pelo mesmo fluxo.

**Package já existente em production não é copiado de novo.** A integridade
continua sendo checada pelo content hash em `--enforce-lockfile`: se o artifact em
production tiver conteúdo diferente do aprovado, a verificação falha.

**Sources fora do hosted registry não são governadas aqui.** `PUB_HOSTED_URL`
controla o registry hosted default; não controla `git:`, `path:` ou `hosted:`
apontando para outro registry. As workflows falham se o grafo resolvido contiver
uma source inesperada, mas o guardrail definitivo pertence à CI dos consumidores.

---

## Fora de escopo

Security/compliance scanner, Cloudsmith Vulnerability/License Policies, SBOM,
portal, banco de auditoria, Jira/ServiceNow, SIEM, Terraform, reusable workflow,
cleanup/retention, workflow de exceção, múltiplos níveis de approval, revogação,
bloqueio de rede, governança de `git:`/`path:`, credenciais dos developers e
packages privados internos.

Todos podem ser adicionados depois sem alterar repositories, OIDC, promoção ou a
verificação de production.
