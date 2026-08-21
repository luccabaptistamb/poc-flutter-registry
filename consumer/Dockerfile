# A developer machine, as far as the governance model is concerned: a Flutter SDK
# that can only reach pub-production.
#
# The SDK version is pinned to the same value as the FLUTTER_VERSION variable in
# the workflows, and it must stay that way. The promoted baseline is per SDK
# version: with a different Flutter, the wrapper re-resolves flutter_tools with
# different pins and `flutter pub get` fails against production even though the
# application graph is approved.
#
# The tarball is the same artifact the runner downloads, pinned by the sha256
# that Google publishes in releases_linux.json.

FROM debian:bookworm-slim

ARG FLUTTER_VERSION=3.44.9
ARG FLUTTER_SHA256=a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils jq \
 && rm -rf /var/lib/apt/lists/*

# Flutter refuses to run several commands as root, so the consumer is a normal
# user, which is also what it is simulating.
RUN useradd --create-home --shell /bin/bash dev

WORKDIR /opt

RUN curl -fsSL -o flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && echo "${FLUTTER_SHA256}  flutter.tar.xz" | sha256sum -c - \
 && tar -xf flutter.tar.xz \
 && rm flutter.tar.xz \
 && chown -R dev:dev /opt/flutter

USER dev
ENV PATH="/opt/flutter/bin:${PATH}"

# Marks the SDK checkout as safe for this user; without it the flutter wrapper
# refuses to inspect its own git metadata.
RUN git config --global --add safe.directory /opt/flutter

COPY --chown=dev:dev app /home/dev/app
COPY --chown=dev:dev consume.sh /home/dev/consume.sh

WORKDIR /home/dev/app

ENTRYPOINT ["/home/dev/consume.sh"]
