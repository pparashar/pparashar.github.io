# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is **Prashant Parashar's personal blog/website**, served at `https://www.prashantparashar.com`
(GitHub Pages, `pparashar/pparashar.github.io`, `CNAME` → `www.prashantparashar.com`).

It is a Jekyll site built on a **fork of the Minimal Mistakes theme v4.10.0** — the theme's own
source (`_layouts/`, `_includes/`, `_sass/`, `assets/`, `_data/ui-text.yml`) lives directly in this
repo rather than being pulled in as a gem. This means **theme files and personal content are mixed
together**. When editing, distinguish between:
- **Personal content** you'll usually touch: `_posts/`, `_pages/`, `_config.yml`, `_data/navigation.yml`, `index.html`, top-level HTML pages.
- **Theme internals** (only touch when intentionally customizing the theme): `_layouts/`, `_includes/`, `_sass/`, `assets/css/`, `assets/js/`, `_data/ui-text.yml`.

The theme's bundled demo/docs (`/docs`, `/test`) are excluded from the build via `_config.yml` and are not part of the live site.

## Commands

```bash
bundle install                 # install gems (run once / after Gemfile changes)
bundle exec jekyll serve       # local dev server with live reload at http://localhost:4000
bundle exec jekyll serve --drafts   # also render _drafts/
bundle exec jekyll build       # build static site into _site/
```

`bundle exec rake preview` is a theme-development task that serves the demo content under `test/` — **not** the personal site. Use `jekyll serve` for normal work.

> **Apple Silicon local builds**: on the old system Ruby (2.6, universal) bundler resolves an
> x86_64 Nokogiri (pulled in by `jemoji`), which the arm64 process can't load. Prefix Jekyll
> commands with `arch -x86_64` (e.g. `arch -x86_64 bundle exec jekyll serve`). Gems install to a
> local `vendor/bundle` (`bundle install --path vendor/bundle`; `vendor/` is gitignored), and
> `kramdown-parser-gfm` is added to the `Gemfile` for local GFM builds. None of this affects the
> deployed site — GitHub Pages builds with its own gem set and ignores the `Gemfile`. The
> `scripts/fetch_articles.rb` fetcher is stdlib-only and runs under plain `ruby` without any of this.

Rebuilding minified JS (only if editing theme JS under `assets/js/`):
```bash
npm install
npm run build:js               # uglify + add license banner -> assets/js/main.min.js
npm run watch:js
```

There is no test suite for the personal content; "testing" means building locally and checking pages render.

## Authoring Content

### Blog posts (`_posts/`)
- Filename: `YYYY-MM-DD-title-slug.md` (Jekyll requires the date prefix).
- ~85 posts spanning 2010–present. Markdown is **kramdown / GFM**, syntax highlighting via **rouge**.
- Frontmatter pattern (see existing posts):
  ```yaml
  ---
  title: Pandas Basics by Practice
  date: 2019-02-12
  permalink: /python-pandas-basics-by-practice-data-science-2019-02.html
  categories:
    - Data Science
  tags:
    - Python
    - ML
  ---
  ```
- Posts default (via `_config.yml` `defaults`) to `layout: single` with author profile, read time, Disqus comments, sharing, and related posts enabled. Don't restate these per-post unless overriding.
- `excerpt_separator` is a blank line (`"\n\n"`) — the text before the first blank line becomes the excerpt.
- Drafts go in `_drafts/` (no date prefix) and only render with `--drafts`.

### Pages (`_pages/`)
- Standalone pages (about, contact, terms, archives). Each sets its own `permalink`.
- `wiki-*.md` pages are a curated resources/bookmarks "wiki" section.
- Pages default to `layout: single` with comments/sharing/related **off**.

### Navigation
- Top nav is driven by `_data/navigation.yml` (`main:` list of `title`/`url`).

### Home page & "Mentions on the Web" (external links)

The home page (`/`) is a **landing page**, not a blog index: it renders only the author sidebar and a
**"Mentions on the Web"** grid of external articles/videos/talks about the owner, plus an
**"Archived posts →"** link to `/year-archive/` (which lists every blog post by year). There is no
post pagination — `jekyll-paginate` is intentionally disabled (the old v1 gem can't make page 1
post-free without dropping posts).

Pieces involved:
- `index.html` — `layout: home`, `author_profile: true`, empty body.
- `_layouts/home.html` — custom layout (built on `default`): sidebar + mentions include + archive link.
- `_includes/external-articles.html` — renders the card grid. Self-contained CSS grid (not the
  theme's float grid, which overlapped on desktop) with a scoped `<style>` block. Cards detect
  YouTube URLs to add a play-button overlay + YouTube icon. Renders nothing if the data file is empty.
- `_data/external_articles.yml` — the curated list (data source + build-time cache).
- `scripts/fetch_articles.rb` — build-time metadata fetcher (stdlib only, no gems).

**To add / edit a mention** (the intended everyday workflow):
1. Add an entry to `_data/external_articles.yml`, below the `# Add your entries below this line:`
   marker — at minimum just a quoted `url:`. The URL must be a **specific** article/video page (a
   YouTube watch URL, a news article), **not** a search results page.
2. Run the fetcher (no bundler needed):
   ```bash
   ruby scripts/fetch_articles.rb            # fills only new/unfetched entries
   ruby scripts/fetch_articles.rb --force    # re-fetch everything
   # equivalently: bundle exec rake fetch_articles  [-- --force]
   ```
   It downloads each page and fills `title` / `image` / `excerpt` / `source` / `date` from Open
   Graph / Twitter / JSON-LD metadata, marks the entry `fetched: true` (so re-runs are idempotent),
   then **sorts all entries newest-first** and writes the file back (preserving the comment header).
3. Review the diff, refresh `localhost:4000`, then commit the updated YAML.

Per-entry fields (any value you set by hand is a **manual override** the fetcher never clobbers):
- `date` — shown on the card; auto-filled when detectable. Set it manually for pages that expose no
  machine-readable date (e.g. event landing pages, Instagram — Instagram dates can be decoded from
  the post shortcode).
- `sort_date` — **ordering only**, overrides `date` for the newest-first sort without changing the
  date shown. Use it to pin an entry to a position (e.g. a very recent post you want lower down).
- `title` — override to shorten long social-post titles.
- `image` — override when the page's `og:image` 404s or is poor; the card CSS resizes/crops any
  image to a 16:9 thumbnail via `object-fit: cover`.
- `type: video` — forces the play-button overlay for non-YouTube videos.

Caveats: some sites block server-side scrapers (e.g. Cloudflare 403s) — those entries get no
auto-metadata and need manual `title`/`image`/`date`, or should be dropped. Wikipedia exposes only
`og:title` (no image/description), so such cards render text-only.

## Key Configuration (`_config.yml`)

- **Permalinks**: `/:categories/:title/` site-wide, though most posts override with an explicit `permalink`. Preserve existing permalinks when editing old posts — they are live URLs.
- **Theme skin**: `minimal_mistakes_skin: "mint"`.
- **Comments**: Disqus (`shortname: prashantparashar`).
- **Search**: enabled, full-content, lunr provider.
- **Analytics**: Google (`UA-572757-11`). **Pagination**: disabled (see *Home page & Mentions* above); all posts are listed on `/year-archive/`.
- **Archives**: liquid-based year (`/year-archive/`, the "Archived Posts" page), category (`/category/`) and tag (`/tag/`) archives — keep `breadcrumbs` links valid.
- **Plugins** (GitHub Pages-safe, whitelisted): `jekyll-sitemap`, `jekyll-gist`, `jekyll-feed`, `jemoji`.
- `timezone: Asia/Calcutta`.

## Deployment

GitHub Pages builds and deploys automatically on push to the default branch (`master`). There is no separate build/deploy step — committing renders the site live. Verify locally with `jekyll build` before pushing, especially when touching `_config.yml` (config changes are not hot-reloaded by `jekyll serve`).
