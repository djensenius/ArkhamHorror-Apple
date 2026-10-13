# fastlane lanes

Arkham Horror's internal TestFlight lanes mirror the owner's canadian-ham setup: App Store Connect API key authentication, the shared dedicated build keychain, and `xbuild` only for archive/export.

The App Store Connect app record exists as **Arkham** (id `6822282565`, SKU `arkham-horror`) with iOS, macOS, tvOS, and visionOS platforms added.

Do not run account-mutating lanes from automation. The owner runs the one-time App Store Connect setup described in [`docs/release/testflight.md`](../docs/release/testflight.md).

## Shared lane

### `fastlane signing_certificates`

Verifies the existing dedicated build keychain and reusable team signing identities without creating certificates. This is the same team-scoped identity check that beta lanes run immediately after unlocking the keychain and before any `xbuild`; it never prints keychain passwords, private keys, or certificates.

## iOS

### `fastlane ios register_bundle_ids`

Registers the universal Developer Portal bundle ID `org.davidjensenius.ArkhamHorror` using the App Store Connect API key. Idempotent.

### `fastlane ios create_app_record`

The App Store Connect app record already exists as **Arkham** (id `6822282565`, SKU `arkham-horror`) with iOS, macOS, tvOS, and visionOS platforms added. This owner-run recovery lane creates the record for iOS, macOS, and tvOS through interactive Apple ID + 2FA with `produce`; add visionOS manually in App Store Connect after the record exists if recreating it elsewhere.

### `fastlane ios asc_status`

Prints the App Store Connect app record and version states.

### `fastlane ios beta`

Archives and exports `ArkhamHorror-iOS` Release with `xbuild`, then uploads the exported `.ipa` to internal TestFlight.

## macOS

### `fastlane mac beta`

Archives and exports `ArkhamHorror-macOS` Release with `xbuild`, then uploads the exported `.pkg` to internal TestFlight.

## tvOS

### `fastlane appletvos beta`

Archives and exports `ArkhamHorror-tvOS` Release with `xbuild`, then uploads the exported `.ipa` to internal TestFlight.

## visionOS

### `fastlane xros beta`

Archives and exports `ArkhamHorror-visionOS` Release with `xbuild`, then uploads the exported `.ipa` to internal TestFlight.
