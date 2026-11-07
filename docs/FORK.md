# This fork

`RishabhChitale/wooloo` is a fork of [rarce/wooloo](https://github.com/rarce/wooloo) with its own changes on top, released from the fork.

## What differs from upstream

- **Versions** are `X.Y.Z.N`: `X.Y.Z` is the upstream release the fork is based on, `N` is our build of it (`0.3.16.1`). `MARKETING_VERSION` in `wooloo.xcodeproj/project.pbxproj` and the release tag `vX.Y.Z.N` must match. Upstream's `vX.Y.Z` tags still pass the checks.
- **Updates** come from the fork: `SUFeedURL` in `wooloo/Info.plist` points at this repository's latest release, and `SUPublicEDKey` is the fork's own Sparkle key (the matching private key is the `SPARKLE_PRIVATE_KEY` repository secret).
- **CI and Release** also start with `workflow_dispatch`, because pushes made with `GITHUB_TOKEN` start no workflows. The release gate (`scripts/ci_policy.py`) accepts a successful CI run on `main` at the tagged commit from either a push or a dispatch.
- **Pages** (`pages.yml`) is manual only, so the fork does not deploy upstream's site.
- Our own code changes live on `main`; docs and the site are left as upstream's.

## Releases

Tag `vX.Y.Z.N` on a `main` commit whose CI passed, and the Release workflow builds the app, signs `appcast.xml` and publishes the release. A tag pushed by hand starts it; otherwise run it with `gh workflow run release.yml -f tag=vX.Y.Z.N` (the tag must already exist).

## Upstream sync

`upstream-sync.yml` runs daily at 09:00 UTC (and on demand). It finds the latest upstream `vX.Y.Z` tag. If `main` already contains it, it stops. Otherwise it:

1. merges the tag into `main` (merge commit; our commits stay);
2. on a conflict, aborts and opens or updates one issue, "Upstream vX.Y.Z needs a manual merge", listing the files;
3. otherwise sets `MARKETING_VERSION` to `X.Y.Z.1`, pushes `main`, runs CI with `workflow_dispatch` and waits for it (a failure opens an issue and stops);
4. tags `vX.Y.Z.1` and runs the Release workflow for it.

After fixing a conflict by hand, push the merge with the version set to `X.Y.Z.1`, then tag it yourself.

## Releasing our own changes

When the fork changes without a new upstream release, raise `N`: set `MARKETING_VERSION` to `X.Y.Z.(N+1)` in the same commit (or a follow-up on `main`), wait for CI, then tag `vX.Y.Z.(N+1)`. Sparkle compares the numeric version, so `N` must only go up for a given `X.Y.Z`. The sync resets it to `.1` for each new upstream release.
