# Live game log rows

`skids-skill-test-rows.json` is an unmodified projection of `game.log[0..<9]` from
`/tmp/arkham-logs/1213-investigation-skids-get.json` (existing local Drowned City playthrough capture,
2026-10-18; source SHA-256 `3c328d9fe882912e697c8d9cafc2632b0c6d08220be51e99e9ffd4b0528ac0ff`).
It retains a complete skill-test group, including its post-summary members,
and the following enemy-phase entry. No account/session credentials are included.
Synthetic cases in GameLogPresentationTests exercise legacy rows, private children,
partial/nonadjacent groups, future icons, and missing catalog keys separately.
This is not a governed Contract fixture.
