#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -E 'connectorVersion' Sources/ConnectorCore/ConnectorCore.swift | sed -E 's/.*"([^"]+)".*/\1/')
APP=dist/Connector.app
DMG="dist/Connector-$VERSION.dmg"
STAGE=$(mktemp -d)

[ -d "$APP" ] || { echo "Falta $APP: ejecuta scripts/build-app.sh primero." >&2; exit 1; }

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Connector" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "${CONNECTOR_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp -s "$CONNECTOR_SIGN_IDENTITY" "$DMG"
fi

if [ -n "${CONNECTOR_NOTARY_APPLE_ID:-}" ] && [ -n "${CONNECTOR_NOTARY_TEAM_ID:-}" ] && [ -n "${CONNECTOR_NOTARY_PASSWORD:-}" ]; then
    xcrun notarytool submit "$DMG" --apple-id "$CONNECTOR_NOTARY_APPLE_ID" --team-id "$CONNECTOR_NOTARY_TEAM_ID" --password "$CONNECTOR_NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"
fi

echo "Creado $DMG"
