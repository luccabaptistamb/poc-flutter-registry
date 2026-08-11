# Cloudsmith — setup passo a passo para a POC de governança Flutter/Dart

> Escopo deste documento: **somente o que precisa ser criado/configurado no Cloudsmith**.
> GitHub (repository, variables, Environment, workflow) fica em outro passo.
>
> Referência: `cloudsmith-flutter-package-governance-poc.md`

---

## 0. Resumo do que será criado

| # | Objeto | Nome / valor | Observação |
|---|---|---|---|
| 1 | Repository | `flutter-ingestion` | Private, formato Dart, upstream `https://pub.dev` em **Cache and Proxy** |
| 2 | Repository | `flutter-production` | Private, formato Dart, **sem upstream** |
| 3 | Service Account | `github-flutter-package-poc` | `Write` nos dois repositories |
| 4 | Repository Privilege | ação `Copy packages` | Ajustada para não exigir `Admin` |
| 5 | OIDC Provider | GitHub Actions | Provider URL = claim `iss` real + required claims |
| 6 | Mapeamento | OIDC Provider → Service Account | Sem isso o token exchange falha |

Total: **2 repositories, 1 service account, 1 OIDC provider**.

Nenhum Terraform, nenhuma policy, nenhum scanner nesta fase.

---

## 1. Pré-requisitos

Antes de começar, confirme que você tem:

- [ ] acesso a um Workspace/Namespace Cloudsmith;
- [ ] role **Manager** ou **Owner** no workspace (obrigatório para configurar OIDC);
- [ ] permissão para criar repositories;
- [ ] permissão para criar Service Accounts;
- [ ] permissão para editar Repository Privileges.

Restrição arquitetural importante:

> Os dois repositories **precisam estar no mesmo namespace**.
> `cloudsmith copy` só copia entre repositories do mesmo namespace.

---

## 2. Passo 1 — Identificar o namespace (workspace slug)

O namespace é o identificador usado em todas as URLs e comandos.

Onde ver:

```text
Cloudsmith UI → canto superior → seletor de Workspace
→ Settings → General
```

Ou pela URL do browser:

```text
https://cloudsmith.io/~<namespace>/repos/
```

Anote o valor:

```text
CLOUDSMITH_NAMESPACE = <workspace-slug>
```

Use o **slug** (minúsculo, com hífens), não o nome de exibição.

---

## 3. Passo 2 — Criar o repository `flutter-ingestion`

```text
Repositories → Create Repository
```

Configuração:

```text
Name:               flutter-ingestion
Slug:               flutter-ingestion
Visibility:         Private
Storage region:     (default do workspace)
```

Notas:

- Cloudsmith não exige "escolher o formato" na criação do repository: o repository é multi-format e o formato Dart passa a existir quando o primeiro package Dart/upstream Dart é configurado. Se a sua UI pedir formato explicitamente, selecione **Dart**.
- **Private** é obrigatório. Um repository público expõe o cache de ingestion.

Resultado esperado — endpoint Dart:

```text
https://dart.cloudsmith.io/<namespace>/flutter-ingestion/
```

---

## 4. Passo 3 — Configurar o upstream `pub.dev` no ingestion

Este é o único ponto do sistema que fala com `pub.dev`.

```text
flutter-ingestion → Settings → Upstream Proxies (ou "Upstreams")
→ Add Upstream → Dart
```

Configuração:

```text
Name:            pub-dev
Upstream URL:    https://pub.dev
Mode:            Cache and Proxy
Auth mode:       None
Priority:        1
Active:          Yes
```

Sobre o **Mode**:

| Mode | Comportamento | Serve para a POC? |
|---|---|---|
| `Cache and Proxy` | resolve no upstream **e** persiste o artifact no repository | ✅ obrigatório |
| `Proxy Only` | resolve no upstream sem persistir | ❌ não há o que promover |
| `Cache Only` | não busca sob demanda | ❌ não ingere |

`Cache and Proxy` é o que garante o critério de sucesso nº 3 e nº 4 da POC: o package precisa **existir fisicamente** no ingestion para poder ser copiado depois.

Validação rápida (opcional, sem GitHub):

```bash
export PUB_HOSTED_URL="https://dart.cloudsmith.io/<namespace>/flutter-ingestion/"
# com token configurado, um pub get deve funcionar e o package deve aparecer na UI
```

---

## 5. Passo 4 — Criar o repository `flutter-production`

```text
Repositories → Create Repository
```

Configuração:

```text
Name:            flutter-production
Slug:            flutter-production
Visibility:      Private
```

E o ponto crítico:

```text
Upstream: NENHUM
```

- [ ] Abra `flutter-production → Settings → Upstream Proxies` e confirme que a lista está **vazia**.

> Se `flutter-production` tiver qualquer upstream público, a POC perde a propriedade central:
> "se a versão não existe fisicamente em production, ela não está aprovada".

Endpoint Dart resultante:

```text
https://dart.cloudsmith.io/<namespace>/flutter-production/
```

---

## 6. Passo 5 — Criar o Service Account

```text
Workspace → Settings → Service Accounts → Create Service Account
```

Configuração:

```text
Name:  github-flutter-package-poc
Slug:  github-flutter-package-poc
Role:  Member  (não usar Manager/Owner)
```

Anote o **slug** — ele é usado na workflow em:

```text
CLOUDSMITH_INGEST_SERVICE
CLOUDSMITH_PROMOTION_SERVICE
```

Nesta POC os dois apontam para o mesmo service account, mas permanecem variáveis separadas para permitir o split futuro (`github-pub-ingestion` / `github-pub-promotion`) sem alterar a workflow.

Não é necessário gerar API key estática. A autenticação será via OIDC.

---

## 7. Passo 6 — Dar privilégios nos repositories

Cloudsmith concede acesso a repository via privileges por usuário/service/team.

```text
flutter-ingestion → Settings → Privileges
→ adicionar Service Account: github-flutter-package-poc
→ Privilege: Write
```

```text
flutter-production → Settings → Privileges
→ adicionar Service Account: github-flutter-package-poc
→ Privilege: Write
```

Matriz da POC:

| Repository | Privilege | Por quê |
|---|---|---|
| `flutter-ingestion` | `Write` | disparar upstream cache + ler para copiar |
| `flutter-production` | `Write` | destino do `cloudsmith copy` + leitura na verificação |

`Write` inclui `Read`. **Não** conceder `Admin`.

Hardening posterior (documentado, não executar agora):

```text
github-pub-ingestion   → ingestion: Write   | production: None
github-pub-promotion   → ingestion: Read    | production: Write
```

---

## 8. Passo 7 — Validar o privilege exigido por `Copy packages`

Cloudsmith permite configurar **qual nível de privilege é exigido por ação** no repository. A ação `Copy packages` pode estar configurada para exigir `Read`, `Write` ou `Admin`.

```text
flutter-ingestion → Settings → Privileges (seção de ações / "Repository Privileges")
→ localizar a ação: Copy packages
```

Objetivo:

```text
Copy packages deve ser satisfeita por Write
```

- [ ] Se estiver como `Admin`, alterar para `Write`.
- [ ] Verificar também no `flutter-production`, já que a cópia escreve no destino.

Se essa configuração ficar em `Admin`, o job `promote-and-verify` vai falhar com erro de permissão no `cloudsmith copy` — e a alternativa (dar `Admin` ao service account) contraria o desenho da POC.

---

## 9. Passo 8 — Criar o OIDC Provider (GitHub → Cloudsmith)

```text
Workspace → Settings → Authentication → OpenID Connect
→ Add Provider
```

### 9.1. Provider URL

O Provider URL precisa ser **exatamente igual** ao claim `iss` do JWT emitido pelo GitHub.

GitHub.com padrão:

```text
https://token.actions.githubusercontent.com
```

Em algumas configurações **GitHub Enterprise Cloud** o issuer inclui o nome do enterprise, por exemplo:

```text
https://token.actions.githubusercontent.com/<enterprise-slug>
```

> ⚠️ Não assumir o issuer. Confirme o valor real antes de finalizar (ver 9.4).

**Trailing slash:** os exemplos do provider Terraform usam `https://token.actions.githubusercontent.com/` (com barra final) e descrevem o campo como a base de `/.well-known/openid-configuration`, enquanto o claim `iss` do GitHub vem **sem** barra final. Não foi possível confirmar se a Cloudsmith normaliza. Se `verify-auth` falhar, testar as duas formas é a primeira coisa a fazer.

### 9.2. Required claims

Nunca criar o provider sem claims — isso permitiria que qualquer repository do GitHub obtivesse credenciais.

**Formato:** os claims são um **objeto JSON plano** — mapa `claim → valor`, com **um único valor por claim**.

Confirmado no provider Terraform oficial (`claims` é `schema.TypeMap`, enviado à API como `map[string]interface{}`):
https://github.com/cloudsmith-io/terraform-provider-cloudsmith/blob/master/cloudsmith/resource_oidc.go

Valor para esta POC (confirmado com token real — ver 9.5):

```json
{
  "repository": "luccabaptistamb/poc-flutter-registry",
  "ref": "refs/heads/main"
}
```

Equivalente em Terraform (para a fase de IaC, seção 38.6 da POC):

```hcl
claims = {
  repository = "luccabaptistamb/poc-flutter-registry"
  ref        = "refs/heads/main"
}
```

Semântica:

| Aspecto | Comportamento |
|---|---|
| Múltiplos claims | avaliados em **AND** — o token precisa satisfazer todos |
| Múltiplos valores para o mesmo claim | **não existe** (é um mapa); sem `OR` |
| Wildcard | `*` no final do valor, ex. `"ref": "refs/heads/*"` |
| Claim ausente no token | falha na verificação |

Como não há `OR`, se no futuro for preciso aceitar mais de uma branch/environment, as opções são wildcard ou **um provider OIDC por contexto** (que é justamente o caminho sugerido na seção 38.2 da POC para separar a identidade de promotion).

Opcionalmente, para robustez contra rename de owner/repo, é possível usar IDs imutáveis (valores reais deste repo):

```json
{
  "repository_id": "1331259250",
  "repository_owner_id": "254526108",
  "ref": "refs/heads/main"
}
```

**Não declare `environment`.** O job `ingest` roda sem environment (claim `null`) e o job `promote-and-verify` roda com `environment: cloudsmith-production`. Como os claims declarados são exigidos em AND, declarar `environment` no provider único da POC faria o job `ingest` falhar. Claims que existem no token mas não são declarados no provider são simplesmente ignorados — então `repository` + `ref` autentica os dois jobs.

**Não declare `aud`.** O audience efetivo solicitado pela `cloudsmith-cli-action@v3` não foi verificado nesta POC (o valor observado em 9.5 veio de um probe com audience hardcoded). Declarar `aud` sem essa confirmação é uma causa provável de falha em `verify-auth`.

Evite depender do claim `sub`: o formato default de `sub` do GitHub mudou em julho de 2026 para novos repositories, passando a incluir IDs imutáveis. Isso foi confirmado neste repository (ver 9.5).

> Na UI pode ser um editor key/value ou um textarea JSON — o conteúdo é idêntico nos dois casos.

### 9.3. Associar o Service Account e habilitar

```text
Name:            github-poc-flutter-registry
Enabled:         Yes
Service Account: github-flutter-package-poc
```

O provider precisa estar **enabled** (no schema da API/Terraform é campo obrigatório) — um provider criado e desabilitado falha silenciosamente no exchange.

Sem o mapeamento para o Service Account o exchange OIDC retorna erro de autorização mesmo com o issuer e os claims corretos.

### 9.4. Como descobrir o `iss` e os claims reais (recomendado)

Antes de fechar a configuração, rode uma workflow mínima no repository da POC:

```yaml
name: Inspect OIDC claims
on: workflow_dispatch
permissions:
  id-token: write
  contents: read
jobs:
  claims:
    runs-on: ubuntu-latest
    steps:
      - name: Print selected claims
        run: |
          set -euo pipefail
          TOKEN="$(
            curl -sSf \
              -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
              "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api.cloudsmith.io" \
            | jq -r '.value'
          )"

          # decodifica somente o payload e imprime apenas os claims relevantes
          PAYLOAD="$(cut -d. -f2 <<< "$TOKEN")"
          PAYLOAD="$(printf '%s' "$PAYLOAD" | tr '_-' '/+')"
          printf '%s' "$PAYLOAD" \
            | base64 -d 2>/dev/null \
            | jq '{iss, aud, sub, repository, repository_owner, repository_id, ref, environment}'
```

Notas de segurança:

- não imprima o token inteiro no log;
- o log dessa run deve ser tratado como sensível;
- apague/desabilite essa workflow depois de coletar os valores.

Use o `iss` retornado como Provider URL e os valores retornados de `repository`/`ref` como required claims.

---

### 9.5. Valores observados neste repository

Executado em `luccabaptistamb/poc-flutter-registry`:

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "aud": "api.cloudsmith.io",
  "sub": "repo:luccabaptistamb@254526108/poc-flutter-registry@1331259250:ref:refs/heads/main",
  "repository": "luccabaptistamb/poc-flutter-registry",
  "repository_owner": "luccabaptistamb",
  "repository_id": "1331259250",
  "ref": "refs/heads/main",
  "environment": null
}
```

Leitura destes valores:

| Claim | Observação |
|---|---|
| `iss` | GitHub.com padrão, **sem trailing slash** → usar como Provider URL |
| `aud` | ⚠️ veio do `audience=api.cloudsmith.io` hardcoded no probe; **não** é evidência do audience usado pela `cloudsmith-cli-action@v3` |
| `sub` | já no **formato novo** (jul/2026) com IDs imutáveis embutidos → confirma a decisão de não usar `sub` |
| `repository_owner` | é uma **conta pessoal**, não uma organização (ver alerta abaixo) |
| `environment` | `null` porque o probe não declara `environment:`; no job `promote-and-verify` será `cloudsmith-production` |

Configuração resultante do provider:

```text
Provider URL: https://token.actions.githubusercontent.com

claims:
{
  "repository": "luccabaptistamb/poc-flutter-registry",
  "ref": "refs/heads/main"
}
```

- [ ] Remover ou desabilitar a workflow de inspeção de claims após esta etapa.

> ⚠️ **Risco fora do Cloudsmith:** o repository pertence a uma conta pessoal. Em repositories **privados**, as protection rules de GitHub Environments (incluindo **Required reviewers**) exigem GitHub Pro/Team/Enterprise — e sem elas o critério de sucesso nº 6 da POC (promoção bloqueada aguardando aprovação manual) não é demonstrável.
>
> **Solução para conta Free: tornar o repository público.** Ambientes, secrets de ambiente e deployment protection rules estão disponíveis em repositories públicos em todos os planos atuais do GitHub (a exclusão é apenas para planos legados Bronze/Silver/Gold).
> Fonte: https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment
>
> Ao tornar o repo público, considerar:
>
> - **Não habilitar "Prevent self-review"** — sendo conta pessoal, você é o único reviewer possível e o gate ficaria impossível de satisfazer. Auto-aprovação ainda valida o Teste C: o job permanece em `Waiting` e nada é promovido antes da aprovação explícita.
> - Logs, Job Summary e artifacts passam a ser públicos, incluindo o `reason` e o `packages.tsv`. Conteúdo é uma lista de packages públicos do pub.dev — impacto baixo para a POC.
> - Nenhum secret é exposto: a autenticação é OIDC e o provider está restrito a `repository` + `ref`, então forks e outras branches não conseguem obter token.
> - `workflow_dispatch` exige permissão de write no repository, então usuários externos não disparam a workflow.
>
> A alternativa é usar um plano ou organização com Environments protegidos em repo privado.

---

## 10. Passo 9 — Validação do setup Cloudsmith

Checagens que podem ser feitas antes de rodar a workflow completa.

### 10.1. Endpoints

```text
https://dart.cloudsmith.io/<namespace>/flutter-ingestion/
https://dart.cloudsmith.io/<namespace>/flutter-production/
```

Confirme na UI de cada repository (seção Setup / Instructions do formato Dart) que a URL exibida coincide com esse padrão. Se o seu workspace usa domínio próprio, adote a URL exibida pela UI e ajuste a workflow.

### 10.2. CLI autenticada (após OIDC configurado)

Com o token OIDC exportado pela Action, ou localmente com uma API key pessoal:

```bash
# lista packages (deve retornar vazio no início)
cloudsmith ls pkg "<namespace>/flutter-ingestion" -F json | jq '.data | length'
cloudsmith ls pkg "<namespace>/flutter-production" -F json | jq '.data | length'
```

### 10.3. Teste negativo do production (critério de sucesso nº 10)

Depois que production existir e antes de qualquer promoção:

```bash
export PUB_HOSTED_URL="https://dart.cloudsmith.io/<namespace>/flutter-production/"
export PUB_CACHE="$(mktemp -d)"
# em um projeto probe qualquer
flutter pub get
```

Esperado: **falha**. Production não deve buscar nada em `pub.dev`.

Se isso **passar**, existe upstream configurado em production — volte ao Passo 4.

### 10.4. Busca exata

Ao validar manualmente, use sempre queries com anchors:

```text
format:dart AND name:^dio$ AND version:^5.9.0$
```

`name:dio` sem anchors é busca textual e pode retornar artifacts errados.

---

## 11. Valores derivados para as GitHub Variables

Ao final do setup Cloudsmith você terá tudo para preencher:

```text
CLOUDSMITH_NAMESPACE        = <workspace-slug>
CLOUDSMITH_INGESTION_REPO   = flutter-ingestion
CLOUDSMITH_PRODUCTION_REPO  = flutter-production
CLOUDSMITH_INGEST_SERVICE   = github-flutter-package-poc
CLOUDSMITH_PROMOTION_SERVICE= github-flutter-package-poc
FLUTTER_VERSION             = <versão do ecossistema alvo>
```

(`FLUTTER_VERSION` não vem do Cloudsmith — vem do ecossistema Flutter que você quer representar.)

---

## 12. Checklist final — Cloudsmith

### Repositories

- [ ] `flutter-ingestion` criado
- [ ] `flutter-ingestion` é **Private**
- [ ] upstream Dart `https://pub.dev` adicionado no ingestion
- [ ] upstream mode = **Cache and Proxy**
- [ ] upstream ativo
- [ ] `flutter-production` criado
- [ ] `flutter-production` é **Private**
- [ ] `flutter-production` **sem nenhum upstream** (lista vazia confirmada)
- [ ] ambos no **mesmo namespace**

### Identidade

- [ ] Service Account `github-flutter-package-poc` criado
- [ ] slug do service account anotado
- [ ] privilege `Write` em `flutter-ingestion`
- [ ] privilege `Write` em `flutter-production`
- [ ] nenhum `Admin` concedido
- [ ] ação `Copy packages` satisfeita por `Write`

### OIDC

- [ ] claim `iss` real observado no token do GitHub — feito (9.5)
- [ ] OIDC Provider criado com Provider URL `https://token.actions.githubusercontent.com`
- [ ] claims configurados: `{"repository": "luccabaptistamb/poc-flutter-registry", "ref": "refs/heads/main"}`
- [ ] `aud` **não** declarado
- [ ] `environment` **não** declarado
- [ ] provider associado ao Service Account
- [ ] provider **enabled**
- [ ] workflow de inspeção de claims removida/desabilitada

### Validação

- [ ] endpoints Dart confirmados na UI
- [ ] `cloudsmith ls pkg` funciona nos dois repositories
- [ ] teste negativo: `pub get` contra production falha

---

## 13. Troubleshooting comum

| Sintoma | Causa provável | Ação |
|---|---|---|
| `verify-auth` falha na Action | Provider URL ≠ `iss` | reconfirmar `iss` real (seção 9.4) e testar com/sem trailing slash |
| `verify-auth` falha com claims corretos | claim declarado que o token não possui (ex. `aud` errado) | remover o claim extra; claims são avaliados em AND |
| Exchange OIDC autoriza mas sem acesso ao repo | service account sem privilege | Passo 6 |
| `cloudsmith copy` retorna 403 | `Copy packages` exigindo `Admin` | Passo 7 |
| `copy` retorna "not found" para o namespace destino | repositories em namespaces diferentes | recriar no mesmo namespace |
| `pub get` no ingestion falha com 401 | token Pub não registrado para a URL exata (com trailing slash) | `dart pub token add <url>/ --env-var CLOUDSMITH_API_KEY` |
| Package não aparece no ingestion após `pub get` | upstream em `Proxy Only` | mudar para `Cache and Proxy` |
| Package aparece mas `copy` falha | sync interno ainda em andamento | é o caso que o `wait_for_package_sync` da workflow cobre |
| `pub get` contra production **funciona** para package não promovido | production tem upstream | remover upstream de production |
| Query retorna mais de 1 resultado | busca sem anchors `^...$` | usar `name:^x$ AND version:^y$` |

---

## 14. O que NÃO configurar no Cloudsmith nesta POC

Explicitamente fora de escopo:

- Vulnerability Policies
- License Policies
- Package Quarantine (é mecanismo de revogação posterior, não de onboarding)
- Entitlement Tokens para developers
- Retention / cleanup policies customizadas
- Terraform / provider Cloudsmith
- Webhooks, SIEM, SBOM
- Teams e mapeamento de developers

Esses itens entram depois sem alterar repositories, OIDC nem o fluxo de promoção.

---

## 15. Pontos a confirmar na UI real

Não consegui validar os rótulos exatos da UI atual do Cloudsmith durante a escrita deste documento (as páginas de docs não renderizaram no fetch). Os nomes abaixo podem diferir ligeiramente:

- seção de upstream: `Upstream Proxies` vs `Upstreams`;
- rótulo do modo: `Cache and Proxy` vs `Cache & Proxy`;
- se a criação do repository pede formato explícito ou é multi-format;
- onde exatamente vive a configuração de privilege por ação (`Copy packages`);
- caminho exato de `Settings → Authentication → OpenID Connect`;
- se o campo de claims na UI é editor key/value ou textarea JSON (o conteúdo é o mesmo — objeto JSON plano, confirmado na seção 9.2);
- se `provider_url` aceita/normaliza trailing slash.

O **conteúdo** de cada configuração (valores, modos, privileges, claims) está correto conforme o desenho da POC; apenas a navegação pode variar. Referências oficiais:

- https://docs.cloudsmith.com/formats/dart-repository
- https://docs.cloudsmith.com/repositories/upstreams
- https://docs.cloudsmith.com/repositories/repository-privileges
- https://docs.cloudsmith.com/accounts-and-teams/service-accounts
- https://docs.cloudsmith.com/authentication/setup-cloudsmith-to-authenticate-with-oidc-in-github-actions
- https://docs.cloudsmith.com/artifact-management/copy-a-package
- https://docs.cloudsmith.com/artifact-management/search-filter-sort-packages
