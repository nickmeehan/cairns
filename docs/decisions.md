# Decisions

Why things are the way they are. Read before "fixing" something odd.

## Native rewrite of the Cairns product (2026-07-05)

The shipped Cairns (built in the `trailhead` repo) is a PWA + Tauri app.
iOS PWAs keep evicting browser storage — including the auth token — which
is fatal for a capture app. This repo is the native Swift generation of the
same product: token in the Keychain, state in real files, same notes-repo
contract (filenames, commit messages, folder config) so both generations
can write to the same repo during the transition.

## Two sync engines, on purpose

- iOS has no local clone, so it speaks the GitHub REST Contents API with a
  durable offline queue (trailhead's PWA semantics).
- macOS operates on the user's existing local clone: save = git commit,
  queue = unpushed commits, push retry + cadence `pull --rebase
  --autostash` (trailhead's Tauri semantics, PR #76 there).

Unifying them on the API would orphan the user's local clone and other
tools editing it; unifying on git is impossible on iOS. Keep both.

## Toolchain floors are pinned by the dev Mac (2026-07-05)

Xcode 16.2 / Swift 6.0 / macOS 14.7 is what the development machine can
host, so: `swift-tools-version: 6.0`, Swift 6 language mode, floors
iOS 17 / macOS 14. The macOS 14 floor is load-bearing — it keeps
`swift test` and the built Mac app runnable on this machine. Raise floors
only when the dev Mac (and CI image) moves.

## Distribution: untrusted-developer first

GitHub Releases carries an ad-hoc-signed `.dmg` (right-click → Open) and an
unsigned `.ipa` for sideloading, until product appetite justifies Apple
Developer Program signing + the stores. The release workflow is written so
signing can be layered in without restructuring. Consequence: the Mac app
must stay un-sandboxed for now anyway (it shells out to git in the user's
clone) — App Store distribution of the Mac app will need a rethink
(sandbox vs. git subprocess), which is fine: appetite first.

## GitHub App reused from the trailhead era

Same app (device flow, Contents R&W only, user-token expiration DISABLED —
no refresh flow, ever, by decision). Users who installed it on their notes
repo need no new setup. Native apps hit github.com's device-flow endpoints
directly; the Cloudflare OAuth proxy was only ever a browser-CORS shim.
Client ID is public and lives in `CairnsGitHubApp.clientID`.

## No Git Data API large-file path

Trailhead added a blob→tree→commit path for >750 KB writes. Capture notes
are small; the Contents API PUT covers them with one round-trip. If a real
note ever exceeds a few MB the API returns an error and the note stays
queued locally — add the Git Data path then, not before.

## Bundle IDs

`com.cairns.ios` / `com.cairns.mac`. The Tauri app already owns
`com.cairns.app`; distinct IDs let both generations coexist on one machine
during the transition.

## `nickmeehan/cairns` on GitHub is currently trailhead's release mirror

trailhead's `sync-public.yml` force-pushes there on every `v*` tag. Before
this repo gets a remote, that mirror arrangement has to be retired or
renamed — do not push this repo over it casually.
