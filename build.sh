#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 [android|desktop|both]"
    echo
    echo "  android   Build the Android runtime host APK and push via ADB"
    echo "  desktop   Build the Desktop bridge JAR and copy to ~/Documents/AnymeX/Tools"
    echo "  both      Build android and desktop"
    echo
    echo "If no argument is given you will be prompted to choose."
}

build_android() {
    echo
    echo "======================================="
    echo " Building Android Runtime Host"
    echo "======================================="
    bash "$SCRIPT_DIR/RuntimeBridges/Android/build.sh"
}

build_desktop() {
    echo
    echo "======================================="
    echo " Building Desktop Bridge"
    echo "======================================="
    bash "$SCRIPT_DIR/build_desktop.sh"
}

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    echo "======================================="
    echo "  AnymeX Extension Runtime Builder"
    echo "======================================="
    echo
    echo "  1) Android  — build APK + ADB push"
    echo "  2) Desktop  — build JAR + copy"
    echo "  3) Both"
    echo
    read -rp "Choose [1/2/3]: " CHOICE
    case "$CHOICE" in
        1) TARGET="android" ;;
        2) TARGET="desktop" ;;
        3) TARGET="both"    ;;
        *) echo "❌ Invalid choice: '$CHOICE'"; usage; exit 1 ;;
    esac
fi

case "$TARGET" in
    android)
        build_android
        ;;
    desktop)
        build_desktop
        ;;
    both)
        build_android
        build_desktop
        ;;
    --help|-h|help)
        usage
        exit 0
        ;;
    *)
        echo "❌ Unknown target: '$TARGET'"
        usage
        exit 1
        ;;
esac

echo
echo "✅ All done!"
