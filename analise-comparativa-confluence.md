# Análise comparativa — Cloudsmith vs. Sonatype Nexus CE

> Conteúdo target para a página do Confluence. Ainda não publicado.

As duas opções foram implementadas de verdade, no mesmo repositório, com o mesmo
modelo de governança, e ambas estão verdes. Este documento compara as duas com
base no que foi medido, não em documentação de fornecedor.

A conclusão em uma frase: **a governança funciona igual nas duas; a escolha é
sobre identidade, perímetro e quem opera a infraestrutura.**

---

## 1. Quadro de decisão

| Dimensão | Cloudsmith | Nexus CE | Vantagem |
|---|---|---|---|
| Identidade de CI | OIDC, token efêmero por run | usuário/senha estáticos | **Cloudsmith**, com folga |
| Pacotes no perímetro | não, ficam no fornecedor | sim, instância própria | **Nexus**, se houver requisito |
| Custo direto | recorrente por consumo (a partir de ~150 USD/mês em ago/2026) | licença zero | **Nexus** no direto |
| Custo indireto | nenhum | infra, backup, upgrade, rede, plantão | **Cloudsmith** |
| Promoção em lote | 52m42s para ~109 pacotes | 7m20s | **Nexus**, 7x |
| Promoção unitária | 44s para 16 pacotes | 14s | **Nexus** |
| Imutabilidade do aprovado | não configurada | `ALLOW_ONCE` no hosted | **Nexus** |
| Tetos | plano contratado | 40k componentes, 100k req/dia | **Cloudsmith** |
| Conectividade com runners | internet pública, nada a fazer | não resolvido pela POC | **Cloudsmith** |
| Maturidade da implementação | direta, sem surpresas | sete armadilhas fora da doc | **Cloudsmith** |
| Outros ecossistemas (Maven, npm) | por repositório contratado | mesma instância | **Nexus** |

Nenhuma das colunas ganha por soma de linhas. As duas primeiras dimensões são
eliminatórias e estão isoladas na seção 6.

---

## 2. O empate que importa: a governança

A propriedade central é idêntica nas duas:

> Se uma versão não existe fisicamente no repositório de produção, ela não está
> aprovada para consumo.

Também idênticos: dois repositórios físicos (ingestão com upstream do `pub.dev`,
produção sem upstream), promoção explícita por pacote, gate de aprovação em
GitHub Environment, `pubspec.lock` como evidência e `--enforce-lockfile` como
verificação final.

**A evidência de que isso não é retórica:** o baseline do Flutter SDK, derivado de
forma independente em cada frente com a mesma versão de SDK, produziu **109
pacotes nas duas**, diferindo em **uma única entrada** — `vm_service 15.2.0` no
Cloudsmith contra `15.3.0` no Nexus, efeito de as resoluções terem ocorrido em
datas diferentes.

Consequência prática: **trocar de registry não é reescrever a governança.** As
workflows mudaram ~14% em volume, quase tudo concentrado no mecanismo de
promoção. O que muda de verdade é o que cada opção exige do time.

---

## 3. Identidade — a diferença mais séria

| | Cloudsmith | Nexus CE |
|---|---|---|
| Mecanismo | OIDC, claims `repository` + `ref` | usuário/senha |
| Vida útil | um run | até rotação manual |
| Existe secret no repositório? | não | sim, um |
| Vínculo com repo/branch | imposto pelo provider | nenhum |

No Cloudsmith não há credencial para vazar, rotacionar ou revogar. No Nexus há, e
**não existe OIDC em nenhuma edição** — não é limitação da CE.

Duas observações que qualificam o tamanho do problema, uma em cada direção.

A favor do Nexus: a credencial de promoção existe **apenas** como Environment
secret do gate de aprovação, nunca como repository secret. O job de ingestão não
consegue lê-la, e isso é verificado automaticamente — o job referencia o secret e
falha se vier com valor. Na prática, o gate de aprovação é o que dá acesso à
credencial, com enforcement do GitHub. Fecha o cenário principal: job não
aprovado escrevendo em produção.

Contra o Nexus: o "token" do Nexus é `base64(user:senha)`. É obfuscação, não
tokenização — guardá-lo equivale a guardar a senha.

A mitigação reduz o risco, não o elimina, e não é equivalente a OIDC.

---

## 4. Desempenho medido

Tempo de step em runs reais, em runners hospedados do GitHub. Wall-clock foi
descartado porque inclui a espera pela aprovação humana.

| Etapa | Cloudsmith | Nexus CE |
|---|---|---|
| Resolver o grafo pelo ingestion (`dio` 5.9.0) | 46s | 1m04s |
| Promover 16 pacotes | 44s | **14s** |
| Promover o baseline (~109 pacotes) | 52m42s | **7m20s** |
| `flutter pub get --enforce-lockfile` | **24s** | 47s |

Por pacote na promoção do baseline: ~33s no Cloudsmith, ~4,4s no Nexus.

**O resultado contraria o que se esperava,** e o motivo é o ponto interessante. A
previsão era que o Nexus fosse mais lento, porque a CE não tem cópia server-side
e cada pacote trafega download + upload pelo runner, enquanto `cloudsmith copy` é
interno ao serviço. O que dominou não foi banda: foi a **espera de sincronização**
do Cloudsmith depois de cada cópia. O Nexus faz upload síncrono e não tem essa
etapa — o que também elimina uma classe de erro, a de promover, achar que
terminou e o pacote ainda não estar resolvível.

Onde o Nexus perde é no caminho do consumidor, 47s contra 24s. **Esse número não
mede o Nexus:** o tráfego passa pelo túnel provisório da POC. Numa exposição de
produção ele muda, e precisa ser remedido.

---

## 5. O que cada opção cobra do time

| | Cloudsmith | Nexus CE |
|---|---|---|
| Instância | — | dimensionar, operar, atualizar |
| Backup | — | volume de dados |
| Disponibilidade | do fornecedor | instância única é ponto de falha de todo build |
| TLS e DNS | — | certificado e nome estável obrigatórios |
| Conectividade com runners | — | **decisão de arquitetura em aberto** |
| Monitoramento | — | tetos da CE, saúde da instância, túnel |
| Jurídico | contrato comercial | EULA da CE, aceita em 12/08 na POC |
| Custo | fatura | infra mais tempo de time |

Três pontos merecem detalhe porque são os que subestimamos.

**Conectividade é o maior esforço não estimado.** Runners hospedados não alcançam
a instância. A POC resolveu com um sidecar Tailscale em container, escolhido por
um motivo circunstancial: o host é um Windows corporativo travado onde não se
instala o client, e o sidecar em userspace networking dispensa privilégios de
rede. Foi o caminho mais curto para provar o resto da arquitetura, **não é
production ready e não deve ser lido como proposta** — sidecar único no caminho de
todo build, estado do nó num volume Docker, ACLs configuradas à mão, auth key de
longa duração em arquivo local, nenhuma observabilidade.

Isso já falhou de forma concreta: em 24/08 um build quebrou com erro de socket
porque o serve config do túnel se perdeu num restart do Docker Desktop. A tailnet
aceitava a conexão sem nada escutando atrás, o Nexus estava sadio o tempo todo e
nenhum alarme disparou. Em produção o substituto é VPN corporativa, self-hosted
runners dentro do perímetro ou exposição controlada — **a POC não produziu
evidência sobre nenhuma dessas opções.**

**O hostname entra na evidência.** Cada entrada do `pubspec.lock` grava a URL do
host, então mudar o endereço invalida toda evidência já aprovada. O endpoint tem
de ser tratado como interface estável, com DNS próprio. Vale para as duas opções,
mas no Cloudsmith o endereço é do fornecedor e não muda.

**Os tetos da CE são reais.** 40.000 componentes e 100.000 requests/dia. A POC usa
pouco, mas um proxy de `pub.dev` cresce sozinho, e o teto de requests é diário —
CI de várias equipes pode encostar. Estourar significa Pro (custo) ou segmentar
instâncias (complexidade).

Do outro lado, a superfície de erro do Nexus é maior: sete armadilhas fora da
documentação custaram tempo na POC (todas registradas no repositório). Nenhuma foi
bloqueante, mas é risco de implementação que o Cloudsmith não apresentou.

---

## 6. As duas perguntas que decidem

**1. Os pacotes podem viver fora do perímetro?** Se não, o Cloudsmith está
descartado, e a discussão passa a ser como operar o Nexus com responsabilidade:
rede, backup, disponibilidade e tetos.

**2. Credencial estática é aceitável no lugar de OIDC?** Se não, o Nexus está
descartado, porque não há OIDC em nenhuma edição. A mitigação por Environment
secret fecha o cenário principal, mas não é equivalente.

Se as duas respostas forem permissivas, o critério é custo direto contra esforço
operacional, e as seções 4 e 5 são o insumo. Se as duas forem restritivas,
nenhuma das avaliadas serve e é preciso avaliar uma terceira opção que combine
self-hosting com identidade federada — trabalho que não foi feito.

---

## 7. O que foi validado

| Teste | Cloudsmith | Nexus |
|---|---|---|
| Happy path com transitivos (`dio` 5.9.0) | ✅ | ✅ 16 pacotes |
| Package com Flutter SDK (`shared_preferences`) | não executado | ✅ 22 pacotes, sources `sdk` excluídas |
| Gate de aprovação bloqueia a promoção | ✅ | ✅ |
| Package não aprovado falha em produção | ✅ | ✅ |
| Reexecução é idempotente | ✅ | ✅ |
| Baseline do SDK | ✅ 109 pacotes | ✅ 109 pacotes |
| `--enforce-lockfile` contra produção | ✅ | ✅ |
| Isolamento da credencial de promoção | n/a | ✅ verificado automaticamente |
| Consumidor local em container | não implementado | ✅ resolve e falha quando deve |

O teste com package do Flutter SDK não rodou no Cloudsmith — os cinco runs
daquela frente usaram o mesmo package. É lacuna de execução, não vantagem de
nenhum lado: o mecanismo é o mesmo código nas duas, e o baseline já o exercita.

---

## 8. Fora do escopo das duas POCs

Vale igual para as duas opções e não diferencia a escolha: promoção atômica,
retenção do repositório de ingestão, scanner de vulnerabilidade e licença,
governança de dependências `git:` e `path:`, credenciais dos developers, e o
upgrade de versão do SDK como processo em vez de execução manual.

Específico do Nexus, e o único item que pesa na decisão: **a arquitetura de rede
entre runners e instância.**

---

## Anexo — evidência

Todos os números vêm de execuções reais, auditáveis no histórico do repositório.

| Run | Frente | O que provou |
|---|---|---|
| 31535103642 | Cloudsmith | baseline de 109 pacotes, promoção em 52m42s |
| 31539602376 | Cloudsmith | `dio` 5.9.0, promoção em 44s, verificações verdes |
| 32398072600 | Nexus | identidade, isolamento da credencial, teste negativo |
| 32398271437 | Nexus | baseline, 100 promovidos em 7m20s |
| 32399777253 | Nexus | `dio` 5.9.0, verificações verdes |
| 32740640281 | Nexus | falha do túnel provisório da POC |
| 32741490883 | Nexus | `shared_preferences` 2.5.5, sources `sdk` excluídas |
