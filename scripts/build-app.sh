#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -E 'connectorVersion' Sources/ConnectorCore/ConnectorCore.swift | sed -E 's/.*"([^"]+)".*/\1/')
APP=dist/Connector.app

swift build -c release --arch arm64 --product Connector
BIN=$(swift build -c release --arch arm64 --product Connector --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj"
cp "$BIN/Connector" "$APP/Contents/MacOS/Connector"
sed "s/@VERSION@/$VERSION/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp Packaging/Connector.icns "$APP/Contents/Resources/Connector.icns"
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "${CONNECTOR_SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp -s "$CONNECTOR_SIGN_IDENTITY" "$APP"
else
    codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Creado $APP ($VERSION)"
