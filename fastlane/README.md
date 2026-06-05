# Scoova white-label iOS build pipeline

One iOS codebase, N tenants, N App Store presences.

## What this pipeline does

For each operator (tenant) we ship a build that:
1. Is **owned by their Apple Developer account** (their team ID, their App
   Store Connect API key) — Apple flags multi-tenant clones under a single
   account as spam, so each tenant must bring their own.
2. Is **rebranded** before compile — `apply_tenant_config.sh` fetches the
   tenant's brand + endpoints + assets from the platform and overlays them
   onto the project (PRODUCT_BUNDLE_IDENTIFIER, Info.plist, asset catalog).
3. Is **uploaded to TestFlight** (and later submitted for review) on a build
   server runner. Status updates flow back to ops-api so the operator sees
   build state on `ops.scoo-va.info`.

## Run locally

```sh
brew install fastlane
cd scoova-nav-layer-ios

# Required env — fill from the operator's encrypted vault entry
export TENANT_SLUG="scoova"
export APP_IDENTIFIER="info.scoo-va.ride"
export APPLE_TEAM_ID="…"
export APPLE_KEY_ID="…"
export APPLE_ISSUER_ID="…"
export APPLE_KEY_CONTENT="$(base64 -i AuthKey_XXX.p8)"

# (Optional, for status callbacks + asset pull)
export OPS_API_TOKEN="…"

fastlane build              # archive-only, sanity check
fastlane testflight_upload  # full TestFlight upload under tenant's account
fastlane submit_for_review  # promote latest to App Store review
```

## Operator-side flow

1. Operator signs into `ops.scoo-va.info`.
2. Pastes their Apple Developer + Google Play credentials (encrypted at rest).
3. Uploads their icon / splash / logo.
4. Clicks "Build new version" → ops-api enqueues a job → this Fastfile runs
   on the Phoenix build host → status updates flow back through
   `notify_pipeline`.

## Files

- `Appfile`              — reads identity from env (no secrets in source)
- `Fastfile`             — `build`, `testflight_upload`, `submit_for_review`
- `scripts/apply_tenant_config.sh` — overlay step run before every build
