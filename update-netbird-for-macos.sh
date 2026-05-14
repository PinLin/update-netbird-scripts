#!/usr/bin/env bash
set -euo pipefail

ARCH=$(uname -m)
case "$ARCH" in
  arm64)  PKG_ARCH="darwin_arm64" ;;
  x86_64) PKG_ARCH="darwin_amd64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

VERSION=$(curl -fsSL https://api.github.com/repos/netbirdio/netbird/releases/latest \
  | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')

if [[ -z "$VERSION" ]]; then
  echo "Failed to determine latest netbird version" >&2
  exit 1
fi

CURRENT=""
if command -v netbird >/dev/null 2>&1; then
  CURRENT=$(netbird version 2>/dev/null | head -n1 | awk '{print $NF}' | sed 's/^v//')
fi

echo "Latest:  $VERSION"
echo "Current: ${CURRENT:-not installed}"

if [[ "$CURRENT" == "$VERSION" ]]; then
  echo "Already up to date."
  exit 0
fi

PKG="netbird_${VERSION}_${PKG_ARCH}.pkg"
URL="https://github.com/netbirdio/netbird/releases/download/v${VERSION}/${PKG}"
DEST="/tmp/${PKG}"

echo "Downloading $URL"
curl -fL --progress-bar -o "$DEST" "$URL"

echo "Installing $PKG (sudo required)"
sudo installer -target / -pkg "$DEST"

rm -f "$DEST"
echo "Done. Installed netbird $VERSION."
