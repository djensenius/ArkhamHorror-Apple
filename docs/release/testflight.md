# Internal TestFlight runbook

Status: internal TestFlight setup for Backlog `task-1.4.2`. Do not invite external testers or submit public/App Store builds from these lanes; `fastlane/ExportOptions.plist` sets `testFlightInternalTestingOnly`.

> **Icon gate:** land `task-1.4.1` first. App Store Connect rejects uploads that do not contain valid app icons for the uploaded platforms.

## Scope and identifiers

- App Store Connect app-name placeholder: **Arkham Horror Companion** (`APP_NAME` in `fastlane/Fastfile`). The owner should choose and confirm the final store name before running `fastlane ios create_app_record`; plain "Arkham Horror" is likely unavailable and is a Fantasy Flight trademark.
- SKU: `arkham-horror`.
- Primary language: `en-CA`.
- Team: `9JALHNGRBQ`.
- Universal purchase bundle ID for every app target: `org.davidjensenius.ArkhamHorror`.
- Xcode schemes: `ArkhamHorror-iOS`, `ArkhamHorror-macOS`, `ArkhamHorror-tvOS`, and `ArkhamHorror-visionOS`.
- App test targets are not present in the Xcode project today; if they are added later, use sub-identifiers under `org.davidjensenius.ArkhamHorror`.

## One-time local setup

The owner already has the App Store Connect API key and the dedicated signing keychain on this machine. Reuse them; do not create new keys, keychains, certificates, or provisioning assets for this task.

1. Install fastlane if it is not already available:

   ```sh
   brew install fastlane
   ```

2. Confirm `xbuild` is on `PATH`. The lanes call `xbuild` directly for archive/export and never call `xcodebuild` directly:

   ```sh
   which xbuild
   ```

3. Keep the App Store Connect API key at the path expected by `fastlane/Fastfile`:

   ```text
   ~/.appstoreconnect/AuthKey_XP65R4N5A2.p8
   ```

   Never commit, print, paste, or otherwise record the key contents. The Fastfile references only key ID `XP65R4N5A2`, issuer ID `69a6de7e-a5f5-47e3-e053-5b8c7c11a4d1`, and the local key path.

4. Confirm the shared dedicated signing keychain and password file exist:

   ```text
   ~/Library/Keychains/canadian-ham-build.keychain-db
   ~/.appstoreconnect/build-keychain.pw
   ```

   `fastlane/Fastfile` exposes configurable defaults for another build host:

   ```sh
   export ARKHAM_BUILD_KEYCHAIN_PATH="$HOME/Library/Keychains/canadian-ham-build.keychain-db"
   export ARKHAM_BUILD_KEYCHAIN_PASSWORD_FILE="$HOME/.appstoreconnect/build-keychain.pw"
   ```

   The password file contains the random password for this build keychain only. Keep it mode 600. Never print or commit the password, private keys, or certificates.

5. Optional owner-run local verification of the reused signing identities:

   ```sh
   fastlane signing_certificates
   ```

   This Arkham Horror lane only unlocks the existing dedicated keychain and checks that the reusable team identities are present; it does not create or fetch certificates.

## One-time App Store Connect setup

Run these only from an owner-controlled interactive shell. They touch the owner's Apple account or Developer Portal. Do not run them from automation or review agents.

1. Register the universal Developer Portal bundle ID. This lane is idempotent and uses the API key:

   ```sh
   fastlane ios register_bundle_ids
   ```

   Release/TestFlight builds require no Developer Portal capabilities beyond the default universal App ID. The macOS App Sandbox and network-client settings are signing entitlements in the app and do not require a portal capability toggle.

2. Create the App Store Connect app record. This uses interactive Apple ID authentication and 2FA through `produce`; confirm the app name before running it:

   ```sh
   fastlane ios create_app_record
   ```

   The lane requests platforms `ios`, `osx`, and `tvos` for the same universal-purchase bundle ID. Fastlane `produce` does not accept the App Store Connect API names `appletvos` or `xros`; after the record exists, add visionOS manually in App Store Connect with **App Information → Add Platform**.

3. Check App Store Connect state when needed:

   ```sh
   fastlane ios asc_status
   ```

## Internal beta lanes

Each beta lane archives and exports a **Release** build through `xbuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, automatic signing, team `9JALHNGRBQ`, `fastlane/ExportOptions.plist` (`method=app-store-connect`, `testFlightInternalTestingOnly=true`), and App Store Connect API-key signing arguments. The lanes then upload the exported `.ipa` or `.pkg` with `upload_to_testflight(skip_waiting_for_build_processing: true)`.

Run only after review/merge approval and only for internal TestFlight:

```sh
fastlane ios beta       # ArkhamHorror-iOS, generic/platform=iOS, exports .ipa
fastlane mac beta       # ArkhamHorror-macOS, generic/platform=macOS, exports .pkg
fastlane appletvos beta # ArkhamHorror-tvOS, generic/platform=tvOS, exports .ipa
fastlane xros beta      # ArkhamHorror-visionOS, generic/platform=visionOS, exports .ipa
```

Do not call `gym`, `build_app`, or `xcodebuild` directly for these uploads. The Fastfile uses only `xbuild` for archive/export.

### Re-upload an existing export

If archive and export succeeded but the upload step failed, upload the exported artifact without rebuilding:

```sh
fastlane ios beta artifact_path:$PWD/fastlane/builds/ios/<build-number>/<exported-app>.ipa
fastlane mac beta artifact_path:$PWD/fastlane/builds/mac/<build-number>/<exported-app>.pkg
```

## Versioning and build numbers

- `project.yml` sets `MARKETING_VERSION` and generated Info.plists read `CFBundleShortVersionString` from `$(MARKETING_VERSION)` and `CFBundleVersion` from `$(CURRENT_PROJECT_VERSION)`.
- The beta lanes override `CURRENT_PROJECT_VERSION` at archive time with a timestamp build number in `%Y%m%d%H%M` format.
- For a version change, update `MARKETING_VERSION` in `project.yml`, regenerate the Xcode project, and verify `mise run project-check` passes before archiving.

## App Store validity notes

- Bundle ID: all four app targets use the universal-purchase ID `org.davidjensenius.ArkhamHorror`.
- macOS entitlements: App Sandbox and `com.apple.security.network.client` are enabled because the app talks to the game server. No file-picker entitlements are currently needed; there is no `NSOpenPanel`, `NSSavePanel`, `fileImporter`, or document-picker usage in the app sources.
- iOS, tvOS, and visionOS entitlements: none are currently required.
- App Transport Security: no arbitrary-load ATS exception is configured. Custom `http://` server profiles are restricted in code to strict loopback hosts; remote servers must use HTTPS.
- Export compliance: generated Info.plists set `ITSAppUsesNonExemptEncryption=NO`; the app uses standard HTTPS/WebSocket transport and does not ship non-exempt encryption.
- Privacy manifest: `Sources/Resources/PrivacyInfo.xcprivacy` is embedded in every app target, declares no tracking and no collected data, and lists required-reason access for app-owned UserDefaults and file timestamp/stat-style cache metadata.

## Troubleshooting

### `errSecInternalComponent` during CodeSign

`errSecInternalComponent` at `CodeSign` means the signing process found an identity but cannot use its private key. The lanes sign with the dedicated build keychain, so check that keychain rather than the login keychain:

1. Confirm the keychain and password file exist and that the keychain is in the user search list:

   ```sh
   ls -l ~/Library/Keychains/canadian-ham-build.keychain-db ~/.appstoreconnect/build-keychain.pw
   security list-keychains -d user
   ```

2. Confirm it holds the existing team identities:

   ```sh
   security find-identity -v ~/Library/Keychains/canadian-ham-build.keychain-db
   ```

3. If private-key access was lost, reapply the key partition list, then rerun the lane:

   ```sh
   KC=~/Library/Keychains/canadian-ham-build.keychain-db
   security set-key-partition-list -S apple-tool:,apple:,codesign:,productbuild: -s -k "$(cat ~/.appstoreconnect/build-keychain.pw)" "$KC"
   ```

Do not switch off Release signing or put login-keychain credentials in scripts or agent sessions.
