# Cairns

Minimal, source-available note capture for Mac and iOS — native Swift apps
that commit plain markdown straight to a GitHub repository you own. No cloud
lock-in, no servers in the middle, nothing between you and your repo.

Cairns is the capture layer: a blank page that's always one keystroke away,
with everything landing as markdown commits in your repo. Heavy editing
happens wherever you already work — your IDE, Obsidian, an agent running
against the clone.

## Features

- **Quick capture** — ⌘⇧N opens a capture window from anywhere on Mac; open
  the app to a ready-to-type blank note on iOS (type or dictate).
- **Your repo, your notes** — every note is a markdown file committed to a
  GitHub repository you own. Full git history, nothing proprietary.
- **Works offline** — on Mac notes are local git commits that push when they
  can; on iOS they queue durably and drain automatically.
- **Native state** — your GitHub token lives in the Keychain. No browser
  storage, nothing for the OS to evict.
- **Agent-ready** — plain markdown in git. Claude Code, Codex, and your own
  scripts can read and operate on every note.
- **No subscription** — GitHub already syncs your files for free.
- **Auditable** — no telemetry, no tracking. Read every line.

## Install

Pre-signing distribution while Cairns finds its audience; App Store /
TestFlight comes later.

- **Mac** — download the `.dmg` from the latest GitHub release. First launch:
  right-click → Open to get past Gatekeeper (unidentified developer).
- **iOS** — sideload the `.ipa` from the release (AltStore/Sideloadly), or
  clone this repo and run the `ios/` app on your device from Xcode with a
  free Apple ID.

Sign in with GitHub (device flow — no password ever touches Cairns) and
install the Cairns GitHub App on the repository you want notes in. The Mac
app additionally points at your local clone of that repository.

## Repo map

- `CairnsKit/` — all logic, one SPM package (`swift test` is the fast loop)
- `ios/` — thin SwiftUI shell: capture-first editor, notes list, settings
- `macos/` — thin SwiftUI shell: menu-bar app, global hotkey, capture panel
- `web/` — static marketing page (Cloudflare Pages)
- `bin/setup` / `bin/ci` — bootstrap and the local gate

```bash
bin/setup   # pinned tools via mise (Xcode pinned by .xcode-version)
bin/ci      # format lint, SwiftLint, CairnsKit tests, both app builds
```

## License

[PolyForm Shield License 1.0.0](./LICENSE) — view, audit, use, and fork
freely; building a competing product with it is not allowed. Commercial
overlap? Reach out: nick [at] meehan [dot] tech.
