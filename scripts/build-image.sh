#!/bin/bash
# build-image.sh — Quick firmware packaging using ImageBuilder
#
# Usage:
#   ./scripts/build-image.sh              Quick mode (FILES injection, daily development)
#   ./scripts/build-image.sh --release    Release mode (apk package management, official release)
#
# Prerequisite: Run build-full.sh at least once (to generate ImageBuilder + .apk repository)
set -e

MODE="quick"
[ "$1" = "--release" ] && MODE="release"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"
UI_DIR="$BUILD_DIR/../bpirouter-ui"
FEEDS_DIR="$BUILD_DIR/../bpirouter-feeds"
IB_DIR="$BUILD_DIR/imagebuilder"

C='\033[0;36m'
G='\033[0;32m'
R='\033[0;31m'
Y='\033[0;33m'
N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }

echo -e "${Y}Build mode: ${MODE}${N}"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 0. Find or extract ImageBuilder
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ ! -d "$IB_DIR/staging_dir" ]; then
    step "Setting up ImageBuilder..."
    # Prefer ImageBuilder from build-full.sh (contains custom kernel + matching signature keys)
    IB_TAR=$(ls "$WORK_DIR/bin/targets/mediatek/filogic/"*imagebuilder*.tar.* 2>/dev/null | head -1)
    if [ -z "$IB_TAR" ]; then
        if [ "$MODE" = "release" ]; then
            # Release mode doesn't allow using official ImageBuilder:
            # 1. Official IB doesn't contain custom kernel patches
            # 2. Official IB's apk public keys don't trust locally-compiled .apk packages (signature mismatch)
            echo -e "${R}Release mode requires local ImageBuilder from build-full.sh.${N}"
            echo -e "${R}Official ImageBuilder cannot verify locally-signed .apk packages.${N}"
            echo "  Run: ./scripts/build-full.sh"
            exit 1
        fi
        # Quick mode: allow fallback to official ImageBuilder (this mode doesn't install local .apk)
        step "No local ImageBuilder found. Downloading official..."
        IB_URL="https://downloads.openwrt.org/releases/25.12.2/targets/mediatek/filogic/"
        IB_FILE=$(curl -sL "$IB_URL" | grep -o 'openwrt-imagebuilder[^"]*\.tar\.[xz|zst]*' | head -1)
        if [ -z "$IB_FILE" ]; then
            echo -e "${R}Cannot find ImageBuilder. Run build-full.sh first.${N}"
            exit 1
        fi
        wget -P /tmp "$IB_URL/$IB_FILE"
        IB_TAR="/tmp/$IB_FILE"
    fi
    mkdir -p "$IB_DIR"
    tar xf "$IB_TAR" --strip-components=1 -C "$IB_DIR"
    ok "ImageBuilder ready"
fi

# ── Sync build keys (resolve apk signature verification) ──
# Even if ImageBuilder is from local build-full.sh, explicitly sync keys for consistency
# Locally compiled .apk packages are signed with private keys in openwrt/keys/,
# ImageBuilder needs the corresponding public keys to pass apk's UNTRUSTED signature verification
if [ -d "$WORK_DIR/keys" ]; then
    step "Syncing build keys for apk signature verification..."
    mkdir -p "$IB_DIR/keys"
    cp -f "$WORK_DIR/keys/"* "$IB_DIR/keys/" 2>/dev/null
    ok "Build keys synced: $(ls $IB_DIR/keys/ | wc -l) key files"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. Build BpiRouter application layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Building Go API (aarch64)..."
cd "$UI_DIR/backend"
[ ! -f go.sum ] && go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -ldflags="-s -w" -o /tmp/bpirouter-apid ./cmd/apid/
ok "Go binary"

step "Building Vue frontend..."
cd "$UI_DIR/frontend"
[ -d node_modules ] || npm ci --silent
npx vite build --outDir /tmp/bpirouter-www/
ok "Frontend"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. Choose packaging method based on mode
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Base packages + WiFi replacement (common to both modes)
BASE_PACKAGES="nginx-ssl openssl-util wireguard-tools openvpn-openssl \
    kmod-mt7996e kmod-mt7996-firmware wpad-mbedtls \
    luci luci-ssl \
    -wpad-basic-mbedtls"

cd "$IB_DIR"

if [ "$MODE" = "release" ]; then
    # ── Release mode: Register local apk repository, use full apk installation ──
    # OpenWrt 25.12 switched from opkg (.ipk) to apk (.apk, Alpine Package Keeper)
    step "[release] Registering local package repository..."

    # Directory where .apk files from build-full.sh are stored
    LOCAL_APK_DIR="$WORK_DIR/bin/packages/aarch64_cortex-a73/bpirouter"
    if [ ! -d "$LOCAL_APK_DIR" ]; then
        LOCAL_APK_DIR="$WORK_DIR/bin/targets/mediatek/filogic/packages"
    fi

    if [ ! -d "$LOCAL_APK_DIR" ] || [ -z "$(ls $LOCAL_APK_DIR/*.apk 2>/dev/null)" ]; then
        echo -e "${R}No .apk files found. Run build-full.sh first to compile packages.${N}"
        exit 1
    fi

    # Write local apk path to ImageBuilder's repositories.conf
    REPO_CONF="$IB_DIR/repositories.conf"
    [ ! -f "$REPO_CONF.orig" ] && cp "$REPO_CONF" "$REPO_CONF.orig"
    cp "$REPO_CONF.orig" "$REPO_CONF"
    sed -i "1i src bpirouter file://$LOCAL_APK_DIR" "$REPO_CONF"
    ok "Local repo registered: $LOCAL_APK_DIR"

    # Note: No need to manually generate index. OpenWrt build system in build-full.sh
    # already automatically generated APKINDEX.tar.gz (25.12 no longer uses ipkg-make-index.sh)

    step "[release] Building firmware with apk packages..."
    make image \
        PROFILE=bananapi_bpi-r4 \
        PACKAGES="$BASE_PACKAGES bpirouter-defaults bpirouter-ui"

else
    # ── Quick mode: FILES= raw injection (no apk) ──
    step "[quick] Preparing files overlay..."
    FILES_DIR="/tmp/bpirouter-ib-files"
    rm -rf "$FILES_DIR"
    mkdir -p "$FILES_DIR/usr/bin"
    mkdir -p "$FILES_DIR/www"
    mkdir -p "$FILES_DIR/usr/share/bpirouter/nginx"
    mkdir -p "$FILES_DIR/etc/init.d"
    mkdir -p "$FILES_DIR/etc/uci-defaults"
    mkdir -p "$FILES_DIR/etc"

    # Go binary
    cp /tmp/bpirouter-apid "$FILES_DIR/usr/bin/bpirouter-apid"
    chmod +x "$FILES_DIR/usr/bin/bpirouter-apid"

    # Vue frontend
    cp -r /tmp/bpirouter-www/* "$FILES_DIR/www/"

    # Deployment configs
    cp "$UI_DIR/deploy/nginx/"*.conf              "$FILES_DIR/usr/share/bpirouter/nginx/"
    cp "$UI_DIR/deploy/init.d/bpirouter-api"      "$FILES_DIR/etc/init.d/"
    chmod +x "$FILES_DIR/etc/init.d/bpirouter-api"
    cp "$UI_DIR/deploy/scripts/gen-cert.sh"        "$FILES_DIR/usr/bin/bpirouter-gen-cert"
    chmod +x "$FILES_DIR/usr/bin/bpirouter-gen-cert"
    cp "$UI_DIR/deploy/uci-defaults/99-bpirouter-setup" "$FILES_DIR/etc/uci-defaults/"
    chmod +x "$FILES_DIR/etc/uci-defaults/99-bpirouter-setup"

    # banner (if exists)
    [ -f "$FEEDS_DIR/net/bpirouter-defaults/files/etc/banner" ] && \
        cp "$FEEDS_DIR/net/bpirouter-defaults/files/etc/banner" "$FILES_DIR/etc/"

    # Default config script
    [ -f "$FEEDS_DIR/net/bpirouter-defaults/files/etc/uci-defaults/99-bpirouter-defaults" ] && \
        cp "$FEEDS_DIR/net/bpirouter-defaults/files/etc/uci-defaults/99-bpirouter-defaults" \
           "$FILES_DIR/etc/uci-defaults/" && \
        chmod +x "$FILES_DIR/etc/uci-defaults/99-bpirouter-defaults"

    ok "Files overlay: $(find $FILES_DIR -type f | wc -l) files"

    step "[quick] Building firmware with FILES overlay..."
    make image \
        PROFILE=bananapi_bpi-r4 \
        PACKAGES="$BASE_PACKAGES" \
        FILES="$FILES_DIR"

    rm -rf "$FILES_DIR"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. Output results
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
ok "Image build complete! (mode=$MODE)"
echo ""
echo "  Firmware location:"
ls -lh "$IB_DIR/bin/targets/mediatek/filogic/"*bpi-r4*sysupgrade* 2>/dev/null
ls -lh "$IB_DIR/bin/targets/mediatek/filogic/"*bpi-r4*sdcard* 2>/dev/null

mkdir -p "$BUILD_DIR/output"
cp "$IB_DIR/bin/targets/mediatek/filogic/"*bpi-r4* "$BUILD_DIR/output/" 2>/dev/null
echo ""
echo "  Copied to: $BUILD_DIR/output/"

# Clean up temporary files
rm -rf /tmp/bpirouter-apid /tmp/bpirouter-www
