#!/bin/bash
set -e
cd "$(dirname "$0")/.."

APP_NAME="LiveCanvas"
APP="build/Release/${APP_NAME}.app"
DMG="build/${APP_NAME}-1.3.0.dmg"
STAGING="build/dmg_staging"
VOLUME_NAME="$APP_NAME"
BG_IMG="scripts/dmg_background@2x.png"

if [ ! -d "$APP" ]; then
  echo "App not built. Run ./build.sh first."
  exit 1
fi

if [ ! -f "$BG_IMG" ]; then
  echo "Generating DMG background..."
  python3 scripts/generate_dmg_bg.py
fi

echo "Creating DMG..."
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$BG_IMG" "$STAGING/.background/background.png"

# Step 1: Create read-write DMG
TEMP_DMG="build/${APP_NAME}_rw.dmg"
rm -f "$TEMP_DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW -size 200m "$TEMP_DMG"

# Step 2: Mount read-write DMG
hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG"
MOUNT="/Volumes/$VOLUME_NAME"
sleep 2

# Step 3: Write .DS_Store with correct background alias
python3 - "$MOUNT" "$APP_NAME" <<'PYEOF'
import sys, plistlib
from ds_store import DSStore
from mac_alias import Alias

mount = sys.argv[1]
app_name = sys.argv[2]
bg_path = f"{mount}/.background/background.png"

# Create a proper Finder alias to the background image
alias = Alias.for_file(bg_path)
alias_bytes = bytes(alias.to_bytes())

icvp = plistlib.dumps({
    "backgroundColorBlue": 1.0,
    "backgroundColorGreen": 1.0,
    "backgroundColorRed": 1.0,
    "backgroundImageAlias": alias_bytes,
    "backgroundType": 2,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "iconSize": 100.0,
    "labelOnBottom": True,
    "showIconPreview": True,
    "showItemInfo": False,
    "textSize": 12.0,
    "viewOptionsVersion": 1,
}, fmt=plistlib.FMT_BINARY)

bwsp = plistlib.dumps({
    "WindowBounds": "{{200, 120}, {660, 400}}",
    "SidebarWidth": 0,
    "ShowSidebar": False,
    "ShowToolbar": False,
    "ShowStatusBar": False,
    "ShowPathbar": False,
    "ShowTabView": False,
}, fmt=plistlib.FMT_BINARY)

ds_path = f"{mount}/.DS_Store"
with DSStore.open(ds_path, "w+") as d:
    d["."]["bwsp"] = bwsp
    d["."]["icvp"] = icvp
    d["."]["vSrn"] = ("long", 1)
    d[f"{app_name}.app"]["Iloc"] = (130, 190)
    d["Applications"]["Iloc"] = (530, 100)
    d[".background"]["Iloc"] = (900, 900)

print("DS_Store with background alias written")
PYEOF

# Step 4: Finalize
sync
hdiutil detach "$MOUNT"

# Step 5: Convert to compressed read-only
hdiutil convert "$TEMP_DMG" -format ULFO -o "$DMG"
rm -f "$TEMP_DMG"
rm -rf "$STAGING"

echo "DMG created at $DMG"
