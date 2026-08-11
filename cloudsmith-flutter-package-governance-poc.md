# POC — Governança de dependências Flutter/Dart com GitHub Actions + Cloudsmith

> **Objetivo:** validar um fluxo simples, reproduzível e reaproveitável para controlar quais dependências públicas Flutter/Dart podem entrar no ecossistema interno.
>
> A POC usa GitHub Actions como plano de controle e Cloudsmith como registry. Segurança/compliance scanning fica fora do escopo e pode ser inserido posteriormente sem alterar o desenho principal.
>
> **Data de referência técnica:** 2026-08-10

---

## 1. Resultado esperado

A POC deve provar este fluxo:

```text
                         pub.dev
                            │
                            │ upstream
                            ▼
                 ┌─────────────────────┐
                 │ flutter-ingestion   │
                 │ private             │
                 │ upstream: pub.dev   │
                 └──────────┬──────────┘
                            │
                 resolve root + transitivos
                            │
                            ▼
                 ┌─────────────────────┐
                 │ GitHub Actions      │
                 │ lock + evidence     │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ GitHub Environment  │
                 │ manual approval     │
                 └──────────┬──────────┘
                            │
                     cloudsmith copy
                            │
                            ▼
                 ┌─────────────────────┐
                 │ flutter-production  │
                 │ private             │
                 │ upstream: NONE      │
                 └──────────┬──────────┘
                            │
                            ▼
              flutter pub get --enforce-lockfile
```

A propriedade central da solução é:

> **Se uma versão não existe fisicamente em `flutter-production`, ela não está aprovada para consumo.**

O repository de produção nunca possui upstream público.

---

## 2. Critérios de sucesso

A POC está concluída quando for possível demonstrar:

1. uma GitHub Action recebe `package`, `version` e `reason`;
2. a resolução usa `flutter-ingestion` como default hosted registry;
3. `flutter-ingestion` busca packages ausentes no `pub.dev` e os mantém em cache;
4. o package solicitado e todos os transitivos hosted necessários ficam disponíveis no ingestion;
5. o workflow produz um `pubspec.lock` com versões e hashes concretos;
6. a promoção fica bloqueada aguardando aprovação manual;
7. após aprovação, os artifacts são copiados de ingestion para production;
8. `flutter-production` permanece sem upstream;
9. o mesmo lockfile resolve usando somente production;
10. uma versão nunca promovida falha quando resolvida exclusivamente contra production.

Esses são os únicos requisitos funcionais da POC.

---

## 3. Escopo

### Incluído

- Cloudsmith Dart repository;
- upstream `pub.dev`;
- cache/proxy;
- repository separado de ingestion;
- repository separado de production;
- GitHub Actions;
- autenticação GitHub → Cloudsmith via OIDC;
- resolução de dependências Flutter/Dart;
- captura de dependências transitivas;
- `pubspec.lock` como evidência;
- approval via GitHub Environment;
- `cloudsmith copy`;
- teste end-to-end de production;
- teste negativo de package não aprovado.

### Fora de escopo

Não implementar nesta POC:

- security/compliance scanner;
- Cloudsmith Vulnerability Policies;
- Cloudsmith License Policies;
- policy engine próprio;
- SBOM;
- portal;
- banco de auditoria;
- Jira/ServiceNow;
- SIEM;
- Terraform;
- reusable workflow;
- automação de cleanup;
- retention customizada;
- workflow de exceção;
- múltiplos níveis de approval;
- automação de revogação;
- bloqueio VPN/firewall;
- governança de dependências `git:` ou `path:`;
- gerenciamento de credenciais dos developers;
- packages privados desenvolvidos internamente.

Esses itens podem ser adicionados depois sem alterar o fluxo base.

---

## 4. Premissas e pré-requisitos

### 4.1. Cloudsmith

É necessário:

- um Workspace/Namespace Cloudsmith;
- permissão para criar repositories;
- permissão para criar Service Accounts;
- permissão de Manager ou Owner para configurar OIDC;
- os dois repositories no **mesmo namespace**.

A operação `cloudsmith copy` só copia packages entre repositories pertencentes ao mesmo namespace.

---

### 4.2. GitHub

É necessário:

- um repository GitHub dedicado à POC;
- GitHub Actions habilitado;
- permissão para configurar repository variables;
- permissão para criar GitHub Environments;
- suporte a **Required Reviewers** no repository utilizado.

Para repositories privados no GitHub.com, Required Reviewers de Environments é um recurso de GitHub Enterprise. Se o plano utilizado não fornecer esse recurso, o mecanismo de approval precisa ser substituído antes da implementação.

Os exemplos usam:

```yaml
runs-on: ubuntu-latest
```

Um self-hosted runner também pode ser utilizado, desde que tenha:

- Bash;
- `jq`;
- acesso ao GitHub;
- acesso a `api.cloudsmith.io`;
- acesso a `dart.cloudsmith.io`;
- capacidade de instalar/executar Flutter.

O runner **não precisa acessar `pub.dev` diretamente**. Quem acessa `pub.dev` é o upstream do Cloudsmith.

---

### 4.3. Network enforcement

O bloqueio corporativo é uma responsabilidade externa à POC.

A arquitetura final assume:

```text
Developer
   │
   ├── dart.cloudsmith.io       ✅
   └── pub.dev                  ❌
```

e:

```text
Cloudsmith flutter-ingestion
   │
   └── pub.dev                  ✅
```

O mesmo princípio deve ser aplicado posteriormente aos runners consumidores.

---

## 5. Decisões arquiteturais

### 5.1. Dois repositories físicos

Usar:

```text
flutter-ingestion
flutter-production
```

Não usar um único repository com upstream como endpoint dos developers.

Isso evita o fluxo:

```text
Developer
   │
   ▼
Cloudsmith
   │
   ▼
pub.dev
```

que permitiria que um package ainda não aprovado fosse resolvido por meio do upstream.

---

### 5.2. `flutter-ingestion`

Configuração:

```text
Repository: flutter-ingestion
Visibility: Private
Format: Dart
Upstream URL: https://pub.dev
Upstream mode: Cache and Proxy
```

Responsabilidade:

```text
entrada controlada de packages públicos
```

Apenas a automação de ingestion deve precisar consumir esse repository.

Developers e pipelines normais não devem usá-lo.

---

### 5.3. `flutter-production`

Configuração:

```text
Repository: flutter-production
Visibility: Private
Format: Dart
Upstream: nenhum
```

Responsabilidade:

```text
allowlist física de packages aprovados
```

Se o package/version não existir nesse repository:

```text
flutter pub get
```

deve falhar.

---

### 5.4. Package Quarantine nativo

O estado nativo **Package Quarantine** do Cloudsmith não participa do fluxo de onboarding.

Os conceitos são:

| Conceito | Responsabilidade |
|---|---|
| `flutter-ingestion` | entrada controlada a partir do `pub.dev` |
| `flutter-production` | versões aprovadas |
| Package Quarantine nativo | bloquear posteriormente um artifact já existente |

Um uso futuro possível:

```text
package aprovado
      │
      │ finding posterior
      ▼
Cloudsmith Package Quarantine
      │
      ▼
novos downloads bloqueados
```

---

### 5.5. Unidade de promoção

A unidade real de promoção não é somente:

```text
package solicitado
```

Ela é:

```text
grafo hosted resolvido
```

Exemplo:

```text
package_a 1.0.0
├── package_b 2.0.0
├── package_c 3.1.0
└── package_d 4.0.0
```

Como production não possui upstream, todos os packages hosted necessários precisam existir em production.

A POC resolve uma **closure concreta** das dependências para o Flutter/Dart SDK configurado naquele momento.

Isso não significa aprovar todas as versões possíveis permitidas pelos constraints transitivos.

Um projeto consumidor com constraints diferentes pode posteriormente exigir outras versões e, nesse caso, essas versões também precisarão passar pelo fluxo de ingestion/promotion.

---

## 6. Evidência da resolução

Usar artefatos nativos do Pub sempre que possível.

A POC preserva:

```text
pubspec.yaml
pubspec.lock
deps.json
packages.tsv
```

### `pubspec.lock`

É a principal evidência técnica.

Ele registra para hosted packages:

- versão concreta;
- source;
- repository URL;
- SHA-256/content hash.

O hash permite validar posteriormente que production está entregando o mesmo conteúdo aprovado.

### `deps.json`

Gerado por:

```bash
dart pub deps --json
```

É utilizado para extrair o conjunto de packages hosted que precisam ser promovidos.

### `packages.tsv`

Formato mínimo:

```text
package_name<TAB>version
```

Exemplo:

```text
async	2.13.0
collection	1.19.1
dio	5.9.0
meta	1.16.0
```

Esse arquivo é apenas uma lista operacional para o `cloudsmith copy`.

Não criar um manifest customizado nesta fase.

---

## 7. Estrutura do repository GitHub

Manter o repository pequeno:

```text
flutter-package-governance/
│
├── .github/
│   └── workflows/
│       └── ingest-package.yml
│
└── README.md
```

Os comandos ficam inline na workflow durante a POC.

Criar `scripts/` somente quando a lógica já estiver validada e a extração realmente melhorar manutenção/testes.

---

## 8. Variáveis do GitHub

Criar em:

```text
Settings
→ Secrets and variables
→ Actions
→ Variables
```

### Repository variables

```text
CLOUDSMITH_NAMESPACE
CLOUDSMITH_INGESTION_REPO
CLOUDSMITH_PRODUCTION_REPO
CLOUDSMITH_INGEST_SERVICE
CLOUDSMITH_PROMOTION_SERVICE
FLUTTER_VERSION
```

Valores:

```text
CLOUDSMITH_NAMESPACE=<workspace-slug>

CLOUDSMITH_INGESTION_REPO=flutter-ingestion
CLOUDSMITH_PRODUCTION_REPO=flutter-production

CLOUDSMITH_INGEST_SERVICE=github-flutter-package-poc
CLOUDSMITH_PROMOTION_SERVICE=github-flutter-package-poc

FLUTTER_VERSION=<versão utilizada pelo ecossistema alvo>
```

`CLOUDSMITH_INGEST_SERVICE` e `CLOUDSMITH_PROMOTION_SERVICE` são variáveis distintas desde o início, mesmo que na POC apontem para o mesmo Service Account.

Isso permite separar as identidades futuramente sem alterar o desenho da workflow.

---

## 9. Service Account Cloudsmith

Para manter a POC simples, criar inicialmente:

```text
github-flutter-package-poc
```

Permissões necessárias:

```text
flutter-ingestion:
  Write

flutter-production:
  Write
```

`Write` inclui `Read`.

Também validar a configuração de **Repository Privileges** do Cloudsmith, porque a ação `Copy packages` pode ser configurada para exigir `Read`, `Write` ou `Admin`.

Para a POC, configurar `Copy packages` de forma que o Service Account consiga realizar a promoção sem receber `Admin`.

### Hardening posterior

A evolução natural é:

```text
github-pub-ingestion

flutter-ingestion:
  Write

flutter-production:
  None
```

e:

```text
github-pub-promotion

flutter-ingestion:
  Read

flutter-production:
  Write
```

A workflow já está preparada para essa separação através das duas variables de service slug.

---

## 10. OIDC GitHub → Cloudsmith

Não armazenar API key Cloudsmith estática no GitHub.

Fluxo:

```text
GitHub Runner
    │
    │ GitHub OIDC JWT
    ▼
Cloudsmith
    │
    │ temporary access token
    ▼
GitHub Runner
```

O token Cloudsmith emitido após o exchange é temporário.

---

### 10.1. Provider URL

No Cloudsmith:

```text
Workspace
→ Settings
→ Authentication
→ OpenID Connect
```

O **Provider URL precisa corresponder exatamente ao claim `iss`** do token emitido pelo GitHub.

Em GitHub.com padrão normalmente é:

```text
https://token.actions.githubusercontent.com
```

Em algumas configurações GitHub Enterprise Cloud, o issuer inclui o nome do enterprise.

Não assumir o issuer: validar o valor efetivo usado pela organização durante a configuração.

---

### 10.2. Required claims

Nunca criar o provider sem claims.

Para evitar dependência desnecessária do formato do claim `sub`, preferir claims explícitos.

Baseline recomendado:

```text
repository = <org>/flutter-package-governance
ref        = refs/heads/main
```

Opcionalmente adicionar:

```text
repository_owner
repository_id
repository_owner_id
```

O objetivo é garantir que outro repository ou branch não possa solicitar credenciais para o Service Account.

O formato default de `sub` do GitHub mudou em julho de 2026 para novos repositories, passando a incluir IDs imutáveis. Por isso, se `sub` for utilizado, primeiro observar o token real emitido para o repository e configurar o Cloudsmith para esse formato.

---

### 10.3. GitHub permissions

A workflow precisa de:

```yaml
permissions:
  contents: read
  id-token: write
```

`id-token: write` é necessário para solicitar o JWT do GitHub.

---

### 10.4. Cloudsmith Action

Usar a integração atual:

```yaml
- name: Configure Cloudsmith CLI with OIDC
  uses: cloudsmith-io/cloudsmith-cli-action@v3
  with:
    oidc-namespace: ${{ vars.CLOUDSMITH_NAMESPACE }}
    oidc-service-slug: ${{ vars.CLOUDSMITH_INGEST_SERVICE }}
    verify-auth: 'true'
    export-auth-token: 'true'
```

`verify-auth: 'true'` executa uma validação de autenticação e falha cedo em caso de configuração incorreta.

`export-auth-token: 'true'` é necessário nesta POC porque, além da CLI, o token precisa ser utilizado pelo `dart pub`.

Com essa opção a Action exporta:

```text
CLOUDSMITH_API_KEY
CLOUDSMITH_USERNAME
```

O `CLOUDSMITH_API_KEY` temporário será referenciado pelo Pub client através de `dart pub token add --env-var`.

---

## 11. GitHub Environment

Criar:

```text
Settings
→ Environments
→ cloudsmith-production
```

Configurar:

```text
Required reviewers: 1
Prevent self-review: enabled, se compatível com o processo desejado
```

Opcionalmente:

```text
Disallow admin bypass: enabled
```

O job:

```yaml
environment: cloudsmith-production
```

não será enviado para um runner até as protection rules do Environment serem satisfeitas.

Fluxo:

```text
ingest
  │
  ▼
Waiting for approval
  │
  ▼
promote-and-verify
```

Não implementar mecanismo paralelo de approval.

---

## 12. Inputs da workflow

Usar `workflow_dispatch`:

```yaml
on:
  workflow_dispatch:
    inputs:
      package:
        description: 'Package name'
        required: true
        type: string

      version:
        description: 'Exact package version'
        required: true
        type: string

      reason:
        description: 'Reason for adoption'
        required: true
        type: string
```

Exemplo:

```text
package = dio
version = 5.9.0
reason  = HTTP client required by mobile application
```

A versão solicitada deve ser exata.

Não usar:

```text
^5.9.0
>=5.0.0 <6.0.0
any
```

---

## 13. Tratamento seguro dos inputs

Inputs de `workflow_dispatch` não devem ser interpolados diretamente em scripts shell.

Usar:

```yaml
env:
  PACKAGE: ${{ inputs.package }}
  VERSION: ${{ inputs.version }}
  REASON: ${{ inputs.reason }}
```

e referenciar:

```bash
"$PACKAGE"
"$VERSION"
"$REASON"
```

Adicionar validação mínima:

```bash
if ! [[ "$PACKAGE" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "Invalid Dart package name: $PACKAGE" >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must be an exact SemVer-compatible value: $VERSION" >&2
  exit 1
fi
```

Essa validação não pretende substituir o parser do Pub.

Ela existe apenas para:

- impedir constraints/ranges;
- evitar shell/YAML injection;
- tornar a consulta Cloudsmith previsível.

O próprio Pub continua sendo a validação definitiva da versão.

---

## 14. Workflow: somente dois jobs

A workflow possui:

```text
ingest
promote-and-verify
```

### Job 1 — `ingest`

Responsabilidades:

```text
validate input
      ↓
setup Flutter
      ↓
OIDC Cloudsmith
      ↓
configure Pub → ingestion
      ↓
create temporary pubspec
      ↓
flutter pub get
      ↓
dart pub deps --json
      ↓
packages.tsv
      ↓
evidence artifact
```

### Job 2 — `promote-and-verify`

Responsabilidades:

```text
GitHub Environment approval
      ↓
download evidence
      ↓
OIDC Cloudsmith
      ↓
wait ingestion sync
      ↓
copy packages
      ↓
wait production sync
      ↓
rewrite repository URL in lockfile copy
      ↓
flutter pub get --enforce-lockfile
```

---

## 15. Criar o dependency probe

Não é necessário manter uma aplicação Flutter real no repository da POC.

Criar um `pubspec.yaml` temporário no runner.

Exemplo:

```yaml
- name: Create dependency probe
  shell: bash
  env:
    PACKAGE: ${{ inputs.package }}
    VERSION: ${{ inputs.version }}
  run: |
    set -euo pipefail

    if ! [[ "$PACKAGE" =~ ^[a-z][a-z0-9_]*$ ]]; then
      echo "Invalid Dart package name: $PACKAGE" >&2
      exit 1
    fi

    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
      echo "Version must be exact: $VERSION" >&2
      exit 1
    fi

    mkdir -p "$RUNNER_TEMP/package-probe"

    cat > "$RUNNER_TEMP/package-probe/pubspec.yaml" <<EOF
    name: package_governance_probe
    publish_to: none

    environment:
      sdk: ">=3.0.0 <4.0.0"

    dependencies:
      flutter:
        sdk: flutter

      ${PACKAGE}: ${VERSION}
    EOF
```

O probe inclui:

```yaml
flutter:
  sdk: flutter
```

porque o fluxo precisa funcionar com packages Flutter, não somente packages Dart puros.

Packages do Flutter SDK aparecem como sources `sdk` e não são promovidos.

Hosted dependencies do grafo são tratadas normalmente.

---

## 16. Configurar o registry de ingestion

URL:

```text
https://dart.cloudsmith.io/<namespace>/flutter-ingestion/
```

Step:

```yaml
- name: Configure ingestion registry
  shell: bash
  run: |
    set -euo pipefail

    INGESTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_INGESTION_REPO }}/"

    dart pub token add \
      "$INGESTION_URL" \
      --env-var CLOUDSMITH_API_KEY

    echo "INGESTION_URL=$INGESTION_URL" >> "$GITHUB_ENV"
```

O Pub não recebe o token em argumento nem o persiste como segredo em plaintext.

Ele registra que o token deve ser lido de:

```text
CLOUDSMITH_API_KEY
```

---

## 17. Resolver com cache isolado

Executar:

```yaml
- name: Resolve through ingestion
  working-directory: ${{ runner.temp }}/package-probe
  shell: bash
  run: |
    set -euo pipefail

    export PUB_HOSTED_URL="$INGESTION_URL"
    export PUB_CACHE="$RUNNER_TEMP/pub-cache-ingestion"

    flutter pub get
    dart pub deps --json > deps.json
```

O `PUB_CACHE` dedicado evita que um package já presente no cache default do runner esconda um problema no Cloudsmith.

Fluxo:

```text
flutter pub get
      │
      ▼
dart.cloudsmith.io/.../flutter-ingestion
      │
      ├── cache hit
      │
      └── cache miss
             │
             ▼
           pub.dev
```

---

## 18. Validar os sources resolvidos

A POC só sabe promover packages hosted.

Após gerar `deps.json`, validar que não existem sources inesperados:

```yaml
- name: Validate dependency sources
  working-directory: ${{ runner.temp }}/package-probe
  shell: bash
  run: |
    set -euo pipefail

    UNEXPECTED="$(
      jq -r '
        .packages[]
        | select(
            .source != "hosted"
            and .source != "sdk"
            and .source != "root"
          )
        | "\(.name)\t\(.version)\t\(.source)"
      ' deps.json
    )"

    if [[ -n "$UNEXPECTED" ]]; then
      echo "Unexpected dependency sources:" >&2
      echo "$UNEXPECTED" >&2
      exit 1
    fi
```

Para packages publicados no `pub.dev`, dependências `git:` e hosted em registries externos não são permitidas pelo próprio pub.dev.

Esse check existe para garantir que o algoritmo de promoção não ignore silenciosamente uma source não prevista.

---

## 19. Gerar `packages.tsv`

```yaml
- name: Build promotion list
  working-directory: ${{ runner.temp }}/package-probe
  shell: bash
  env:
    PACKAGE: ${{ inputs.package }}
    VERSION: ${{ inputs.version }}
  run: |
    set -euo pipefail

    jq -r '
      .packages[]
      | select(.source == "hosted")
      | [.name, .version]
      | @tsv
    ' deps.json \
      | sort -u \
      > packages.tsv

    if [[ ! -s packages.tsv ]]; then
      echo "No hosted packages were resolved." >&2
      exit 1
    fi

    if ! awk \
      -F '\t' \
      -v package="$PACKAGE" \
      -v version="$VERSION" \
      '$1 == package && $2 == version { found=1 } END { exit !found }' \
      packages.tsv
    then
      echo "Requested package/version is not present in resolved graph." >&2
      exit 1
    fi

    cat packages.tsv
```

A verificação final garante:

```text
requested = resolved
```

para o package raiz.

---

## 20. Job Summary para aprovação

O reviewer precisa enxergar rapidamente o que será promovido.

```yaml
- name: Write approval summary
  working-directory: ${{ runner.temp }}/package-probe
  shell: bash
  env:
    PACKAGE: ${{ inputs.package }}
    VERSION: ${{ inputs.version }}
    REASON: ${{ inputs.reason }}
  run: |
    set -euo pipefail

    PACKAGE_COUNT="$(wc -l < packages.tsv | tr -d ' ')"

    {
      echo "# Flutter/Dart package ingestion"
      echo
      printf '**Requested:** `%s@%s`\n\n' "$PACKAGE" "$VERSION"
      printf '**Requested by:** `%s`\n\n' "$GITHUB_ACTOR"
      printf '**Reason:** %s\n\n' "$REASON"
      printf '**Hosted packages to promote:** %s\n\n' "$PACKAGE_COUNT"
      echo "## Resolved hosted packages"
      echo
      echo '```text'
      cat packages.tsv
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
```

---

## 21. Preservar a evidência

Upload:

```yaml
- name: Upload approval evidence
  uses: actions/upload-artifact@v4
  with:
    name: package-approval-evidence
    retention-days: 30
    path: |
      ${{ runner.temp }}/package-probe/pubspec.yaml
      ${{ runner.temp }}/package-probe/pubspec.lock
      ${{ runner.temp }}/package-probe/deps.json
      ${{ runner.temp }}/package-probe/packages.tsv
```

A evidência da POC fica distribuída entre:

### GitHub run

- requester;
- timestamp;
- inputs;
- reason;
- logs;
- reviewer;
- approval/rejection;
- promotion result.

### Artifact

- `pubspec.yaml`;
- `pubspec.lock`;
- dependency graph;
- lista promovida.

### Cloudsmith

- cached packages;
- package copy operations;
- repository state.

Não criar uma base de auditoria adicional na POC.

---

## 22. Approval

Job:

```yaml
promote-and-verify:
  needs: ingest
  environment: cloudsmith-production
  runs-on: ubuntu-latest
```

Enquanto não houver aprovação:

```text
promote-and-verify
        │
        ▼
Waiting
```

Nenhum token OIDC do segundo job foi emitido e nenhum runner de promoção foi iniciado.

Após a aprovação, o job começa normalmente.

---

## 23. Reautenticar no job de promoção

OIDC é job-scoped/temporário.

Não tentar reaproveitar a autenticação do primeiro job.

```yaml
- name: Configure Cloudsmith CLI with OIDC
  uses: cloudsmith-io/cloudsmith-cli-action@v3
  with:
    oidc-namespace: ${{ vars.CLOUDSMITH_NAMESPACE }}
    oidc-service-slug: ${{ vars.CLOUDSMITH_PROMOTION_SERVICE }}
    verify-auth: 'true'
    export-auth-token: 'true'
```

---

## 24. Esperar sincronização no Cloudsmith

Packages recebidos através de upstream caching podem aparecer no repository enquanto o processamento interno ainda está ocorrendo.

A promoção não deve depender de timing.

Usar um helper pequeno inspirado no padrão documentado pelo próprio Cloudsmith.

```bash
wait_for_package_sync() {
  local repo="$1"
  local name="$2"
  local version="$3"

  local query="format:dart AND name:^${name}$ AND version:^${version}$"
  local result=""
  local count=0
  local package_id=""
  local status=""

  for attempt in $(seq 1 18); do
    result="$(
      cloudsmith ls pkg \
        "${CLOUDSMITH_NAMESPACE}/${repo}" \
        -q "$query" \
        -F json
    )"

    count="$(jq '.data | length' <<< "$result")"

    if [[ "$count" -gt 1 ]]; then
      echo "More than one package matched ${name}@${version} in ${repo}." >&2
      return 1
    fi

    if [[ "$count" -eq 1 ]]; then
      package_id="$(
        jq -r '.data[0].slug_perm // .data[0].slug' <<< "$result"
      )"

      status="$(
        cloudsmith status \
          "${CLOUDSMITH_NAMESPACE}/${repo}/${package_id}" \
          2>/dev/null || true
      )"

      if grep -q 'Completed' <<< "$status"; then
        printf '%s\n' "$package_id"
        return 0
      fi

      if grep -q 'Failed' <<< "$status"; then
        echo "Package synchronization failed: ${name}@${version}" >&2
        return 1
      fi
    fi

    sleep 10
  done

  echo "Timed out waiting for ${name}@${version} in ${repo}." >&2
  return 1
}
```

Timeout:

```text
18 × 10s = 180s
```

Para a POC, 3 minutos é suficiente para distinguir eventual consistency normal de um problema operacional.

---

## 25. Consultas Cloudsmith precisam ser exatas

Nunca usar:

```text
name:foo
version:1.2.3
```

como única seleção para promotion, porque `name:` sem anchors é uma busca textual.

Usar:

```text
name:^foo$
version:^1.2.3$
```

Query:

```text
format:dart AND name:^foo$ AND version:^1.2.3$
```

Isso evita promover um artifact errado devido a fuzzy matching.

---

## 26. Identificador do package

`cloudsmith copy` trabalha com o Unique ID do package.

No JSON do Cloudsmith, preferir:

```text
slug_perm
```

com fallback para:

```text
slug
```

Exemplo:

```bash
PACKAGE_ID="$(
  jq -r '.data[0].slug_perm // .data[0].slug' <<< "$RESULT"
)"
```

---

## 27. Promoção

A promoção percorre o `packages.tsv`.

Regras:

```text
package já existe em production e está sincronizado
    → skip

package não existe em production
    → localizar exatamente em ingestion
    → esperar sync
    → cloudsmith copy
    → esperar sync em production
```

Não implementar rollback/transação.

A operação é idempotente o suficiente para a POC porque packages já disponíveis em production são ignorados.

---

## 28. Step de promoção

```yaml
- name: Promote packages
  shell: bash
  env:
    CLOUDSMITH_NAMESPACE: ${{ vars.CLOUDSMITH_NAMESPACE }}
    INGESTION_REPO: ${{ vars.CLOUDSMITH_INGESTION_REPO }}
    PRODUCTION_REPO: ${{ vars.CLOUDSMITH_PRODUCTION_REPO }}
  run: |
    set -euo pipefail

    wait_for_package_sync() {
      local repo="$1"
      local name="$2"
      local version="$3"

      local query="format:dart AND name:^${name}$ AND version:^${version}$"
      local result=""
      local count=0
      local package_id=""
      local status=""

      for attempt in $(seq 1 18); do
        result="$(
          cloudsmith ls pkg \
            "${CLOUDSMITH_NAMESPACE}/${repo}" \
            -q "$query" \
            -F json
        )"

        count="$(jq '.data | length' <<< "$result")"

        if [[ "$count" -gt 1 ]]; then
          echo "Duplicate exact package match: ${name}@${version} in ${repo}" >&2
          return 1
        fi

        if [[ "$count" -eq 1 ]]; then
          package_id="$(
            jq -r '.data[0].slug_perm // .data[0].slug' <<< "$result"
          )"

          status="$(
            cloudsmith status \
              "${CLOUDSMITH_NAMESPACE}/${repo}/${package_id}" \
              2>/dev/null || true
          )"

          if grep -q 'Completed' <<< "$status"; then
            printf '%s\n' "$package_id"
            return 0
          fi

          if grep -q 'Failed' <<< "$status"; then
            echo "Package sync failed: ${name}@${version} in ${repo}" >&2
            return 1
          fi
        fi

        sleep 10
      done

      echo "Timeout: ${name}@${version} in ${repo}" >&2
      return 1
    }

    while IFS=$'\t' read -r NAME VERSION; do
      echo "Processing ${NAME}@${VERSION}"

      PROD_QUERY="format:dart AND name:^${NAME}$ AND version:^${VERSION}$"

      PROD_RESULT="$(
        cloudsmith ls pkg \
          "${CLOUDSMITH_NAMESPACE}/${PRODUCTION_REPO}" \
          -q "$PROD_QUERY" \
          -F json
      )"

      PROD_COUNT="$(jq '.data | length' <<< "$PROD_RESULT")"

      if [[ "$PROD_COUNT" -gt 1 ]]; then
        echo "Duplicate package in production: ${NAME}@${VERSION}" >&2
        exit 1
      fi

      if [[ "$PROD_COUNT" -eq 1 ]]; then
        wait_for_package_sync \
          "$PRODUCTION_REPO" \
          "$NAME" \
          "$VERSION" \
          >/dev/null

        echo "Already available in production; skipping copy."
        continue
      fi

      SOURCE_ID="$(
        wait_for_package_sync \
          "$INGESTION_REPO" \
          "$NAME" \
          "$VERSION"
      )"

      echo "Copying ${NAME}@${VERSION}"

      cloudsmith copy \
        "${CLOUDSMITH_NAMESPACE}/${INGESTION_REPO}/${SOURCE_ID}" \
        "${PRODUCTION_REPO}"

      wait_for_package_sync \
        "$PRODUCTION_REPO" \
        "$NAME" \
        "$VERSION" \
        >/dev/null

    done < "$RUNNER_TEMP/package-probe/packages.tsv"
```

A cópia mantém o package no ingestion.

Usar:

```text
copy
```

e não:

```text
move
```

---

## 29. Reproduzir o grafo em production

O `pubspec.lock` original aponta para o hosted repository usado durante ingestion.

Conceitualmente:

```yaml
description:
  name: some_package
  sha256: ...
  url: https://dart.cloudsmith.io/.../flutter-ingestion/
source: hosted
version: 1.2.3
```

Para testar production, trabalhar sobre a cópia baixada do artifact e substituir somente a URL:

```text
flutter-ingestion
       ↓
flutter-production
```

Não alterar:

- package names;
- versions;
- content hashes.

O artifact original de approval no GitHub permanece intacto.

---

## 30. Trocar somente a repository URL

```yaml
- name: Point lockfile to production
  shell: bash
  run: |
    set -euo pipefail

    INGESTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_INGESTION_REPO }}"
    PRODUCTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_PRODUCTION_REPO }}"

    sed -i \
      "s#${INGESTION_URL}#${PRODUCTION_URL}#g" \
      "$RUNNER_TEMP/package-probe/pubspec.lock"
```

As variáveis são propositalmente definidas sem depender de trailing slash, para que a substituição cubra a URL normalizada registrada pelo Pub.

---

## 31. Verificação com `--enforce-lockfile`

Configurar autenticação para production:

```yaml
- name: Configure production registry
  shell: bash
  run: |
    set -euo pipefail

    PRODUCTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_PRODUCTION_REPO }}/"

    dart pub token add \
      "$PRODUCTION_URL" \
      --env-var CLOUDSMITH_API_KEY

    echo "PRODUCTION_URL=$PRODUCTION_URL" >> "$GITHUB_ENV"
```

Executar com cache novo:

```yaml
- name: Verify production
  working-directory: ${{ runner.temp }}/package-probe
  shell: bash
  run: |
    set -euo pipefail

    export PUB_HOSTED_URL="$PRODUCTION_URL"
    export PUB_CACHE="$RUNNER_TEMP/pub-cache-production"

    flutter pub get --enforce-lockfile
```

`--enforce-lockfile` faz o comando falhar caso:

- o lockfile não seja uma resolução válida do `pubspec.yaml`;
- uma versão necessária não esteja disponível;
- o conteúdo de um hosted package não corresponda ao content hash salvo no lockfile.

Esse é o principal teste de integridade da POC.

---

## 32. Workflow completa de referência

Arquivo:

```text
.github/workflows/ingest-package.yml
```

```yaml
name: Ingest Flutter/Dart package

run-name: >-
  Ingest ${{ inputs.package }}@${{ inputs.version }}
  requested by ${{ github.actor }}

on:
  workflow_dispatch:
    inputs:
      package:
        description: Package name
        required: true
        type: string

      version:
        description: Exact package version
        required: true
        type: string

      reason:
        description: Reason for adoption
        required: true
        type: string

permissions:
  contents: read
  id-token: write

jobs:

  ingest:
    runs-on: ubuntu-latest

    steps:
      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ vars.FLUTTER_VERSION }}
          cache: true

      - name: Configure Cloudsmith CLI with OIDC
        uses: cloudsmith-io/cloudsmith-cli-action@v3
        with:
          oidc-namespace: ${{ vars.CLOUDSMITH_NAMESPACE }}
          oidc-service-slug: ${{ vars.CLOUDSMITH_INGEST_SERVICE }}
          verify-auth: 'true'
          export-auth-token: 'true'

      - name: Create dependency probe
        shell: bash
        env:
          PACKAGE: ${{ inputs.package }}
          VERSION: ${{ inputs.version }}
        run: |
          set -euo pipefail

          if ! [[ "$PACKAGE" =~ ^[a-z][a-z0-9_]*$ ]]; then
            echo "Invalid Dart package name: $PACKAGE" >&2
            exit 1
          fi

          if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
            echo "Version must be exact: $VERSION" >&2
            exit 1
          fi

          mkdir -p "$RUNNER_TEMP/package-probe"

          cat > "$RUNNER_TEMP/package-probe/pubspec.yaml" <<EOF
          name: package_governance_probe
          publish_to: none

          environment:
            sdk: ">=3.0.0 <4.0.0"

          dependencies:
            flutter:
              sdk: flutter

            ${PACKAGE}: ${VERSION}
          EOF

      - name: Configure ingestion registry
        shell: bash
        run: |
          set -euo pipefail

          INGESTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_INGESTION_REPO }}/"

          dart pub token add \
            "$INGESTION_URL" \
            --env-var CLOUDSMITH_API_KEY

          echo "INGESTION_URL=$INGESTION_URL" >> "$GITHUB_ENV"

      - name: Resolve through ingestion
        working-directory: ${{ runner.temp }}/package-probe
        shell: bash
        run: |
          set -euo pipefail

          export PUB_HOSTED_URL="$INGESTION_URL"
          export PUB_CACHE="$RUNNER_TEMP/pub-cache-ingestion"

          flutter pub get
          dart pub deps --json > deps.json

      - name: Validate dependency sources
        working-directory: ${{ runner.temp }}/package-probe
        shell: bash
        run: |
          set -euo pipefail

          UNEXPECTED="$(
            jq -r '
              .packages[]
              | select(
                  .source != "hosted"
                  and .source != "sdk"
                  and .source != "root"
                )
              | "\(.name)\t\(.version)\t\(.source)"
            ' deps.json
          )"

          if [[ -n "$UNEXPECTED" ]]; then
            echo "Unexpected dependency sources:" >&2
            echo "$UNEXPECTED" >&2
            exit 1
          fi

      - name: Build promotion list
        working-directory: ${{ runner.temp }}/package-probe
        shell: bash
        env:
          PACKAGE: ${{ inputs.package }}
          VERSION: ${{ inputs.version }}
        run: |
          set -euo pipefail

          jq -r '
            .packages[]
            | select(.source == "hosted")
            | [.name, .version]
            | @tsv
          ' deps.json \
            | sort -u \
            > packages.tsv

          if [[ ! -s packages.tsv ]]; then
            echo "No hosted packages were resolved." >&2
            exit 1
          fi

          if ! awk \
            -F '\t' \
            -v package="$PACKAGE" \
            -v version="$VERSION" \
            '$1 == package && $2 == version { found=1 } END { exit !found }' \
            packages.tsv
          then
            echo "Requested package/version was not resolved exactly." >&2
            exit 1
          fi

          cat packages.tsv

      - name: Write approval summary
        working-directory: ${{ runner.temp }}/package-probe
        shell: bash
        env:
          PACKAGE: ${{ inputs.package }}
          VERSION: ${{ inputs.version }}
          REASON: ${{ inputs.reason }}
        run: |
          set -euo pipefail

          PACKAGE_COUNT="$(wc -l < packages.tsv | tr -d ' ')"

          {
            echo "# Flutter/Dart package ingestion"
            echo
            printf '**Requested:** `%s@%s`\n\n' "$PACKAGE" "$VERSION"
            printf '**Requested by:** `%s`\n\n' "$GITHUB_ACTOR"
            printf '**Reason:** %s\n\n' "$REASON"
            printf '**Hosted packages to promote:** %s\n\n' "$PACKAGE_COUNT"
            echo "## Resolved hosted packages"
            echo
            echo '```text'
            cat packages.tsv
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Upload approval evidence
        uses: actions/upload-artifact@v4
        with:
          name: package-approval-evidence
          retention-days: 30
          path: |
            ${{ runner.temp }}/package-probe/pubspec.yaml
            ${{ runner.temp }}/package-probe/pubspec.lock
            ${{ runner.temp }}/package-probe/deps.json
            ${{ runner.temp }}/package-probe/packages.tsv


  promote-and-verify:
    needs: ingest
    environment: cloudsmith-production
    runs-on: ubuntu-latest

    steps:
      - name: Download approved evidence
        uses: actions/download-artifact@v4
        with:
          name: package-approval-evidence
          path: ${{ runner.temp }}/package-probe

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{ vars.FLUTTER_VERSION }}
          cache: true

      - name: Configure Cloudsmith CLI with OIDC
        uses: cloudsmith-io/cloudsmith-cli-action@v3
        with:
          oidc-namespace: ${{ vars.CLOUDSMITH_NAMESPACE }}
          oidc-service-slug: ${{ vars.CLOUDSMITH_PROMOTION_SERVICE }}
          verify-auth: 'true'
          export-auth-token: 'true'

      - name: Promote packages
        shell: bash
        env:
          CLOUDSMITH_NAMESPACE: ${{ vars.CLOUDSMITH_NAMESPACE }}
          INGESTION_REPO: ${{ vars.CLOUDSMITH_INGESTION_REPO }}
          PRODUCTION_REPO: ${{ vars.CLOUDSMITH_PRODUCTION_REPO }}
        run: |
          set -euo pipefail

          wait_for_package_sync() {
            local repo="$1"
            local name="$2"
            local version="$3"

            local query="format:dart AND name:^${name}$ AND version:^${version}$"
            local result=""
            local count=0
            local package_id=""
            local status=""

            for attempt in $(seq 1 18); do
              result="$(
                cloudsmith ls pkg \
                  "${CLOUDSMITH_NAMESPACE}/${repo}" \
                  -q "$query" \
                  -F json
              )"

              count="$(jq '.data | length' <<< "$result")"

              if [[ "$count" -gt 1 ]]; then
                echo "Duplicate exact match: ${name}@${version} in ${repo}" >&2
                return 1
              fi

              if [[ "$count" -eq 1 ]]; then
                package_id="$(
                  jq -r '.data[0].slug_perm // .data[0].slug' <<< "$result"
                )"

                status="$(
                  cloudsmith status \
                    "${CLOUDSMITH_NAMESPACE}/${repo}/${package_id}" \
                    2>/dev/null || true
                )"

                if grep -q 'Completed' <<< "$status"; then
                  printf '%s\n' "$package_id"
                  return 0
                fi

                if grep -q 'Failed' <<< "$status"; then
                  echo "Package sync failed: ${name}@${version} in ${repo}" >&2
                  return 1
                fi
              fi

              sleep 10
            done

            echo "Timeout: ${name}@${version} in ${repo}" >&2
            return 1
          }

          while IFS=$'\t' read -r NAME VERSION; do
            echo "Processing ${NAME}@${VERSION}"

            PROD_QUERY="format:dart AND name:^${NAME}$ AND version:^${VERSION}$"

            PROD_RESULT="$(
              cloudsmith ls pkg \
                "${CLOUDSMITH_NAMESPACE}/${PRODUCTION_REPO}" \
                -q "$PROD_QUERY" \
                -F json
            )"

            PROD_COUNT="$(jq '.data | length' <<< "$PROD_RESULT")"

            if [[ "$PROD_COUNT" -gt 1 ]]; then
              echo "Duplicate package in production: ${NAME}@${VERSION}" >&2
              exit 1
            fi

            if [[ "$PROD_COUNT" -eq 1 ]]; then
              wait_for_package_sync \
                "$PRODUCTION_REPO" \
                "$NAME" \
                "$VERSION" \
                >/dev/null

              echo "Already available in production; skipping copy."
              continue
            fi

            SOURCE_ID="$(
              wait_for_package_sync \
                "$INGESTION_REPO" \
                "$NAME" \
                "$VERSION"
            )"

            cloudsmith copy \
              "${CLOUDSMITH_NAMESPACE}/${INGESTION_REPO}/${SOURCE_ID}" \
              "${PRODUCTION_REPO}"

            wait_for_package_sync \
              "$PRODUCTION_REPO" \
              "$NAME" \
              "$VERSION" \
              >/dev/null

          done < "$RUNNER_TEMP/package-probe/packages.tsv"

      - name: Point lockfile to production
        shell: bash
        run: |
          set -euo pipefail

          INGESTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_INGESTION_REPO }}"
          PRODUCTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_PRODUCTION_REPO }}"

          sed -i \
            "s#${INGESTION_URL}#${PRODUCTION_URL}#g" \
            "$RUNNER_TEMP/package-probe/pubspec.lock"

      - name: Configure production registry
        shell: bash
        run: |
          set -euo pipefail

          PRODUCTION_URL="https://dart.cloudsmith.io/${{ vars.CLOUDSMITH_NAMESPACE }}/${{ vars.CLOUDSMITH_PRODUCTION_REPO }}/"

          dart pub token add \
            "$PRODUCTION_URL" \
            --env-var CLOUDSMITH_API_KEY

          echo "PRODUCTION_URL=$PRODUCTION_URL" >> "$GITHUB_ENV"

      - name: Verify production
        working-directory: ${{ runner.temp }}/package-probe
        shell: bash
        run: |
          set -euo pipefail

          export PUB_HOSTED_URL="$PRODUCTION_URL"
          export PUB_CACHE="$RUNNER_TEMP/pub-cache-production"

          flutter pub get --enforce-lockfile
```

---

## 33. Por que não executar `flutter pub get` novamente antes do approval

O segundo job não deve recalcular o grafo contra ingestion antes de copiar.

Queremos promover:

```text
o grafo que foi apresentado ao reviewer
```

e não:

```text
um grafo recalculado depois da aprovação
```

O job de promotion baixa os artifacts produzidos pelo job `ingest`.

A única resolução executada no segundo job é a verificação final contra production, usando o lockfile aprovado.

---

## 34. Testes da POC

Executar somente os testes necessários para validar o desenho.

### Teste A — Happy path com transitivos

Escolher um package com dependências transitivas.

Exemplo de execução:

```text
package = <package>
version = <exact version>
reason  = POC
```

Esperado:

```text
workflow starts
    ↓
ingestion resolves package
    ↓
root + transitives cached
    ↓
approval requested
    ↓
reviewer approves
    ↓
packages copied
    ↓
production --enforce-lockfile succeeds
```

Validar no Cloudsmith:

```text
flutter-ingestion
  contém root + transitivos

flutter-production
  contém root + transitivos aprovados
```

---

### Teste B — Flutter-specific package

Escolher um package que utilize Flutter SDK.

Esperado:

```text
flutter pub get
```

resolver corretamente pelo ingestion.

Isso comprova que o probe não funciona apenas com Dart puro.

---

### Teste C — Approval

Iniciar um package válido.

Esperado:

```text
ingest               ✅
promote-and-verify    Waiting
```

Antes do approval:

```text
package não está em production
```

Depois do approval:

```text
package é promovido
```

---

### Teste D — Package não aprovado

Escolher um package/version que:

```text
não está em flutter-production
```

Em uma máquina de teste:

```bash
export PUB_HOSTED_URL="https://dart.cloudsmith.io/<namespace>/flutter-production/"
flutter pub get
```

Esperado:

```text
FAIL
```

O Cloudsmith production não deve buscar o package no `pub.dev`.

---

### Teste E — Reexecução

Executar novamente o mesmo:

```text
package + version
```

Esperado:

```text
ingestion resolve              ✅
approval                       ✅
existing production packages  skip
production verification        ✅
```

Isso valida a idempotência mínima da promoção.

---

## 35. Definition of Done

A demonstração final deve ser:

```text
1. Abrir GitHub Actions.

2. Run workflow.

3. Informar:
   package
   exact version
   reason

4. A Action autentica no Cloudsmith via OIDC.

5. PUB_HOSTED_URL aponta para flutter-ingestion.

6. flutter pub get resolve root + transitivos.

7. A Action salva:
   pubspec.yaml
   pubspec.lock
   deps.json
   packages.tsv

8. promote-and-verify fica:
   Waiting for approval

9. O reviewer abre o run e revisa a lista de packages.

10. O reviewer aprova.

11. A Action executa:
    cloudsmith copy

12. Os artifacts aparecem em flutter-production.

13. A Action troca somente a URL do repository na cópia do lockfile.

14. A Action executa:
    flutter pub get --enforce-lockfile
    usando PUB_HOSTED_URL=flutter-production
    e PUB_CACHE limpo.

15. O comando termina com sucesso.

16. Um package não promovido é testado contra production.

17. A resolução falha.
```

Se esses passos funcionarem, a POC cumpriu o objetivo.

---

## 36. Limitações técnicas conhecidas da POC

### Promoção não é atômica

`cloudsmith copy` opera um package por vez.

Durante a promoção pode existir temporariamente um estado como:

```text
flutter-production
├── dependency_a  ✅
├── dependency_b  ✅
├── dependency_c  ⏳
└── root_package  ⏳
```

Isso é aceitável para a POC.

Um consumer que tentar resolver o grafo nesse intervalo deve falhar até que todos os packages estejam disponíveis.

A verificação final com:

```text
flutter pub get --enforce-lockfile
```

só conclui o workflow depois que o conjunto completo está utilizável.

Para a solução oficial, avaliar `concurrency` no GitHub Actions para serializar promotions que escrevem no mesmo production repository.

---

### O probe não representa constraints de todas as aplicações consumidoras

A POC resolve o package solicitado dentro de um projeto Flutter mínimo.

Ela prova:

```text
esse package/version possui uma closure resolvível
para o SDK configurado
```

Ela não prova que a mesma closure será escolhida por todas as aplicações existentes.

Uma aplicação com constraints próprios pode exigir uma versão transitiva diferente. Se essa versão não estiver em production, ela deverá passar pelo mesmo fluxo.

---

### Package já existente em production não é copiado novamente

Se `name + version` já existir em production, a promoção faz `skip`.

A integridade continua sendo testada no final pelo content hash presente no lockfile aprovado.

Se o artifact existente em production tiver conteúdo diferente, `--enforce-lockfile` deve falhar.

---

### Sources fora do hosted registry exigem governança separada

O mecanismo controla dependencies resolvidas pelo hosted repository.

Dependências `git:`, `path:` e `hosted:` apontando explicitamente para outro registry precisam de um guardrail próprio na solução oficial.

---

## 37. O que não deve virar requisito para concluir a POC

Não bloquear a avaliação esperando:

```text
scanner
Terraform
portal
dashboard próprio
SIEM
tickets
SBOM
automação de revogação
reusable workflow
configuração definitiva dos developers
```

Esses itens não validam a hipótese principal.

---

## 38. Evolução para solução oficial

A POC deve ser reaproveitada, não descartada.

A evolução recomendada é incremental.

### 38.1. Separar Service Accounts

Trocar:

```text
github-flutter-package-poc
```

por:

```text
github-pub-ingestion
github-pub-promotion
```

Sem alterar o fluxo.

---

### 38.2. Fortalecer OIDC da promoção

Associar a identidade de promotion somente ao contexto autorizado.

Exemplos de claims:

```text
repository
ref
environment
repository_id
```

Para isso pode ser utilizado um provider OIDC dedicado ao Service Account de promotion.

---

### 38.3. Serializar promotions

Adicionar `concurrency` ao job/workflow de promotion quando o fluxo passar a ser compartilhado por múltiplas solicitações.

Exemplo conceitual:

```yaml
concurrency:
  group: cloudsmith-flutter-production
  cancel-in-progress: false
```

Isso evita múltiplas promotions concorrentes alterando o mesmo repository enquanto ainda estamos trabalhando com cópias package-a-package.

---

### 38.4. Proteger a workflow

Proteger:

```text
.github/workflows/
```

por PR review/CODEOWNERS e regras da branch principal.

Como a workflow controla a promoção, alterações nesse arquivo fazem parte da superfície de segurança da solução.

---

### 38.5. Pin de Actions

Durante a POC é aceitável usar major tags para facilitar evolução:

```text
cloudsmith-io/cloudsmith-cli-action@v3
actions/upload-artifact@v4
actions/download-artifact@v4
subosito/flutter-action@v2
```

Antes do rollout oficial, pin third-party Actions por commit SHA.

Também considerar pin da versão do Cloudsmith CLI.

---

### 38.6. Infraestrutura como código

Somente após validar manualmente as configurações:

```text
repositories
upstream
privileges
Service Accounts
OIDC
```

migrar a configuração Cloudsmith para Terraform.

A configuração validada pela POC se torna a especificação do código de infraestrutura.

---

### 38.7. Security/compliance gate

Adicionar posteriormente:

```text
ingestion
   │
   ▼
security/compliance
   │
   ▼
approval
```

O scanner pode ser inserido entre a resolução e o Environment approval sem alterar:

- repositories;
- OIDC;
- promotion;
- production verification.

---

### 38.8. Revogação

Adicionar um fluxo separado:

```text
finding
   │
   ▼
review
   │
   ▼
Cloudsmith Package Quarantine
```

Não misturar revogação de artifacts previamente aprovados com onboarding de novos packages.

---

### 38.9. Consumer authentication

Definir posteriormente a identidade de leitura de production:

```text
developers
build CI
release CI
```

Opções Cloudsmith incluem usuários/teams e Entitlement Tokens read-only.

Não reutilizar o Service Account de promotion como credential dos consumers.

---

### 38.10. Guardrail para sources que bypassam o registry

`PUB_HOSTED_URL` controla o default hosted repository.

Ele não transforma o Cloudsmith em controle para:

```yaml
dependencies:
  foo:
    git: ...

  bar:
    path: ...

  baz:
    hosted: https://outro-registry.example.com
```

A solução oficial deve decidir se essas sources serão:

```text
bloqueadas
permitidas mediante exceção
governadas por outro processo
```

Uma validação simples de `pubspec.yaml`/`pubspec.lock` na CI dos consumidores pode ser adicionada sem alterar o registry.

---

## 39. Decisões que formam o núcleo da arquitetura

Estas decisões devem sobreviver à POC:

1. `flutter-production` não possui upstream público;
2. somente `flutter-ingestion` acessa `pub.dev`;
3. packages são promovidos fisicamente entre repositories;
4. a promoção é explícita e auditável;
5. GitHub Actions é o plano de controle;
6. GitHub Environment é o gate de aprovação;
7. OIDC é usado para autenticação CI → Cloudsmith;
8. `pubspec.lock` representa a resolução concreta aprovada;
9. production é validado com `--enforce-lockfile`;
10. scanners e políticas são extensões do fluxo, não requisito estrutural do registry.

---

## 40. Checklist de implementação

### Cloudsmith

- [ ] criar `flutter-ingestion`;
- [ ] configurar como private;
- [ ] configurar Dart upstream `https://pub.dev`;
- [ ] selecionar `Cache and Proxy`;
- [ ] criar `flutter-production`;
- [ ] configurar como private;
- [ ] confirmar que production não possui upstream;
- [ ] criar Service Account `github-flutter-package-poc`;
- [ ] dar Write nos dois repositories;
- [ ] validar `Copy packages` privilege;
- [ ] criar OIDC provider;
- [ ] configurar required claims;
- [ ] associar Service Account ao provider.

### GitHub

- [ ] criar repository;
- [ ] criar repository variables;
- [ ] criar Environment `cloudsmith-production`;
- [ ] configurar Required Reviewer;
- [ ] configurar Prevent self-review, se desejado;
- [ ] adicionar workflow;
- [ ] validar `id-token: write`.

### Workflow

- [ ] instalar Flutter;
- [ ] configurar Cloudsmith Action v3;
- [ ] usar `verify-auth: true`;
- [ ] usar `export-auth-token: true`;
- [ ] validar input;
- [ ] criar probe;
- [ ] configurar Pub token;
- [ ] definir `PUB_HOSTED_URL=ingestion`;
- [ ] usar `PUB_CACHE` isolado;
- [ ] executar `flutter pub get`;
- [ ] gerar `deps.json`;
- [ ] validar sources;
- [ ] gerar `packages.tsv`;
- [ ] validar root package/version;
- [ ] gerar Job Summary;
- [ ] salvar approval artifact;
- [ ] aguardar Environment approval;
- [ ] reautenticar no segundo job;
- [ ] esperar package sync;
- [ ] executar `cloudsmith copy`;
- [ ] esperar sync em production;
- [ ] substituir URL na cópia do lockfile;
- [ ] configurar token de production;
- [ ] usar novo `PUB_CACHE`;
- [ ] executar `flutter pub get --enforce-lockfile`.

### Validação

- [ ] happy path;
- [ ] package Flutter;
- [ ] approval bloqueia promotion;
- [ ] production funciona sem upstream;
- [ ] package não aprovado falha;
- [ ] rerun não cria problema.

---

## 41. Referências oficiais

Documentação consultada em 2026-08-10.

### Dart

Custom package repositories:

https://dart.dev/tools/pub/custom-package-repositories

`dart pub token`:

https://dart.dev/tools/pub/cmd/pub-token

`dart pub deps`:

https://dart.dev/tools/pub/cmd/pub-deps

`dart pub get` / `--enforce-lockfile`:

https://dart.dev/tools/pub/cmd/pub-get

Package lockfiles/content hashes:

https://dart.dev/tools/pub/packages

Package versioning:

https://dart.dev/tools/pub/versioning

---

### Cloudsmith

Dart Repository:

https://docs.cloudsmith.com/formats/dart-repository

Upstream proxying and caching:

https://docs.cloudsmith.com/repositories/upstreams

GitHub Actions OIDC:

https://docs.cloudsmith.com/authentication/setup-cloudsmith-to-authenticate-with-oidc-in-github-actions

Cloudsmith CLI:

https://docs.cloudsmith.com/developer-tools/cli

Copy a Package:

https://docs.cloudsmith.com/artifact-management/copy-a-package

Package Identification:

https://docs.cloudsmith.com/artifact-management/identifying-a-package

Package Search Syntax:

https://docs.cloudsmith.com/artifact-management/search-filter-sort-packages

Repository Privileges:

https://docs.cloudsmith.com/repositories/repository-privileges

Service Accounts:

https://docs.cloudsmith.com/accounts-and-teams/service-accounts

---

### GitHub

Deployments and Environments:

https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments

Reviewing deployments:

https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments

OpenID Connect reference:

https://docs.github.com/en/actions/reference/security/oidc

---

## 42. Resumo operacional

A POC exige apenas:

```text
2 Cloudsmith repositories
1 Cloudsmith Service Account
1 Cloudsmith OIDC provider
1 GitHub repository
1 GitHub Environment
1 GitHub workflow
2 jobs
```

Fluxo:

```text
workflow_dispatch(package, version, reason)
              │
              ▼
      flutter-ingestion
              │
              ▼
       pubspec.lock
       packages.tsv
              │
              ▼
       manual approval
              │
              ▼
       cloudsmith copy
              │
              ▼
      flutter-production
              │
              ▼
flutter pub get --enforce-lockfile
```

Esse é o menor fluxo que valida a arquitetura sem criar componentes descartáveis e, ao mesmo tempo, deixa uma base direta para hardening e evolução posterior.
