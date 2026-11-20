#!/bin/zsh
# Construit « mFONTS.app » (ou « mFONTS dev.app » avec DEV=1 : autre identifiant fr.stephan.mfonts.dev, autres données),
# la signe (certificat local stable) puis (version normale seulement) l'installe dans ~/Applications/Applications Personnelles.
# DEV=1 n'installe jamais. NO_INSTALL=1 : ne pas installer ; NO_OPEN=1 : ne pas lancer.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Applications/Applications Personnelles"
if [ -n "${DEV:-}" ]; then NAME="mFONTS dev"; BID="fr.stephan.mfonts.dev"; else NAME="mFONTS"; BID="fr.stephan.mfonts"; fi
APP="$NAME.app"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$APP/Contents/MacOS/mFONTS" Sources/*.swift
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/plugins "$APP/Contents/Resources/plugins"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" -c "Set :CFBundleName $NAME" -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist"
for l in fr en es it; do mkdir -p "$APP/Contents/Resources/$l.lproj"; cp "Resources/$l.lproj/InfoPlist.strings" "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"; done
SIGN="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
if [ -x "$SIGN" ]; then "$SIGN" "$APP"; else codesign --force --deep -s - "$APP"; fi
# Jamais d'édition de dev dans Applications Personnelles : elle reste dans le dossier du projet.
if [ -n "${DEV:-}" ]; then NO_INSTALL=1; fi
if [ -z "${NO_INSTALL:-}" ]; then
  mkdir -p "$DEST"
  pkill -f "$NAME.app/Contents/MacOS/mFONTS" 2>/dev/null || true
  rm -rf "$DEST/$APP"; cp -R "$APP" "$DEST/$APP"
  echo "Installée : $DEST/$APP"
fi
echo "OK : $APP"
