#!/usr/bin/env bash
#
# apply_tenant_config.sh
# Fetch the tenant's runtime config from the platform gateway and overlay it
# onto the iOS project before Fastlane builds:
#   • PRODUCT_BUNDLE_IDENTIFIER  (from $BUNDLE_ID env, falls back to default)
#   • Info.plist:
#       SCOOVA_TENANT_SLUG
#       SCOOVA_NOSQL_API_KEY
#       SCOOVA_MONITOR_API_KEY
#       CFBundleDisplayName
#   • Assets.xcassets:
#       AccentColor.colorset   ← branding.accentColor
#       BrandColor.colorset    ← branding.primaryColor
#       ScoovaLogo.imageset    ← branding.logoUrl (downloaded; @1x only)
#       AppIcon.appiconset     ← branding.iconUrl (downloaded → 1024×1024)
#   • Resources/tenant_config.json — full /tenant/{slug}/config snapshot
#                                    so a first-launch-offline boot is
#                                    fully tenant-branded (no Scoova
#                                    fallback flash before network arrives)
#   • Splash asset (LaunchScreen) — pulled from ops vault when present
#
# Inputs (env vars set by the build runner):
#   TENANT_SLUG              required; e.g. "scoova"
#   PLATFORM_API_KEY         optional; needed only for non-public collections
#   OPS_API_TOKEN            optional; if set, we also pull store assets from
#                            the operator's encrypted vault on the server
#
# The script is idempotent — re-running it produces the same result given
# the same upstream config.

set -euo pipefail

TENANT_SLUG="${1:-${TENANT_SLUG:-}}"
if [[ -z "$TENANT_SLUG" ]]; then
  echo "usage: apply_tenant_config.sh <tenant-slug>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
APP_DIR="$ROOT/app/ScoovaRide"
PBXPROJ="$ROOT/app/ScoovaRide.xcodeproj/project.pbxproj"
INFO_PLIST="$APP_DIR/Info.plist"

# 1. Pull the public tenant config from the platform.
GATEWAY="${PLATFORM_API_URL:-https://cloud.scoo-va.info}"
CFG=$(curl -sf "$GATEWAY/api/v1/tenant/$TENANT_SLUG/config")
if [[ -z "$CFG" ]]; then
  echo "❌ tenant '$TENANT_SLUG' not found at $GATEWAY" >&2
  exit 1
fi

# All shell-side parsing goes through python so we avoid pulling jq.
# Wire format: {"success":true,"data":{"configJson":{...}}}
get() { python3 -c "import sys, json
d = json.loads(sys.argv[1]).get('data', {}).get('configJson', {})
k = sys.argv[2].split('.')
v = d
for s in k:
    if isinstance(v, dict): v = v.get(s)
    else: v = None
print('' if v is None else v)" "$CFG" "$1"; }

APP_NAME=$(get strings.appName)
[[ -z "$APP_NAME" ]] && APP_NAME="Scoova"
# Bundle ID is NOT in the public config response (we keep that to
# safe-to-publish fields only). Build runners pass it via $BUNDLE_ID;
# otherwise we keep whatever the project file already has.
BUNDLE_ID="${BUNDLE_ID:-}"
BRAND_PRIMARY=$(get branding.primaryColor)
BRAND_ACCENT=$(get branding.accentColor)
LOGO_URL=$(get branding.logoUrl)
ICON_URL=$(get branding.iconUrl)
echo "→ tenant=$TENANT_SLUG  app='$APP_NAME'  primary=$BRAND_PRIMARY  accent=$BRAND_ACCENT"

# 2. Overlay Bundle ID into the Xcode project (sed in place — boring but
#    works without xcodeproj-gem).
if [[ -n "$BUNDLE_ID" ]]; then
  sed -i.bak -E "s/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;/g" "$PBXPROJ"
  rm -f "$PBXPROJ.bak"
fi
export APP_IDENTIFIER="${BUNDLE_ID:-com.scoova.ride}"

# 3. Overlay Info.plist keys (PlistBuddy ships with macOS / build hosts).
PB="/usr/libexec/PlistBuddy"
plist_set() {
  $PB -c "Set :$1 $2" "$INFO_PLIST" 2>/dev/null \
    || $PB -c "Add :$1 string $2"   "$INFO_PLIST"
}

plist_set "SCOOVA_TENANT_SLUG"      "$TENANT_SLUG"
plist_set "CFBundleDisplayName"     "$APP_NAME"
[[ -n "${SCOOVA_NOSQL_API_KEY:-}"   ]] && plist_set "SCOOVA_NOSQL_API_KEY"   "$SCOOVA_NOSQL_API_KEY"
[[ -n "${SCOOVA_MONITOR_API_KEY:-}" ]] && plist_set "SCOOVA_MONITOR_API_KEY" "$SCOOVA_MONITOR_API_KEY"

# 4. Overlay brand colors into the asset catalog. Idempotent — each run
#    overwrites the Contents.json from scratch. The colorset is created
#    if it doesn't exist; SwiftUI's `Color("BrandColor")` and the system
#    AccentColor both pick this up at build time, no source change.
ASSETS_DIR="$APP_DIR/Assets.xcassets"
write_colorset() {
  local name="$1"
  local hex="$2"
  [[ -z "$hex" ]] && return 0
  local dir="$ASSETS_DIR/$name.colorset"
  # #RRGGBB → r,g,b components as 0.xxx floats (Xcode wire format).
  local r
  local g
  local b
  r=$(printf '%d' 0x${hex:1:2})
  g=$(printf '%d' 0x${hex:3:2})
  b=$(printf '%d' 0x${hex:5:2})
  local rf
  local gf
  local bf
  rf=$(python3 -c "print(f'{$r/255:.3f}')")
  gf=$(python3 -c "print(f'{$g/255:.3f}')")
  bf=$(python3 -c "print(f'{$b/255:.3f}')")
  mkdir -p "$dir"
  cat > "$dir/Contents.json" <<JSON
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "$bf",
          "green" : "$gf",
          "red" : "$rf"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
}
write_colorset "AccentColor" "$BRAND_ACCENT"
write_colorset "BrandColor"  "$BRAND_PRIMARY"
[[ -n "$BRAND_PRIMARY" || -n "$BRAND_ACCENT" ]] && echo "→ applied brand colors"

# 5. Overlay tenant logo into ScoovaLogo.imageset. We only ship @1x —
#    Xcode picks it for every scale and downsizes; tenants rarely have
#    proper 3x retina assets so we degrade gracefully. Skipped silently
#    if logoUrl is null (tenant hasn't uploaded one yet).
if [[ -n "$LOGO_URL" ]]; then
  LOGO_SET="$ASSETS_DIR/ScoovaLogo.imageset"
  mkdir -p "$LOGO_SET"
  TMP_LOGO=$(mktemp -t scoova-logo).png
  if curl -sfL "$LOGO_URL" -o "$TMP_LOGO" && [[ -s "$TMP_LOGO" ]]; then
    rm -f "$LOGO_SET"/scoova-logo*.png
    cp "$TMP_LOGO" "$LOGO_SET/scoova-logo.png"
    cat > "$LOGO_SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "scoova-logo.png", "idiom" : "universal", "scale" : "1x" },
    { "idiom" : "universal", "scale" : "2x" },
    { "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
    echo "→ applied tenant logo ($LOGO_URL)"
  else
    echo "→ logoUrl set but download failed; keeping default logo"
  fi
  rm -f "$TMP_LOGO"
fi

# 6. App icon — overwrite AppIcon.appiconset/AppIcon-1024.png with the
#    operator's master image. This app uses iOS 17's single-image
#    "universal" AppIcon, so we don't need to generate the size grid;
#    Xcode resamples at archive time. Source PNG should be 1024×1024
#    sRGB with no transparency — anything smaller still works (Xcode
#    will warn) but App Store Connect rejects the build, so the script
#    nudges with sips when the source is smaller.
if [[ -n "$ICON_URL" ]]; then
  ICON_SET="$APP_DIR/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$ICON_SET"
  TMP_ICON=$(mktemp -t scoova-icon).png
  if curl -sfL "$ICON_URL" -o "$TMP_ICON" && [[ -s "$TMP_ICON" ]]; then
    # Force a square 1024×1024 PNG. `sips -z` resizes; `--out` writes
    # alongside. If the source is already 1024 square we still get a
    # cheap re-encode but the output is deterministic.
    if command -v sips >/dev/null 2>&1; then
      sips -s format png -z 1024 1024 "$TMP_ICON" --out "$ICON_SET/AppIcon-1024.png" >/dev/null
    else
      cp "$TMP_ICON" "$ICON_SET/AppIcon-1024.png"
    fi
    cat > "$ICON_SET/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
    echo "→ applied app icon ($ICON_URL)"
  else
    echo "→ iconUrl set but download failed; keeping default app icon"
  fi
  rm -f "$TMP_ICON"
fi

# 7. Optional: pull tenant icons + splash from the ops vault if creds present.
#    The endpoint returns a zip we can unpack straight over the asset catalog.
if [[ -n "${OPS_API_TOKEN:-}" ]]; then
  ASSETS_URL="${GATEWAY%/}/ops-api/v1/ops/internal/tenant-assets-zip"
  TMP_ZIP=$(mktemp)
  if curl -sfL -H "Authorization: Bearer $OPS_API_TOKEN" -H "X-Tenant-Slug: $TENANT_SLUG" \
       "$ASSETS_URL" -o "$TMP_ZIP" && [[ -s "$TMP_ZIP" ]]; then
    unzip -oq "$TMP_ZIP" -d "$APP_DIR/Assets.xcassets/"
    echo "→ applied store assets (icons + splash) from ops vault"
  else
    echo "→ no store assets available for $TENANT_SLUG (continuing with defaults)"
  fi
  rm -f "$TMP_ZIP"
fi

# 8. Bundled tenant_config.json — the same envelope that the runtime
#    fetch consumes, baked into the IPA. ScoovaTenantConfig prefers the
#    server response, falls back to UserDefaults cache, then to this
#    file, then to the hardcoded Scoova default. So a first-ever launch
#    in airplane mode on a fresh install still boots with the operator's
#    colours + copy.
RES_DIR="$APP_DIR/Resources"
mkdir -p "$RES_DIR"
echo "$CFG" > "$RES_DIR/tenant_config.json"
echo "→ bundled $(wc -c < "$RES_DIR/tenant_config.json") bytes of tenant_config.json for offline first-launch"

echo "✅ tenant config applied for $TENANT_SLUG"
