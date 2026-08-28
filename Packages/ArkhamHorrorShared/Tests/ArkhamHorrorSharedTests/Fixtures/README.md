# Test Fixtures

## capabilities.json

Vendored from:
`djensenius/ArkhamHorror@2bf2935cde121498435744a06fcf63502a80ae43` (PR #23)

This is the **only** backend contract artifact vendored here. The full backend
contract manifest references many additional schema documents (OpenAPI, AsyncAPI,
JSON Schemas) that are **not** reproduced. See the backend repository for the
authoritative contract documents and the complete manifest.

## token.json / whoami.json

Synthetic, hand-authored fixtures used by the authentication-session tests. They
are **not** vendored from the backend and contain **no** real or reusable
credentials:

- `token.json` — a `Token` response whose `token` is the obvious placeholder
  `fixture-token-not-a-real-credential`.
- `whoami.json` — a `CurrentUser` response for a fictional account
  (`investigator@example.com`).
