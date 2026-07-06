# Deployment — Cloudflare Pages

The marketing page (`web/index.html`) is a single self-contained static file:
inline CSS, no JavaScript, no external assets. Deploying it is just serving
that directory.

## One-time setup

In the Cloudflare dashboard → Pages → **Create a project** → **Connect to
Git**, pick `nickmeehan/cairns` and configure:

- **Framework preset:** None
- **Build command:** *(leave empty — there is no build step)*
- **Build output directory:** `web`
- **Production branch:** `main`

That is the whole configuration. Every push to `main` redeploys; `cairns.md`
is attached as the custom domain (Pages → Custom domains).

## Deliberately no functions, no env vars

There are no Pages Functions and no environment variables, on purpose. The old
trailhead/PWA generation shipped a `functions/api/github/` CORS proxy so a
browser could reach GitHub's device-flow endpoints; the native apps hit
`github.com` directly, so that proxy is gone. Nothing on this page needs a
secret, and the GitHub App client ID it might reference is public anyway.

If Cloudflare ever asks for a root directory, it is `/` — but there is no
`functions/` for it to discover, and that is the point: the page is static all
the way down.
