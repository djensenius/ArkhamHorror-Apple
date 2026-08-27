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
