#!/bin/bash
# build-full.sh — Full firmware build for BpiRouter
# Usage: ./scripts/build-full.sh [jobs]
# Use when: kernel/U-Boot/feeds have changes
# Time: 1-2 hours for first build, 10-30 minutes for incremental builds
set -e

JOBS="${1:-$(nproc)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"
UI_DIR="$BUILD_DIR/../bpirouter-ui"
FEEDS_DIR="$BUILD_DIR/../bpirouter-feeds"

C='\033[0;36m'
G='\033[0;32m'
N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }

# ── 0. Prepare environment (if not already prepared) ──
if [ ! -d "$WORK_DIR" ]; then
    step "Running prepare.sh first..."
    "$SCRIPT_DIR/prepare.sh"
fi

# ── 1. Build BpiRouter application layer ──
step "Building Go API (aarch64)..."
cd "$UI_DIR/backend"
[ ! -f go.sum ] && go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -ldflags="-s -w" \
    -o "$FEEDS_DIR/net/bpirouter-ui/files/bpirouter-apid" \
    ./cmd/apid/
ok "Go binary: $(ls -lh $FEEDS_DIR/net/bpirouter-ui/files/bpirouter-apid | awk '{print $5}')"

step "Building Vue + Naive UI frontend..."
cd "$UI_DIR/frontend"
[ -d node_modules ] || npm ci --silent
npx vite build --outDir "$FEEDS_DIR/net/bpirouter-ui/files/www/"
ok "Frontend built"

# Copy deployment configs to feeds (don't silence errors, fail immediately if files missing)
step "Copying deploy configs to feeds..."
FEED_FILES="$FEEDS_DIR/net/bpirouter-ui/files"
mkdir -p "$FEED_FILES"

cp "$UI_DIR/deploy/nginx/"*.conf                        "$FEED_FILES/"
cp "$UI_DIR/deploy/init.d/bpirouter-api"                "$FEED_FILES/"
cp "$UI_DIR/deploy/scripts/gen-cert.sh"                 "$FEED_FILES/bpirouter-gen-cert"
cp "$UI_DIR/deploy/uci-defaults/99-bpirouter-setup"     "$FEED_FILES/"
chmod +x "$FEED_FILES/bpirouter-api" "$FEED_FILES/bpirouter-gen-cert" "$FEED_FILES/99-bpirouter-setup"
ok "Deploy configs: $(ls $FEED_FILES/ | tr '\n' ' ')"

# ── 2. Update feeds (pull latest local feed changes) ──
step "Updating feeds..."
cd "$WORK_DIR"
./scripts/feeds update bpirouter
./scripts/feeds install -a -f

# ── 3. Download all source packages ──
step "Downloading source packages..."
make download -j$JOBS

# ── 4. Full compilation ──
step "Building firmware (jobs=$JOBS)..."
make -j$JOBS

# ── 5. Output results ──
echo ""
ok "Build complete!"
echo ""
echo "  Firmware location:"
ls -lh "$WORK_DIR/bin/targets/mediatek/filogic/"*bpi-r4*sysupgrade* 2>/dev/null
ls -lh "$WORK_DIR/bin/targets/mediatek/filogic/"*bpi-r4*sdcard* 2>/dev/null
echo ""
echo "  ImageBuilder (for quick packaging):"
ls -lh "$WORK_DIR/bin/targets/mediatek/filogic/"*imagebuilder* 2>/dev/null
echo ""
echo "  SDK (for building individual packages):"
ls -lh "$WORK_DIR/bin/targets/mediatek/filogic/"*sdk* 2>/dev/null
