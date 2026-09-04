# Renaming the repo without dropping off Community Applications

This repo was renamed from `blckassassin/ArkSA` to
`blckassassin/unraid-game-servers` on 2026-09-04, once it held more than one
game. The rename and the Community Applications listing were handled by hand,
outside git. This document is the record of what was done, in what order, and
which parts of it are still load-bearing.

**Status: complete.** Both ARK: Survival Ascended and Terraria are listed in
Community Applications under the new repository name.

## Why order matters here

`<TemplateURL>` in each template under `templates/` is a self-referential
declaration of where CA should fetch that template from. The CA appfeed
crawls every registered repo's templates on its own schedule — on the order of
hours, not immediately. If `<TemplateURL>` is rewritten to the new repo name in
the same commit as the rename, there is a window where the URL the template
*declares* and the URL the feed last *crawled it from* disagree. At worst that
drops the entry from the feed, which removes both ARK and Terraria from
Community Applications for everyone browsing it — not just new installs,
existing users' Docker tab entries too.

Raw URLs, by contrast, survive a repo rename on their own:
`raw.githubusercontent.com/<owner>/<old-name>/...` keeps resolving after the
repo is renamed, because GitHub serves the old path server-side. Verified
against three renamed repos that predate this one:
`GoogleCloudPlatform/kubernetes` (now `kubernetes/kubernetes`),
`visionmedia/express` (now `expressjs/express`) and `facebook/jest` (now
`jestjs/jest`) — all still serve raw content at their old owner/name path.
Confirmed again against this repo after its own rename, below.

Raw URLs do **not** survive a *file move*, only a repo rename. That is why
root `README.md`, `icon.png` and `icon.svg` stay exactly where they are and
always will — every installed ASA template's `<ReadMe>` and `<Icon>` point at
those exact paths, and moving the files (not just renaming the repo) would
break them with no redirect to save it.

## What was done, in order

1. **Merged the monorepo branch first, before renaming anything** (`52fd9fa`).
   Every template still pointed at `blckassassin/ArkSA` at that commit — that
   was intentional, not a leftover.

2. **Renamed the GitHub repository** to `unraid-game-servers`.

3. **Confirmed the frozen raw URLs still resolve** under the old owner/name
   path:

   ```sh
   for u in README.md icon.png icon.svg templates/ark-survival-ascended.xml; do
       printf '%-40s %s\n' "$u" \
         "$(curl -s -o /dev/null -w '%{http_code}' \
            "https://raw.githubusercontent.com/blckassassin/ArkSA/main/$u")"
   done
   ```

   All four returned `200`, and notably a *direct* 200 rather than a redirect —
   GitHub serves the old owner/name path transparently, so a client that does
   not follow redirects still works.

4. **Nothing was re-pointed, because nothing can be.** This step was
   originally written as "re-point the CA appfeed entry at the new repository
   name". That was wrong: the submission portal at `ca.unraid.net/submit/new`
   has no management area for an existing entry, only a one-way submit flow.
   Re-submitting would have created a duplicate listing of the same two apps.

   No action was needed. The feed's registration for **Blairwin's Repository**
   still reads:

   ```
   url:      https://github.com/blckassassin/ArkSA
   icon:     https://raw.githubusercontent.com/blckassassin/ArkSA/main/icon.svg
   WebPage:  https://github.com/blckassassin/ArkSA
   ```

   Every one of those paths survives the rename, including the API path the
   crawler uses:

   ```
   github.com/blckassassin/ArkSA            301 -> .../unraid-game-servers
   api.github.com/repos/blckassassin/ArkSA  301 -> api.github.com/repositories/1339965760
   .../contents/templates  (followed)       ark-survival-ascended.xml, terraria.xml
   ```

   The API redirect resolves the old owner/name to the repository's **numeric
   ID**, which a rename cannot change. The next crawl (feed time 10:48 on
   2026-09-04, about three hours after the rename) picked up the new
   `ca_profile.xml` bio and added the Terraria entry on its own.

5. **Only then**, in a separate follow-up commit, rewrote `<TemplateURL>`,
   `<Support>`, `<Project>`, `<Icon>` and `<ReadMe>` in both files under
   `templates/`, `<Icon>` / `<WebPage>` / the support URL in `ca_profile.xml`,
   the `org.opencontainers.image.source` label in `.github/workflows/build.yml`
   and in both games' Dockerfiles, and the badge, clone and project URLs in the
   READMEs and Docker Hub descriptions.

   The design spec and implementation plan under `docs/superpowers/` were left
   untouched: they are the historical record of the migration and describe the
   repository as it was named at the time.

## The listing depends on a redirect, permanently

The CA feed registration cannot be edited, so it will keep pointing at
`github.com/blckassassin/ArkSA` for as long as the listing exists. The listing
works only because GitHub still resolves that name to this repository.

> [!WARNING]
> **Never create a new repository named `blckassassin/ArkSA`, at any point.**
> GitHub frees an old repository name for the same owner to reuse once it has
> been renamed away from. A new repo created at that freed name does not
> inherit the redirect — instead it *becomes* the target of the CA feed's
> registration and of every frozen raw URL that installed templates still point
> at (root `README.md`, `icon.png`, `icon.svg`, the ASA template itself),
> silently substituting whatever that new repo contains for what users expect.
> `blckassassin/ArkSA` is permanently retired.
