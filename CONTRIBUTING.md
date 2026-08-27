# Contributing

ArkhamHorror-Apple is being built in reviewable vertical slices against the
[Apple roadmap](https://github.com/djensenius/ArkhamHorror-Apple/issues/5).
The Haskell backend remains authoritative for game rules.

## Before opening a pull request

- Search existing issues and discuss substantial product or protocol decisions
  before implementation.
- Report vulnerabilities through
  [private vulnerability reporting](https://github.com/djensenius/ArkhamHorror-Apple/security/advisories/new).
- Do not commit official card art, official gaming-mat art, authentication
  tokens, or private game exports.
- This repository does not yet have an open-source license. Do not assume
  permission to redistribute its source or assets.

## Local workflow

Install the pinned tools:

```sh
mise install
```

Use the selected Xcode installation and run the focused checks:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
mise run format-check
mise run lint
mise run test
mise run project-check
mise run build
```

Run the smallest relevant checks while iterating, then run every affected
platform build before requesting review.

## Pull requests

- Branch from the current `main`.
- Keep hand-written changes near 20 files and 2,000 lines or less.
- Put shared behavior in `ArkhamHorrorShared`; keep app targets thin and
  platform-specific.
- Use semantic commands, native focus, and standard controls. Controller input
  must not emulate a mouse cursor.
- Add focused tests for protocol parsing, state transitions, input mapping, and
  other high-risk behavior before visual hardening.
- Update `project.yml`, regenerate the Xcode project, and commit both when
  project structure changes.
