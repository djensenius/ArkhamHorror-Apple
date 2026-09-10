# ArkhamHorror-Apple

ArkhamHorror-Apple is the native SwiftUI client foundation for a semantic digital
card game on iOS, iPadOS, macOS, tvOS, and visionOS. Phase 0 is intentionally a
walking skeleton: it proves the shared UI, platform entry points, focus-driven
input, project generation, tests, and CI without pretending that game features
exist.

Official card art, playmat art, and other Arkham Horror assets are not included.

## Architecture

XcodeGen creates four thin application targets. Each target has its own entry
point under `Sources/Platforms` and depends on the local `ArkhamHorrorShared`
Swift package under `Packages/ArkhamHorrorShared`:

- `App`: observable application state and command dispatch
- `Domain`: pure server endpoint and status models
- `Presentation`: the shared SwiftUI shell
- `Input`: semantic commands and focus targets

The UI uses standard SwiftUI buttons and platform focus systems. It does not
simulate a pointer or tabletop physics.

### Story catalog artwork

Story image nodes use the selected server's public `/api/v1/site-settings`
`assetHost`, validated independently of catalog content. Missing/null settings
select the web client's hosted CDN; an empty setting uses the server origin.
Transport errors or unsafe hosts never silently select another source.
The catalog and its asset-source result share the existing profile/generation
fence and catalog retry action. A settings failure blocks image-bearing passages,
not otherwise-resolvable text-only stories. Retrying just the image source leaves
the verified catalog and its request/revision intact, including while offline.

`CatalogImageAsset` accepts only closed semantic artwork families and exact
PNG, JPEG, or AVIF paths below `/img/arkham/`. In particular,
`encounter-sets/` is not rewritten to `sets/`, and `.jpeg` is not changed to
`.jpg`. SVG, WebP, unknown roots, mismatched roles, traversal, and external URLs
remain unavailable rather than receiving placeholder artwork.

All platforms render decoded native images through the shared bounded
`AssetCacheService` and a per-view `AssetImageLoader`. The root injects one cache
across windows; disappearing/replaced images cancel their loaders. Supplied alt
text (or an accessible role label) accompanies loading, success, and explicit
retry/failure states. Safely representable references enable story actions;
network/decode failures remain visible and retryable, never placeholder success.
No official artwork is bundled.

Local image-cache initialization failures are reported as client-side failures
with a **Retry image support** action. Retrying reconstructs the shared cache and
reloads only the image source; once construction succeeds, all windows reuse that
one observed cache instance for the rest of the session, without requiring relaunch.

## Prerequisites

- macOS with Xcode 26 or newer
- [mise](https://mise.jdx.dev/)

The 26.0 deployment floor is intentional: the client targets the current
public Apple OS generation across every platform rather than carrying
compatibility branches for older SDKs. Required CI therefore runs on
`macos-26`; the beta Xcode path below is used for next-generation validation.

Install the pinned XcodeGen, SwiftFormat, and SwiftLint versions:

```sh
mise install
```

For the local beta Xcode installation, select the developer directory once per
shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

## Commands

```sh
mise run generate
mise run project-check
mise run format-check
mise run lint
mise run test
mise run build
```

`project-check` regenerates `ArkhamHorror.xcodeproj` and fails when the checked-in
project differs from `project.yml`.

## Current limitations

Phase 0 has no gameplay, persistence, accounts, deck management, or live network
requests. The server card is a compile-time UI contract only, and platform icons
are not yet provided. Product planning is tracked in
[djensenius/ArkhamHorror#5](https://github.com/djensenius/ArkhamHorror/issues/5)
and
[djensenius/ArkhamHorror-Apple#5](https://github.com/djensenius/ArkhamHorror-Apple/issues/5).
