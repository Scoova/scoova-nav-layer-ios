#!/usr/bin/env bash
#
# apply_tenant_config.sh
# Fetch the tenant's runtime config from the platform gateway and overlay it
# onto the iOS project before Fastlane builds:
#   • PRODUCT_BUNDLE_IDENTIFIER  (from tenant_apps.bundle_id)
#   • Info.plist:
#       SCOOVA_TENANT_SLUG
#       SCOOVA_NOSQL_API_KEY
#       SCOOVA_MONITOR_API_KEY
#       CFBundleDisplayName
#   • App icon (AppIcon.appiconset) — replaced wholesale from icons.zip
#   • Splash asset (LaunchScreen) — same idea
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
get() { python3 -c "import sys, json; d = json.loads(sys.argv[1]).get('data', {}); k = sys.argv[2].split('.'); v=d
for s in k: v = v.get(s) if isinstance(v, dict) else None
print('' if v is None else v)" "$CFG" "$1"; }

TENANT_NAME=$(get name)
APP_NAME=$(python3 -c "import json,sys
d=json.loads(sys.argv[1])['data']
for a in d['apps']:
  if a['platform']=='ios':
    print(a.get('appName') or d['name']); break
else: print(d['name'])
" "$CFG")
BUNDLE_ID=$(python3 -c "import json,sys
d=json.loads(sys.argv[1])['data']
for a in d['apps']:
  if a['platform']=='ios':
    print(a['bundleId']); break
" "$CFG")
echo "→ tenant=$TENANT_SLUG  app='$APP_NAME'  bundle=$BUNDLE_ID"

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

# 4. Optional: pull tenant icons + splash from the ops vault if creds present.
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

echo "✅ tenant config applied for $TENANT_SLUG"
