# Fabrica — landing page

A static, self-contained "coming soon" landing page for Fabrica, served at
**fabrica.yihanzhu.com**.

## Files

| File | Purpose |
|------|---------|
| `index.html` | The page (single-page; entry point). |
| `styles.css` | All styling — warm-ember "workshop / forge" theme. |
| `favicon.svg` | Brand mark (anvil) used as the tab icon. |
| `robots.txt` | Allows crawlers; points at the sitemap. |
| `sitemap.xml` | Single-URL sitemap. |

No build step, no dependencies, no JS framework. The only external request is the
Google Fonts stylesheet (Fraunces + Inter), and the page degrades to system fonts if
it fails to load.

## Deploy (Cloudflare Pages)

This folder is the publish root.

- **Build command:** *(none)*
- **Build output directory:** `website`
- **Framework preset:** None / Static HTML

Point the custom domain `fabrica.yihanzhu.com` at the Pages project. That's it — the
files are served as-is.

To preview locally:

```sh
cd website && python3 -m http.server 8000   # then open http://localhost:8000
```

## When distribution is decided

- **Waitlist / notify:** there's a clearly-marked `WAITLIST PLACEHOLDER` comment in
  `index.html` (in the hero). Drop a capture form there — with Cloudflare you can POST to
  a Pages Function / Worker, or embed a hosted form. Keep it inline and dependency-free.
- **Social preview image:** add a 1200×630 PNG and wire `og:image` (there's a note next
  to the Open Graph tags in `<head>`).
- **Repo link / docs:** the GitHub repo is currently private, so the page intentionally
  links nowhere external. Add links once there's a public destination.

## Note

This page is a marketing artifact, not part of the team-restore backup, so it is **not**
listed in `ci/required-files.txt`. CI stays green regardless (the structure check only
verifies listed files exist; there are no shell scripts here for shellcheck).
