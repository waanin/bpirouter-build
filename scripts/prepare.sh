#!/bin/bash
# prepare.sh — Prepare OpenWrt build environment
# Usage: ./scripts/prepare.sh
set -e

OPENWRT_VERSION="v25.12.2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"

C='\033[0;36m'
G='\033[0;32m'
R='\033[0;31m'
N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
fail() { echo -e "${R}✗ $1${N}"; exit 1; }

# ── 1. Clone OpenWrt Mainline ──
if [ -d "$WORK_DIR" ]; then
    step "OpenWrt directory exists, skipping clone"
else
    step "Cloning OpenWrt $OPENWRT_VERSION ..."
    # Use GitHub mirror for faster cloning
    git clone --branch "$OPENWRT_VERSION" --depth 1 \
        https://github.com/openwrt/openwrt.git "$WORK_DIR"
    ok "OpenWrt cloned"
fi

cd "$WORK_DIR"

# ── 2. Inject Kernel Patches (quilt method) ──
# OpenWrt automatically applies patches in the patches directory using quilt during make
# We only need to copy patch files to the correct locations

KERNEL_PATCH_DIR="$WORK_DIR/target/linux/mediatek/patches-6.12"
UBOOT_PATCH_DIR="$WORK_DIR/package/boot/uboot-mediatek/patches"

if ls "$BUILD_DIR/patches/kernel/"*.patch 1>/dev/null 2>&1; then
    step "Injecting kernel patches into quilt directory..."
    mkdir -p "$KERNEL_PATCH_DIR"
    # Use high-numbered prefixes to avoid conflicts with built-in OpenWrt patches
    for patch in "$BUILD_DIR/patches/kernel/"*.patch; do
        basename=$(basename "$patch")
        # If patch filename doesn't start with a number, prepend with 900-
        if [[ ! "$basename" =~ ^[0-9] ]]; then
            basename="900-bpirouter-${basename}"
        fi
        cp "$patch" "$KERNEL_PATCH_DIR/$basename"
        echo "  + $basename"
    done
    ok "Kernel patches injected"
else
    step "No kernel patches to apply"
fi

if ls "$BUILD_DIR/patches/uboot/"*.patch 1>/dev/null 2>&1; then
    step "Injecting U-Boot patches..."
    mkdir -p "$UBOOT_PATCH_DIR"
    for patch in "$BUILD_DIR/patches/uboot/"*.patch; do
        cp "$patch" "$UBOOT_PATCH_DIR/"
        echo "  + $(basename $patch)"
    done
    ok "U-Boot patches injected"
else
    step "No U-Boot patches to apply"
fi

# ── 3. Apply base-files patches (direct modification, as base-files has no quilt mechanism) ──
if ls "$BUILD_DIR/patches/base-files/"*.patch 1>/dev/null 2>&1; then
    step "Applying base-files patches..."
    for patch in "$BUILD_DIR/patches/base-files/"*.patch; do
        git apply --check "$patch" 2>/dev/null && \
            git apply "$patch" && \
            echo "  + $(basename $patch)" || \
            echo "  SKIP (already applied or conflict): $(basename $patch)"
    done
    ok "Base-files patches applied"
fi

# ── 4. Setup feeds ──
step "Configuring feeds..."
cp "$BUILD_DIR/feeds.conf" "$WORK_DIR/feeds.conf"
./scripts/feeds update -a
./scripts/feeds install -a
ok "Feeds installed"

# ── 5. Apply .config ──
step "Applying build config..."
if [ -f "$BUILD_DIR/config/bpi-r4.config" ]; then
    cp "$BUILD_DIR/config/bpi-r4.config" "$WORK_DIR/.config"
    make defconfig
    ok "Config applied"
else
    echo "  No .config found. Run 'make menuconfig' manually in $WORK_DIR"
fi

echo ""
ok "OpenWrt build environment ready!"
echo "  Next steps:"
echo "    cd $WORK_DIR"
echo "    make menuconfig    # (optional) fine-tune configuration"
echo "    make download -j\$(nproc)"
echo "    make -j\$(nproc)"
