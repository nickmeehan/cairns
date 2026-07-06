# AGENTS.md

Native Swift monorepo for Cairns: markdown note capture straight to a GitHub
repo. Local-first, no server. iOS talks the GitHub REST API; macOS operates
on the user's local clone via git. That divergence is deliberate — do not
unify the two sync engines.

## Map

- `CairnsKit/` — every piece of logic lives here; the app dirs only compose.
  Fast loop: `cd CairnsKit && swift test`.
- `ios/` — SwiftUI shell. Capture-first: launch → focused blank editor.
  Saves go through `CaptureQueue` (durable, drains via `GitHubAPI`).
- `macos/` — SwiftUI menu-bar shell. ⌘⇧N capture panel. Saves go through
  `GitSync` (atomic write + git add/commit in the user's clone; background
  push retry + cadence pull).
- `web/` — static marketing page, Cloudflare Pages, no build step.

## Contracts (breaking these corrupts user repos — test first)

- Filenames: `YYYY-MM-DD-HHMMSS.md`, local time. Conflict siblings:
  `{stem}--local-{timestamp}{ext}`.
- Commit messages: `Add: <name>`, `Update: <name>`,
  `Add (conflict copy): <name>`.
- Updates always refetch the SHA immediately before the PUT; a 409 after
  that is a true concurrent write and lands at the conflict sibling. Never
  overwrite on 409.
- 401 halts queues and routes to re-auth; pending writes are preserved.
  403 is NOT an auth failure (rate limits) — never sign the user out on it.
- Tokens live in the Keychain only. Never in files, UserDefaults, or logs.
  The Mac app never injects the token into git — pushes use the user's own
  git credentials.

## Rules

- Done means `bin/ci` is green (run `bin/setup` once first).
- Red–green–refactor: a failing test in `CairnsKitTests` precedes logic.
- SwiftLint/SwiftFormat are walls, not suggestions (`--strict`).
- Commits: Conventional Commits v1.0.0, imperative mood.
- Non-trivial flows get a doc in `docs/architecture/`; update it in the
  same change that alters the flow.
