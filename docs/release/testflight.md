# Internal TestFlight runbook

Status: internal TestFlight setup for Backlog `task-1.4.2`. Do not invite external testers or submit public/App Store builds from these lanes; `fastlane/ExportOptions.plist` sets `testFlightInternalTestingOnly`.

> **Icon gate:** land `task-1.4.1` first. App Store Connect rejects uploads that do not contain valid app icons for the uploaded platforms.

## Scope and identifiers

- App Store Connect app record: **Arkham** (id `6822282565`, SKU `arkham-horror`) exists, with iOS, macOS, tvOS, and visionOS platforms added. `APP_NAME` in `fastlane/Fastfile` matches this record.
- SKU: `arkham-horror`.
- Primary language: `en-CA`.
- Team: `9JALHNGRBQ`.
- Universal purchase bundle ID for every app target: `org.davidjensenius.ArkhamHorror`.
- macOS App Store category: `public.app-category.board-games`.
- Xcode schemes: `ArkhamHorror-iOS`, `ArkhamHorror-macOS`, `ArkhamHorror-tvOS`, and `ArkhamHorror-visionOS`.
- App test targets are not present in the Xcode project today; if they are added later, use sub-identifiers under `org.davidjensenius.ArkhamHorror`.

## One-time local setup

The owner already has the App Store Connect API key and the dedicated signing keychain on this machine. Reuse them; do not create new keys, keychains, or certificates for this task. The beta lanes verify the existing team-scoped signing identities before any `xbuild`; automatic signing with `-allowProvisioningUpdates` may create or update provisioning profiles for `org.davidjensenius.ArkhamHorror` on the first upload, and that is expected.

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

   This Arkham Horror lane only unlocks the existing dedicated keychain and checks that the reusable team identities are present; it does not create or fetch certificates. If the identities are missing, the owner should recover the dedicated keychain by following the canadian-ham keychain setup and `get_certificates` steps from that project's runbook, then return here and rerun `fastlane signing_certificates`.

## One-time App Store Connect setup

Run these only from an owner-controlled interactive shell. They touch the owner's Apple account or Developer Portal. Do not run them from automation or review agents.

1. Register the universal Developer Portal bundle ID. This lane is idempotent and uses the API key:

   ```sh
   fastlane ios register_bundle_ids
   ```

   Release/TestFlight builds require no Developer Portal capabilities beyond the default universal App ID. The macOS App Sandbox and network-client settings are signing entitlements in the app and do not require a portal capability toggle.

2. The App Store Connect app record already exists as **Arkham** (id `6822282565`, SKU `arkham-horror`) with iOS, macOS, tvOS, and visionOS platforms added. Keep this owner-run lane as recovery/documentation for creating the record in another account; it uses interactive Apple ID authentication and 2FA through `produce`:

   ```sh
   fastlane ios create_app_record
   ```

   The lane requests platforms `ios`, `osx`, and `tvos` for the same universal-purchase bundle ID. Fastlane `produce` does not accept the App Store Connect API names `appletvos` or `xros`; if recreating the record elsewhere, add visionOS manually in App Store Connect with **App Information → Add Platform** after the record exists.

3. Check App Store Connect state when needed:

   ```sh
   fastlane ios asc_status
   ```

## Internal beta lanes

Each beta lane archives and exports a **Release** build through `xbuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, automatic signing, team `9JALHNGRBQ`, `fastlane/ExportOptions.plist` (`method=app-store-connect`, `testFlightInternalTestingOnly=true`), and App Store Connect API-key signing arguments. Immediately after unlocking the build keychain and before any `xbuild`, the lanes verify the reusable team signing identities and fail if an identity is missing, so automatic signing does not create certificates. `-allowProvisioningUpdates` stays enabled so Xcode can create or update provisioning profiles for `org.davidjensenius.ArkhamHorror`. The lanes then upload the exported `.ipa` or `.pkg` with `upload_to_testflight(skip_waiting_for_build_processing: true)`.

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
fastlane ios beta artifact_path:"$PWD/fastlane/builds/ios/<build-number>/Arkham Horror.ipa"
fastlane mac beta artifact_path:"$PWD/fastlane/builds/mac/<build-number>/Arkham Horror.pkg"
```

## Versioning and build numbers

- `project.yml` sets `MARKETING_VERSION` and generated Info.plists read `CFBundleShortVersionString` from `$(MARKETING_VERSION)` and `CFBundleVersion` from `$(CURRENT_PROJECT_VERSION)`.
- The beta lanes override `CURRENT_PROJECT_VERSION` at archive time with a timestamp build number in `%Y%m%d%H%M` format.
- For a version change, update `MARKETING_VERSION` in `project.yml`, regenerate the Xcode project, and verify `mise run project-check` passes before archiving.

## App Store validity notes

- Bundle ID: all four app targets use the universal-purchase ID `org.davidjensenius.ArkhamHorror`. Because this changes the bundle ID, and because the macOS app now runs in the App Sandbox, existing local development installs should be expected to lose saved server profiles, tokens, and caches.
- macOS category: generated Info.plists set `LSApplicationCategoryType=public.app-category.board-games`.
- macOS entitlements: App Sandbox and `com.apple.security.network.client` are enabled because the app talks to the game server. No file-picker entitlements are currently needed; there is no `NSOpenPanel`, `NSSavePanel`, `fileImporter`, or document-picker usage in the app sources.
- First macOS TestFlight build: smoke-test sign-in and token persistence under the sandbox, because `kSecUseDataProtectionKeychain` needs the provisioning profile's `application-identifier` entitlement.
- iOS, tvOS, and visionOS entitlements: none are currently required.
- App Transport Security: no arbitrary-load ATS exception is configured. Custom `http://` server profiles are restricted in code to strict loopback hosts; remote servers must use HTTPS.
- Export compliance: generated Info.plists set `ITSAppUsesNonExemptEncryption=NO`; the app uses standard HTTPS/WebSocket transport and does not ship non-exempt encryption.
- Privacy manifest: `Sources/Resources/PrivacyInfo.xcprivacy` is embedded in every app target, declares no tracking, declares email address, user ID, and gameplay content as collected data linked to the user for app functionality, and lists required-reason access for app-owned UserDefaults (`CA92.1`) and file timestamp/stat-style cache metadata (`C617.1`). Keep the App Store Connect privacy questionnaire consistent with these declarations.
- Secure-cache metadata boundary (`task-1.4.3`): production assets remain under the `FileManager` user Caches URL (`ArkhamHorrorAssets/v1`). The secure directory walk opens the existing Caches trust anchor directly (or, only if it is missing with `ENOENT`, retries from the next containing OS-provided anchor to create Caches safely), checks its descriptor, and uses `openat`/`mkdirat` with `O_NOFOLLOW` below it, retaining owner, mode, and device checks. It never stats `/`, `/Users`, `/private/var`, or other ancestors above the anchor, nor reads their symlink metadata. Darwin's `/var` and `/private/var` spellings are compared lexically, without `lstat`/`readlink`. The anchor itself is not allowed to be a symlink; ancestors above it are trusted as supplied by the OS, not individually verified. Symlink, ownership, mode, stat, and other non-`ENOENT` failures never trigger fallback to a broader anchor. Replacing an already-open anchor path cannot redirect the descriptor-relative walk.
- Anchor selection uses strict component-wise containment, in order: `FileManager` Caches, home, then temporary directory; paths outside these locations are rejected. Home comes from `FileManager.homeDirectoryForCurrentUser` on macOS and Foundation's `NSHomeDirectory()` on iOS-family SDKs, where that FileManager property is unavailable. Home and temporary anchors support unsandboxed macOS development runs and test fixtures. On shipped sandboxed iOS, macOS, tvOS, and visionOS apps, these OS-provided locations are within the app container, keeping stat-style metadata access within `C617.1`'s container scope. No timestamp or other filesystem metadata is sent to the server.

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

### Missing signing identities

If `fastlane signing_certificates` reports missing reusable identities, do not create certificates from an agent session. The owner should follow the canadian-ham runbook's dedicated keychain setup and `get_certificates` recovery steps to restore the shared team certificates into `~/Library/Keychains/canadian-ham-build.keychain-db`, then rerun `fastlane signing_certificates` locally.

Do not switch off Release signing or put login-keychain credentials in scripts or agent sessions.

## Future App Store follow-ups

- Add native in-app account deletion before public App Store submission to satisfy App Store Review Guideline 5.1.1(v).
- Review trademark risk around the display name `Arkham` before public App Store submission; the current App Store Connect app record uses that name for internal TestFlight.
