# Consumidor local — Flutter contra `pub-production`

Simula uma máquina de developer: um SDK Flutter que só alcança
`pub-production`. É o outro lado da governança — as workflows provam que o grafo
aprovado chega em production, isto prova o que um consumidor consegue e não
consegue instalar.

```bash
consumer/run.sh             # resolve o app contra production
consumer/run.sh negative    # pede um package não aprovado, espera falhar
consumer/run.sh shell       # inspecionar por dentro
```

O wrapper deriva o token de `nexus/.credentials` na hora da chamada e passa por
ambiente, então nenhum segredo novo é gravado em arquivo.

## Resultado observado

```text
resolve    flutter pub get                  → 109 packages servidos por production
           flutter analyze --no-pub         → No issues found
           flutter pub get --enforce-lockfile → Got dependencies!
           pubspec.lock url:                 https://nexus-pub-poc.<tailnet>.ts.net/repository/pub-production/

negative   equatable any → could not find package equatable at
           https://nexus-pub-poc.<tailnet>.ts.net/repository/pub-production/
```

## Três decisões que não são óbvias

**A versão do SDK é fixada no Dockerfile, com sha256.** `3.44.9`, o mesmo valor
da variable `FLUTTER_VERSION`, e o mesmo tarball que o runner baixa, conferido
pelo hash publicado em `releases_linux.json`. O baseline promovido é **por versão
de SDK**: com outro Flutter, o wrapper reresolve o `flutter_tools` com pins
diferentes e `flutter pub get` falha contra production mesmo com o grafo da
aplicação aprovado. Trocar a versão aqui exige rodar
`nexus-promote-sdk-baseline.yml` antes.

**O container passa pelo hostname da tailnet, não por `http://nexus:8081`.** O
endereço interno é alcançável na mesma rede Docker, mas `dart pub token add`
recusa URL não-HTTPS, então autenticar por ele é impossível. Como o container não
é nó da tailnet, ele chega lá pelo proxy HTTP de saída do sidecar
(`https_proxy=http://nexus-tailscale:1055`). Efeito colateral bom: o caminho
exercitado é o mesmo do developer, TLS e token inclusive.

**`PUB_CACHE` é apagado a cada execução.** Com cache quente, uma resolução
bem-sucedida não prova nada sobre o que production serve — os arquivos já estariam
na máquina. O script recria o cache vazio e depois lista o que foi de fato
baixado.

## Limite conhecido

O `flutter analyze` roda, mas nada aqui compila para Android ou iOS: a imagem não
tem SDK de plataforma. O que está sendo validado é a resolução de dependências e
o toolchain Dart, que é onde a governança de packages atua.
