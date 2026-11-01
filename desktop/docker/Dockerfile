# Build environment of the desktop app: Rust, Node and the system libraries Tauri 2
# links against on Linux (webkit2gtk-4.1, appindicator for the tray, D-Bus for the
# Secret Service of keyring), and the cross build of the Windows NSIS installer the way
# Tauri documents it: the MSVC target, cargo-xwin (fetches the MSVC CRT and Windows SDK
# into its cache), clang/lld as the linker, makensis. Used by scripts/desktop-build.sh,
# also for signing the packages (tauri CLI, minisign) in a container without network.
#
# Pinned for a reproducible build: the base images by digest, the tools by version and
# sha256, the MSVC CRT and Windows SDK versions of xwin. To move one, change it here and
# check the build (sh scripts/desktop-build.sh).
FROM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da AS node

FROM rust:1.90-bookworm@sha256:3914072ca0c3b8aad871db9169a651ccfce30cf58303e5d6f2db16d1d8a7e58f
RUN apt-get update && apt-get install -y --no-install-recommends \
		libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
		libssl-dev libdbus-1-dev pkg-config file xdg-utils \
		nsis clang lld llvm \
	&& rm -rf /var/lib/apt/lists/*
# into /usr/local/cargo of the image: CARGO_HOME below is a volume for the registry only
RUN rustup target add x86_64-pc-windows-msvc \
	&& cargo install --locked cargo-xwin --version 0.23.1 --root /usr/local \
	&& rm -rf /usr/local/cargo/registry
# the build lists the NSIS setup with 7z: the app and WebView2 bootstrapper must be in it;
# minisign checks the update signatures against the public key of tauri.conf.json
RUN apt-get update && apt-get install -y --no-install-recommends p7zip-full minisign \
	&& rm -rf /var/lib/apt/lists/*
# the installer script of Tauri includes Win\RestartManager.nsh, new in NSIS 3.09; bookworm
# has 3.08 (trixie would build the Linux packages against glibc 2.41). The header is only
# defines for the System plugin: taken from NSIS 3.10, checked by its hash
RUN curl -fsSL -o /usr/share/nsis/Include/Win/RestartManager.nsh \
		https://raw.githubusercontent.com/kichik/nsis/v310/Include/Win/RestartManager.nsh \
	&& echo "67149978412da9b283e2e1abe48a360093df9caf6363373e2cabe463978b7c0e  /usr/share/nsis/Include/Win/RestartManager.nsh" | sha256sum -c -
# What the Tauri bundler would download into $XDG_CACHE_HOME/tauri at every AppImage build,
# under the names it looks for: its AppRun and linuxdeploy (fixed releases of tauri-apps;
# linuxdeploy with the AppImage magic bytes 8-10 zeroed, as the bundler leaves it, so that it
# runs without FUSE) and linuxdeploy-plugin-appimage, which the bundler takes from the moving
# "continuous" tag: a fixed release here. The NSIS plugins the bundler checks by hash itself.
RUN mkdir -p /opt/tauri-cache/tauri && cd /opt/tauri-cache/tauri \
	&& curl -fsSL -o AppRun-x86_64 \
		https://github.com/tauri-apps/binary-releases/releases/download/apprun-old/AppRun-x86_64 \
	&& curl -fsSL -o linuxdeploy-07333c6-x86_64.AppImage \
		https://github.com/tauri-apps/binary-releases/releases/download/linuxdeploy-07333c6/linuxdeploy-x86_64.AppImage \
	&& curl -fsSL -o linuxdeploy-plugin-appimage.AppImage \
		https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-appimage-x86_64.AppImage \
	&& printf '%s  %s\n' \
		f30140a43a0a59e46db21bdefdf749b9e9f2c6946e92afabbacf98b8ae73fb4f AppRun-x86_64 \
		36a2d7e274d12e1050d0e9ecfe11d339ed54720b2bec464c286d53f8b07f5c62 linuxdeploy-07333c6-x86_64.AppImage \
		992d502a248e14ab185448ddf6f6e7d25558cb84d4623c354c3af350c25fccb3 linuxdeploy-plugin-appimage.AppImage \
		| sha256sum -c - \
	&& printf '\0\0\0' | dd of=linuxdeploy-07333c6-x86_64.AppImage bs=1 seek=8 conv=notrunc status=none \
	&& echo "bd9521cd5ff3ca351fecb78cd9b236a4e37b3621014ac05cac0c2d767ffa0474  linuxdeploy-07333c6-x86_64.AppImage" | sha256sum -c - \
	&& chmod 755 ./*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
	&& ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
	&& node --version && npm --version
# `tauri signer sign` for the signing step, which runs without network and without the
# project's node_modules; the version of desktop/package-lock.json
RUN npm install -g --no-audit --no-fund @tauri-apps/cli@2.12.4 && tauri --version
# the caches live in docker volumes (scripts/desktop-build.sh), the build as the caller;
# XWIN_*: the MSVC CRT and Windows SDK cargo-xwin takes (x64 only)
ENV CARGO_HOME=/cache/cargo NPM_CONFIG_CACHE=/cache/npm CARGO_TARGET_DIR=/cache/target \
	XWIN_CACHE_DIR=/cache/xwin XWIN_ARCH=x86_64 XWIN_CRT_VERSION=14.44.17.14 XWIN_SDK_VERSION=10.0.26100 \
	XDG_CACHE_HOME=/opt/tauri-cache APPIMAGE_EXTRACT_AND_RUN=1
WORKDIR /build
