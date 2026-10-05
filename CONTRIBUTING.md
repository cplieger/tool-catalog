# Contributing to tool-catalog

The [shared rules](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md) for commits, synced files, checks and review apply here.

## Rules

A new file that `scripts/publish.sh` reads needs three more edits:

- A `push` path in `.github/workflows/publish.yaml`. Without it, the merge does not run the publisher, and the change waits for the next daily run.
- A field in the script's `STAMP`. Without it, the publisher finds the stamp unchanged and publishes nothing.
- The two sentences in the README's [How each release is built](README.md#how-each-release-is-built) section that list what a release records.

## Checks

Before you change `scripts/publish.sh`, `required-floor.txt`, `registries.env` or the `TOOLCATALOG_VERSION` pin, run the README's [dry run](README.md#building-locally). Pull-request CI never runs the publisher, so a broken compile or floor check fails the first publish after the merge.

## Releases

With no `cliff.toml`, commit types do not decide releases here. A release needs a change to one of the inputs the README's [How each release is built](README.md#how-each-release-is-built) section lists.

A fix to `scripts/publish.sh` alone publishes nothing and ships with the next release.
