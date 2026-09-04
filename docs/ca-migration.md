# Renaming the repo without dropping off Community Applications

This repo is currently `blckassassin/ArkSA`. At some point it gets renamed to
something that reflects it holding more than one game (e.g.
`unraid-game-servers`). That rename, and re-pointing the Community
Applications appfeed at it, are manual steps done by hand outside git — this
document is the order to do them in, and why the order matters.

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
repo is renamed, because GitHub redirects the old path server-side. Verified
against three renamed repos that predate this one:
`GoogleCloudPlatform/kubernetes` (now `kubernetes/kubernetes`),
`visionmedia/express` (now `expressjs/express`) and `facebook/jest` (now
`jestjs/jest`) — all still serve raw content at their old owner/name path.

Raw URLs do **not** survive a *file move*, only a repo rename. That is why
root `README.md`, `icon.png` and `icon.svg` stay exactly where they are and
always will — every installed ASA template's `<ReadMe>` and `<Icon>` point at
those exact paths, and moving the files (not just renaming the repo) would
break them with no redirect to save it.

## Do these in order

1. **Merge this branch first, before renaming anything.** Every template still
   points at `blckassassin/ArkSA` — that is intentional, not a leftover to
   clean up. Do not rewrite any URL in this same change.

2. **Rename the GitHub repository** (Settings → repository name) to the new
   name, e.g. `unraid-game-servers`.

3. **Confirm the frozen raw URLs still resolve** under the old owner/name path:

   ```sh
   for u in README.md icon.png icon.svg templates/ark-survival-ascended.xml; do
       printf '%-40s %s\n' "$u" \
         "$(curl -s -o /dev/null -w '%{http_code}' \
            "https://raw.githubusercontent.com/blckassassin/ArkSA/main/$u")"
   done
   ```

   All four must print `200`. If any does not, stop here and investigate
   before touching the appfeed — do not proceed on a broken redirect.

4. **Re-point the CA appfeed entry** at the new repository name. Wait for the
   feed to regenerate on its own schedule, then confirm both **ARK: Survival
   Ascended** and **Terraria** still appear in Community Applications.

5. **Only now**, in a separate follow-up commit, rewrite `<TemplateURL>`,
   `<Support>` and `<Project>` in both files under `templates/`, and `<Icon>`
   / `<WebPage>` in `ca_profile.xml`, to point at the new repository name.
   Also rewrite the `org.opencontainers.image.source` label in
   `.github/workflows/build.yml` and `games/terraria/Dockerfile` — both
   still say `blckassassin/ArkSA`.

> [!WARNING]
> **Never create a new repository named `blckassassin/ArkSA`, at any point
> during or after this migration.** GitHub frees an old repository name for
> the same owner to reuse once it has been renamed away from. A new repo
> created at that freed name does not inherit the redirect — instead it
> *becomes* the target of every frozen raw URL that installed templates still
> point at (root `README.md`, `icon.png`, `icon.svg`, the ASA template itself),
> silently substituting whatever that new repo contains for what users expect.
> Treat `blckassassin/ArkSA` as permanently retired once the rename happens.
