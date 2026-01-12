#!/bin/bash
#
# CyberKit Injection Script v2
# Portable, generic script for injecting CyberKit into any iOS browser IPA
#
# Usage: ./inject-cyberkit.sh <target.ipa> <cyberkit-frameworks-dir> [output-name]
#
# Requirements:
#   - macOS with Xcode command line tools, or
#   - Linux with llvm-otool, llvm-install-name-tool, and ldid
#   - ldid (brew install ldid on macOS)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <target.ipa> <cyberkit-frameworks-dir> [output-name]"
    echo ""
    echo "Arguments:"
    echo "  target.ipa              Path to decrypted browser IPA"
    echo "  cyberkit-frameworks-dir Path to extracted CyberKit frameworks"
    echo "  output-name             (Optional) Output filename without extension"
    echo ""
    echo "Example:"
    echo "  $0 Brave-decrypted.ipa ./cyberkit_frameworks Brave-CyberKit"
    exit 1
fi

TARGET_IPA="$1"
CYBERKIT_DIR="$2"
OUTPUT_NAME="${3:-$(basename "$TARGET_IPA" .ipa)-CyberKit}"

# Validate inputs
[ ! -f "$TARGET_IPA" ] && error "Target IPA not found: $TARGET_IPA"
[ ! -d "$CYBERKIT_DIR" ] && error "CyberKit frameworks directory not found: $CYBERKIT_DIR"

# Check for required tools
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        error "$1 is required but not installed. $2"
    fi
}

check_tool "ldid" "Install with: brew install ldid"
check_tool "unzip" ""
check_tool "zip" ""

# Use llvm tools on Linux if available
if command -v llvm-otool &> /dev/null; then
    OTOOL="llvm-otool"
    INSTALL_NAME_TOOL="llvm-install-name-tool"
elif command -v llvm-otool-18 &> /dev/null; then
    OTOOL="llvm-otool-18"
    INSTALL_NAME_TOOL="llvm-install-name-tool-18"
else
    OTOOL="otool"
    INSTALL_NAME_TOOL="install_name_tool"
fi

check_tool "$OTOOL" "Install Xcode command line tools or LLVM"
check_tool "$INSTALL_NAME_TOOL" "Install Xcode command line tools or LLVM"

# Create working directory
WORK_DIR=$(mktemp -d)
log "Working directory: $WORK_DIR"

cleanup() {
    log "Cleaning up..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Extract target IPA
log "Extracting target IPA..."
unzip -q "$TARGET_IPA" -d "$WORK_DIR/target"

# Find the .app directory
TARGET_APP=$(find "$WORK_DIR/target/Payload" -name "*.app" -type d | head -1)
[ -z "$TARGET_APP" ] && error "No .app found in IPA"

APP_NAME=$(basename "$TARGET_APP" .app)
success "Found app: $APP_NAME"

# Find main executable
EXECUTABLE="$TARGET_APP/$APP_NAME"
if [ ! -f "$EXECUTABLE" ]; then
    EXECUTABLE=$(find "$TARGET_APP" -maxdepth 1 -type f -perm +111 2>/dev/null | head -1)
fi
[ ! -f "$EXECUTABLE" ] && error "Could not find main executable"
success "Found executable: $(basename $EXECUTABLE)"

# Patch load commands in main executable
log "Patching main executable load commands..."

patch_webkit_deps() {
    local bin="$1"
    local name="$2"
    local changed=0

    # WebKit -> CyberKit
    if $OTOOL -L "$bin" 2>/dev/null | grep -q "/System/Library/Frameworks/WebKit.framework"; then
        $INSTALL_NAME_TOOL -change \
            /System/Library/Frameworks/WebKit.framework/WebKit \
            @rpath/CyberKit.framework/CyberKit \
            "$bin"
        changed=1
    fi

    # JavaScriptCore -> CyberCore
    if $OTOOL -L "$bin" 2>/dev/null | grep -q "/System/Library/Frameworks/JavaScriptCore.framework"; then
        $INSTALL_NAME_TOOL -change \
            /System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore \
            @rpath/CyberCore.framework/CyberCore \
            "$bin"
        changed=1
    fi

    # WebKitLegacy -> CyberKitLegacy
    if $OTOOL -L "$bin" 2>/dev/null | grep -q "/System/Library/Frameworks/WebKitLegacy.framework"; then
        $INSTALL_NAME_TOOL -change \
            /System/Library/Frameworks/WebKitLegacy.framework/WebKitLegacy \
            @rpath/CyberKitLegacy.framework/CyberKitLegacy \
            "$bin"
        changed=1
    fi

    if [ $changed -eq 1 ]; then
        success "Patched: $name"
    fi
}

patch_webkit_deps "$EXECUTABLE" "$APP_NAME"

# Patch existing frameworks
if [ -d "$TARGET_APP/Frameworks" ]; then
    log "Patching existing frameworks..."
    for fw in "$TARGET_APP/Frameworks"/*.framework; do
        if [ -d "$fw" ]; then
            fwname=$(basename "$fw" .framework)
            fwbin="$fw/$fwname"
            if [ -f "$fwbin" ]; then
                patch_webkit_deps "$fwbin" "$fwname.framework"
            fi
        fi
    done
fi

# Copy CyberKit frameworks
log "Copying CyberKit frameworks..."
mkdir -p "$TARGET_APP/Frameworks"

for item in "$CYBERKIT_DIR"/*; do
    if [ -e "$item" ]; then
        itemname=$(basename "$item")
        # Skip MobileMiniBrowser.framework if present
        if [[ "$itemname" != *"MobileMiniBrowser"* ]]; then
            cp -R "$item" "$TARGET_APP/Frameworks/"
            success "Copied: $itemname"
        fi
    fi
done

# Remove existing code signatures (TrollStore will re-sign)
log "Removing existing signatures..."
find "$TARGET_APP" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true

# Create entitlements file
log "Creating entitlements..."
cat > "$WORK_DIR/entitlements.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>
    <key>get-task-allow</key>
    <true/>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>com.apple.private.security.no-container</key>
    <true/>
    <key>com.apple.private.skip-library-validation</key>
    <true/>
</dict>
</plist>
EOF

# Fakesign function
fakesign_binary() {
    local bin="$1"
    local name="$2"

    # Try to get existing entitlements
    existing_ents=$(ldid -e "$bin" 2>/dev/null || echo "")

    if [ -n "$existing_ents" ] && echo "$existing_ents" | grep -q "<dict>"; then
        # Merge entitlements
        static_ents=$(cat "$WORK_DIR/entitlements.plist")
        static_ents=${static_ents%</dict>*}
        existing_ents=${existing_ents#*<dict>}
        existing_ents=${existing_ents%</dict>*}
        echo "${static_ents}${existing_ents}</dict></plist>" > "$WORK_DIR/merged_ents.plist"
        ldid -S"$WORK_DIR/merged_ents.plist" "$bin" 2>/dev/null
        rm -f "$WORK_DIR/merged_ents.plist"
    else
        ldid -S"$WORK_DIR/entitlements.plist" "$bin" 2>/dev/null
    fi

    success "Signed: $name"
}

# Fakesign all binaries
log "Fakesigning binaries..."

# Sign main executable
fakesign_binary "$EXECUTABLE" "$APP_NAME"

# Sign frameworks
if [ -d "$TARGET_APP/Frameworks" ]; then
    for fw in "$TARGET_APP/Frameworks"/*.framework; do
        if [ -d "$fw" ]; then
            fwname=$(basename "$fw" .framework)
            fwbin="$fw/$fwname"
            if [ -f "$fwbin" ]; then
                fakesign_binary "$fwbin" "$fwname.framework"
            fi
        fi
    done

    # Sign dylibs
    for dylib in "$TARGET_APP/Frameworks"/*.dylib; do
        if [ -f "$dylib" ]; then
            fakesign_binary "$dylib" "$(basename $dylib)"
        fi
    done
fi

# Sign XPC services
for xpc_dir in "$TARGET_APP/Frameworks"/*.framework/XPCServices/*.xpc; do
    if [ -d "$xpc_dir" ]; then
        xpcname=$(basename "$xpc_dir" .xpc)
        if [ -f "$xpc_dir/$xpcname" ]; then
            fakesign_binary "$xpc_dir/$xpcname" "$xpcname.xpc"
        fi
    fi
done

# Package final IPA
log "Packaging final IPA..."
OUTPUT_DIR="$(cd "$(dirname "$TARGET_IPA")" && pwd)"
cd "$WORK_DIR/target"
find . -name ".DS_Store" -delete
zip -r -y "$OUTPUT_DIR/$OUTPUT_NAME.tipa" Payload
cd - > /dev/null

echo ""
success "==================================="
success "CyberKit injection complete!"
success "Output: $OUTPUT_DIR/$OUTPUT_NAME.tipa"
success "==================================="
echo ""
log "Install via TrollStore and enjoy!"
