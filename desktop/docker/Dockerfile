# Build environment of the desktop app for Linux: Rust, Node and the system libraries
# Tauri 2 links against (webkit2gtk-4.1, appindicator for the tray, D-Bus for the
# Secret Service of keyring). Used by scripts/desktop-build.sh.
FROM node:22-bookworm-slim AS node

FROM rust:1.90-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
		libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
		libssl-dev libdbus-1-dev pkg-config file xdg-utils \
	&& rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
	&& ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
	&& node --version && npm --version
# the caches live in docker volumes (scripts/desktop-build.sh), the build as the caller
ENV CARGO_HOME=/cache/cargo NPM_CONFIG_CACHE=/cache/npm CARGO_TARGET_DIR=/cache/target
WORKDIR /build
