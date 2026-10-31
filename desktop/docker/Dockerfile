# Build environment of the desktop app: Rust, Node and the system libraries Tauri 2
# links against on Linux (webkit2gtk-4.1, appindicator for the tray, D-Bus for the
# Secret Service of keyring), and the cross build of the Windows NSIS installer the way
# Tauri documents it: the MSVC target, cargo-xwin (fetches the MSVC CRT and Windows SDK
# into its cache), clang/lld as the linker, makensis. Used by scripts/desktop-build.sh.
FROM node:22-bookworm-slim AS node

FROM rust:1.90-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
		libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
		libssl-dev libdbus-1-dev pkg-config file xdg-utils \
		nsis clang lld llvm \
	&& rm -rf /var/lib/apt/lists/*
# into /usr/local/cargo of the image: CARGO_HOME below is a volume for the registry only
RUN rustup target add x86_64-pc-windows-msvc \
	&& cargo install --locked cargo-xwin --version 0.23.1 --root /usr/local \
	&& rm -rf /usr/local/cargo/registry
# the build lists the NSIS setup with 7z: the app and WebView2 bootstrapper must be in it
RUN apt-get update && apt-get install -y --no-install-recommends p7zip-full \
	&& rm -rf /var/lib/apt/lists/*
# the installer script of Tauri includes Win\RestartManager.nsh, new in NSIS 3.09; bookworm
# has 3.08 (trixie would build the Linux packages against glibc 2.41). The header is only
# defines for the System plugin: taken from NSIS 3.10, checked by its hash
RUN curl -fsSL -o /usr/share/nsis/Include/Win/RestartManager.nsh \
		https://raw.githubusercontent.com/kichik/nsis/v310/Include/Win/RestartManager.nsh \
	&& echo "67149978412da9b283e2e1abe48a360093df9caf6363373e2cabe463978b7c0e  /usr/share/nsis/Include/Win/RestartManager.nsh" | sha256sum -c -
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
	&& ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
	&& node --version && npm --version
# the caches live in docker volumes (scripts/desktop-build.sh), the build as the caller;
# XDG_CACHE_HOME: the tools the Tauri bundler downloads (linuxdeploy, NSIS plugins)
ENV CARGO_HOME=/cache/cargo NPM_CONFIG_CACHE=/cache/npm CARGO_TARGET_DIR=/cache/target \
	XWIN_CACHE_DIR=/cache/xwin XDG_CACHE_HOME=/cache/tools APPIMAGE_EXTRACT_AND_RUN=1
WORKDIR /build
