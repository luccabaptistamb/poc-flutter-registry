# Cloudsmith vs. Nexus CE — comparação das duas implementações

Documento para discussão com o time de arquitetura. As duas frentes foram
implementadas de verdade, no mesmo repositório, com o mesmo modelo de governança,
e ambas estão verdes. O que segue são os números medidos, as diferenças de
mecanismo e o que cada opção cobra do time.

Não é um documento de recomendação única: a escolha depende de duas perguntas que
só arquitetura responde, e elas estão isoladas na seção final.

---

## 1. O que não muda entre as duas

A propriedade central é a mesma, e é o que se está comprando em qualquer das
opções:

> Se uma versão não existe fisicamente no repositório de produção, ela não está
> aprovada para consumo.

Também são idênticos: os dois repositórios físicos (ingestão com upstream do
`pub.dev`, produção sem upstream), a promoção explícita por artifact, o gate de
aprovação em GitHub Environment, o `pubspec.lock` como evidência e
`--enforce-lockfile` como verificação final.

**Evidência de que o modelo é agnóstico ao registry:** o baseline do Flutter SDK,
derivado de forma independente em cada frente com a mesma `FLUTTER_VERSION`,
produziu **109 packages nas duas**, com diferença em **uma única entrada**:

```text
< vm_service  15.2.0     (Cloudsmith, resolvido em 11/08)
> vm_service  15.3.0     (Nexus,      resolvido em 20/08)
```

A diferença é a data da resolução, não o registry. Isso significa que a decisão
abaixo é sobre operação, custo e identidade — não sobre a governança.

---

## 2. Números medidos

Todos de runs reais deste repositório, em runners hospedados do GitHub. Tempo de
step, não de wall-clock (o wall-clock inclui a espera pela aprovação humana e não
diz nada sobre a tecnologia).

| Etapa | Cloudsmith | Nexus CE | Runs |
|---|---|---|---|
| Resolver grafo pelo ingestion (`dio` 5.9.0) | 46s | 1m04s | 31539602376 / 32399777253 |
| Promover 16 packages | **44s** | **14s** | idem |
| `dart pub get --enforce-lockfile` | 3s | 7s | idem |
| `flutter pub get --enforce-lockfile` | 24s | 47s | idem |
| Resolver baseline do SDK | 1m31s | 2m03s | 31535103642 / 32398271437 |
| **Promover baseline (~109 packages)** | **52m42s** | **7m20s** | idem |
| Entrar na rede privada | — | 4s | — |

Por package na promoção do baseline: **~33s no Cloudsmith, ~4,4s no Nexus.**

Esse resultado contraria a expectativa registrada no plano. A previsão era que o
Nexus fosse mais lento, porque em CE não existe cópia server-side e cada artifact
trafega download + upload pelo runner, enquanto `cloudsmith copy` é uma operação
interna do serviço. O que dominou não foi banda: foi a **espera de sincronização**
do Cloudsmith depois de cada cópia (`is_sync_completed`). O Nexus faz upload
síncrono e não tem essa etapa.

Onde o Nexus é mais lento é no caminho do consumidor — `flutter pub get` levou 47s
contra 24s. Parte disso é o tráfego passando pela tailnet em userspace
networking, que é característica da exposição escolhida na POC, não do Nexus.

---

## 3. Cloudsmith

### Prós

**Identidade sem segredo estático.** OIDC com claims `repository` + `ref`, token
de vida curta emitido por run. Nenhum secret no repositório. É a vantagem mais
difícil de replicar e a mais relevante em auditoria: não existe credencial para
vazar, rotacionar ou revogar.

**Zero day-2.** Sem instância para operar, atualizar, backupear ou monitorar. Sem
TLS para gerenciar, sem exposição de rede para resolver.

**Promoção é uma chamada.** `cloudsmith copy` move o artifact server-side; o
script de promoção tem 178 linhas contra 251 do equivalente Nexus, que precisa
baixar, conferir e subir.

**Superfície de erro conhecida.** A implementação não exigiu nenhuma descoberta
fora da documentação.

### Contras

**Custo recorrente por consumo.** Storage, transferência e seats. Como o proxy do
`pub.dev` acumula (só o toolchain do Flutter trouxe 109 packages), o custo cresce
com o uso. Números atuais devem sair da página de preços do fornecedor, não deste
documento.

**Dependência de terceiro no caminho crítico do build.** Indisponibilidade do
serviço para a CI e as máquinas dos developers. Não há mirror interno.

**Artifacts e metadados fora do perímetro.** Relevante se houver requisito de
residência de dados ou de inventário sob controle interno.

**Promoção lenta em lote.** 52m42s para o baseline, por causa da espera de sync.
Um upgrade de `FLUTTER_VERSION` paga esse custo inteiro de novo.

### Requisitos

```text
conta e billing no Cloudsmith
provider OIDC configurado com claims repository + ref
audiência alinhada (api.cloudsmith.io) entre provider e workflow
service account com Write nos dois repositories
```

---

## 4. Nexus Repository CE

### Prós

**Sem custo de licença e sem custo por consumo.** CE é gratuito. O custo é
infraestrutura e tempo do time.

**Artifacts dentro do perímetro.** O mirror do `pub.dev` é interno; a produção
também. Atende requisito de residência e dá resiliência se o `pub.dev` ficar
indisponível — o cache local continua servindo o que já foi promovido.

**Promoção em lote muito mais rápida.** 7m20s contra 52m42s, medido.

**Sem espera de sincronização.** O upload via components API é síncrono, o que
elimina uma classe de erro (promover, achar que terminou, e o package ainda não
estar resolvível).

**Imutabilidade por configuração.** `writePolicy: ALLOW_ONCE` no hosted impede
sobrescrever versão publicada. No Cloudsmith isso não foi configurado.

**Um único produto para outros ecossistemas.** Se amanhã entrar Maven, npm ou
Docker, a mesma instância atende. A POC cobre só `pub`, mas o desenho de dois
repositórios se repete.

### Contras

**Credencial estática, sem OIDC em nenhuma edição.** É a maior perda
arquitetural: some a expiração automática e o vínculo com `repository`/`ref`.

*Mitigação implementada e verificada:* a credencial de promoção existe **apenas**
como Environment secret do `nexus-production`, nunca como repository secret. O
job de ingestão não consegue lê-la, e isso é **asserção automática** — o job
referencia o secret e falha se vier com valor. O gate de aprovação passa a ser o
que dá acesso à credencial, com enforcement do GitHub. Não é equivalente a OIDC,
mas fecha o cenário principal (job não aprovado escrevendo em produção).

*Agravante honesto:* o "token" do Nexus é `base64(user:senha)`. Obfuscação, não
tokenização. Guardá-lo é guardar a senha.

**Teto do CE.** 40.000 componentes e 100.000 requests/dia. A POC usa pouco, mas
um proxy de `pub.dev` em uso real cresce, e o teto de requests é por dia — CI de
muitas equipes pode encostar nele. Estourar significa migrar para Pro (custo) ou
segmentar instâncias (complexidade).

**Exposição de rede é problema seu.** Runners hospedados não alcançam a
instância. Na POC isso foi resolvido com sidecar Tailscale e federated identity;
em produção é decisão de arquitetura de rede (VPN, self-hosted runners, ou
exposição controlada). **Este é o item de maior esforço não estimado.**

**Hostname entra na evidência.** Cada entrada do `pubspec.lock` grava a URL do
host. Mudar o endereço invalida toda evidência aprovada. Exige que o endpoint seja
tratado como interface estável e versionada, com DNS próprio.

**Day-2 é do time.** Backup do volume, upgrade, disponibilidade, certificado,
monitoramento do Usage Center. Uma instância única é ponto de falha do build de
todo mundo.

**EULA do CE.** Aceite jurídico, feito em 12/08 na POC com opt-in explícito. Se
houver revisão jurídica interna, é item de pauta.

**Superfície de erro não documentada.** Sete armadilhas custaram tempo e estão
registradas no `nexus/README.md`. Três merecem menção porque afetariam qualquer
implementação nova: o realm `PubToken` vem desativado e não vale para a REST API;
a Base URL só chega ao plugin `pub` **depois de restart** do Nexus, e sem isso o
consumidor recebe metadata correta com URLs de download inalcançáveis; e o
negative cache de 24h faz correções parecerem não ter funcionado.

### Requisitos

```text
host para a instância (a POC usou container; produção precisa de dimensionamento)
volume persistente com backup
TLS válido — dart pub token add recusa http://
DNS estável, porque o hostname entra no pubspec.lock
conectividade runner → instância
EULA aceita
credencial estática de promoção como Environment secret
acesso anônimo desabilitado (é opt-out no Nexus, ao contrário do Cloudsmith)
```

---

## 5. Diferenças de mecanismo, ponto a ponto

| Conceito | Cloudsmith | Nexus CE |
|---|---|---|
| Repo de entrada | `flutter-ingestion`, upstream Cache and Proxy | `pub-ingestion`, pub proxy |
| Repo aprovado | `flutter-production`, sem upstream | `pub-production`, pub hosted |
| Privacidade | `Private` (opt-in) | anônimo desabilitado (**opt-out**) |
| Identidade de CI | OIDC, token efêmero, claims `repository`+`ref` | usuário/senha estáticos |
| Onde vive a credencial | não existe | Environment secret do gate |
| Auth do cliente `pub` | `dart pub token add --env-var` | idem, token = `base64(user:senha)`, realm `PubToken` |
| Promoção | `cloudsmith copy` server-side | download do proxy + `POST /v1/components` |
| Espera de sync | necessária (`is_sync_completed`) | não existe |
| Imutabilidade | não configurada | `writePolicy: ALLOW_ONCE` |
| Idempotência | `skipped` se já existe | idem, e obrigatória por causa do `ALLOW_ONCE` |
| Rede | internet pública | tailnet/VPN, mais um join por job |
| Auth nas APIs internas | uma credencial, um esquema | `Basic` na REST API, `Bearer` no `/repository` |

---

## 6. Esforço de implementação

| | Cloudsmith | Nexus CE |
|---|---|---|
| Workflows + script de promoção | 1377 linhas | 1575 linhas |
| Infra (compose, bootstrap, verify, sidecar, consumidor) | — | 1154 linhas |
| Armadilhas fora da documentação | nenhuma registrada | sete registradas |
| Componentes a operar | nenhum | Nexus, sidecar de rede, credenciais |

O delta de workflow é pequeno (~14%). O custo real do Nexus não está nas
workflows, está no `bootstrap.sh` (17 KB), na exposição de rede e nas descobertas.

---

## 7. O que foi validado em cada frente

| Teste | Cloudsmith | Nexus |
|---|---|---|
| A — happy path com transitivos (`dio`) | ✅ | ✅ 16 packages, `promoted=2 skipped=14` |
| B — package com Flutter SDK | ✅ | pendente |
| C — gate de aprovação bloqueia | ✅ | ✅ |
| D — package não aprovado falha | ✅ | ✅ |
| E — reexecução é idempotente | ✅ | ✅ 9 de 109 vieram `skipped` |
| Baseline do SDK | ✅ 109 packages | ✅ 109 packages, `promoted=100` |
| `--enforce-lockfile` nos dois modos | ✅ | ✅ |
| Isolamento da credencial | n/a (não há credencial) | ✅ asserção automática |
| Consumidor local em container | não implementado | ✅ `consumer/`, resolve e teste negativo |

O consumidor em container existe só na frente Nexus, mas é portável: trocar
`PUB_HOSTED_URL` e o token o aponta para o Cloudsmith.

---

## 8. Riscos residuais, por frente

| Risco | Cloudsmith | Nexus CE |
|---|---|---|
| Vazamento de credencial | baixo (não há) | médio — mitigado pelo Environment secret |
| Indisponibilidade externa | fornecedor | `pub.dev` só afeta ingestão nova |
| Indisponibilidade interna | — | instância única para todos os builds |
| Custo crescente com uso | sim | só se estourar o teto do CE |
| Promoção não atômica | sim | sim — igual nas duas, mitigar com `concurrency` |
| Baseline por versão de SDK | sim | sim — igual nas duas |
| Superfície do repositório plano | sim | sim — igual nas duas |

As três últimas linhas são propriedades do desenho, não do produto. Valem ser
discutidas, mas não diferenciam as opções.

---

## 9. As duas perguntas que decidem

**1. Os artifacts podem viver fora do perímetro?** Se a resposta for não, o
Cloudsmith está descartado e a discussão passa a ser sobre como operar o Nexus
com responsabilidade — rede, backup, disponibilidade e o teto do CE.

**2. O time aceita credencial estática no lugar de OIDC?** Se a resposta for não,
o Nexus está descartado, porque não há OIDC em nenhuma edição. A mitigação
implementada fecha o cenário principal, mas não é equivalente.

Se as duas respostas forem permissivas, o critério passa a ser custo contra
esforço operacional, e aí os números da seção 2 e 6 são o insumo. Se as duas
forem restritivas, nenhuma das duas serve e o caminho é outro produto com OIDC e
self-hosting — Artifactory é o candidato óbvio, e não foi avaliado.

---

## 10. Pontos abertos que não são cobertos por nenhuma das POCs

- promoção atômica (`concurrency` serializando promoções);
- retenção e limpeza do repositório de ingestão, que cresce indefinidamente;
- scanner de vulnerabilidade e licença, fora de escopo nas duas frentes;
- governança de `git:` e `path:`, que `PUB_HOSTED_URL` não controla;
- credenciais dos developers (a POC usa uma identidade de leitura única);
- upgrade de `FLUTTER_VERSION` como processo, não como run manual.

---

## Anexo — evidência

| Run | Frente | O que provou |
|---|---|---|
| 31535103642 | Cloudsmith | baseline de 109 packages, promoção em 52m42s |
| 31539602376 | Cloudsmith | `dio` 5.9.0, promoção em 44s, verificações verdes |
| 32398072600 | Nexus | identidade, isolamento de credencial, teste negativo |
| 32398271437 | Nexus | baseline `promoted=100 skipped=9` em 7m20s |
| 32399777253 | Nexus | `dio` 5.9.0, `promoted=2 skipped=14`, verificações verdes |

Detalhamento: `README.md` (Cloudsmith), `nexus/README.md` (achados da instância),
`nexus/plano-2-troca-cloudsmith-nexus.md` (migração) e `consumer/README.md`.
