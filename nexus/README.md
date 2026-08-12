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

## Quatro coisas que não estão na documentação e custaram tempo

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

**4. Negative cache de 24h esconde a correção.** O default do Nexus faz uma
falha transitória de saída continuar respondendo 404 por um dia, e um remote com
erro deixa o repositório em `AUTO_BLOCKED_UNAVAILABLE`. Depois de corrigir
qualquer coisa de rede é obrigatório invalidar o cache e esperar o bloqueio
expirar, senão parece que nada melhorou. O bootstrap usa TTL de 5 minutos.

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
