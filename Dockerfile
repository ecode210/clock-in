# Builds the Flutter web bundle and serves it from nginx. Only the frontend
# lives here: Postgres, auth, storage and the manage-staff function stay on
# Supabase, so this image is a static site with no runtime configuration. The
# Supabase URL and publishable key come compiled in from
# lib/src/config/supabase_config.dart.
FROM debian:bookworm-slim AS build

# The SDK is cloned at a release tag rather than taken from a prebuilt image:
# the published `stable` image carries a Dart older than the ^3.12.2 this
# project requires, and only floating tags are available to pin instead.
ARG FLUTTER_VERSION=3.44.5
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git unzip xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$FLUTTER_VERSION" \
      https://github.com/flutter/flutter.git "$FLUTTER_HOME" \
  && git config --global --add safe.directory "$FLUTTER_HOME" \
  && flutter --version \
  && flutter precache --web

WORKDIR /app

# Dependencies resolve on their own layer so code edits do not refetch them.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# Icons are looked up at runtime through FLucideIcons, which the tree shaker
# cannot see, so shaking them would strip glyphs the app still draws.
# --pwa-strategy=none stops Flutter generating an offline-first worker, which
# would pin phones to a stale bundle after the next deploy.
RUN flutter build web --release --no-tree-shake-icons --pwa-strategy=none

FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
# Overwrites Flutter's empty worker with the uninstall script so phones that
# already installed the old worker pick this up and drop their cache.
COPY deploy/flutter_service_worker.js /usr/share/nginx/html/flutter_service_worker.js

EXPOSE 80
