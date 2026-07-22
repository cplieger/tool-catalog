#!/bin/bash
# Compile the tool catalog from the PINNED mise + aqua registry refs in
# registries.env and publish it as a dated GitHub release. Renovate bumps
# the pins and the merge triggers .github/workflows/publish.yaml (push
# trigger), so releases follow upstream at the Renovate sweep cadence; the
# workflow's daily cron is a self-heal retry only (the idempotence stamp
# below makes it a no-op while the newest release already matches the
# pins). Run locally with DRY_RUN=1 to produce ./tool-catalog.json without
# touching GitHub releases.
#
# Registry tarballs are fetched BY COMMIT (the tag's dereferenced commit,
# pinned next to the tag): git content addressing keeps the extracted tree
# stable while archive bytes may vary, so no tarball checksum is kept —
# integrity rests on TLS to GitHub plus the reviewed pin, and the release
# notes record the exact tags AND commits ingested, so a moved upstream
# tag lands as a visible digest-only Renovate PR and re-publishes rather
# than skips.
#
# Environment:
#   TOOLCATALOG_VERSION  (required) toolcatalog lane tag, e.g. v2.1.0
#   TOOLCATALOG_RUN      (optional) override the compiler invocation; used by
#                        local simulation to run a checked-out lane instead of
#                        the published module
#   DRY_RUN=1            (optional) compile + verify only; write the artifact
#                        to ./tool-catalog.json and skip release creation
set -euo pipefail

TOOLCATALOG_VERSION="${TOOLCATALOG_VERSION:?set TOOLCATALOG_VERSION (toolcatalog lane tag, e.g. v2.1.0)}"
TOOLCATALOG_RUN="${TOOLCATALOG_RUN:-go run github.com/cplieger/toolbelt/cmd/toolcatalog/v2@${TOOLCATALOG_VERSION}}"
DRY_RUN="${DRY_RUN:-0}"
REPO="${GITHUB_REPOSITORY:-cplieger/tool-catalog}"
# Absolute: TOOLCATALOG_RUN may change the compiler's working directory
# (the local-simulation `go run -C <lane> .` case).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOOR="$ROOT/required-floor.txt"

# Pinned registry refs (Renovate-bumped tag+commit pairs; see the file's
# header). Guard every value: a malformed pin must fail here, loudly,
# not as a 404 mid-fetch or a tarball of the wrong tree.
# shellcheck source=/dev/null
. "$ROOT/registries.env"
for v in MISE_REF MISE_COMMIT AQUA_REF AQUA_COMMIT; do
  [ -n "${!v:-}" ] || {
    echo "publish: ERROR registries.env does not set ${v}" >&2
    exit 1
  }
done
for v in MISE_COMMIT AQUA_COMMIT; do
  if ! [[ "${!v}" =~ ^[a-f0-9]{40}$ ]]; then
    echo "publish: ERROR ${v}='${!v}' is not a 40-hex commit" >&2
    exit 1
  fi
done
REFS="mise=${MISE_REF},aqua=${AQUA_REF}"
# The idempotence stamp carries tags AND commits: a moved upstream tag
# (same name, different commit) must re-publish, never skip.
STAMP="refs: mise=${MISE_REF}@${MISE_COMMIT},aqua=${AQUA_REF}@${AQUA_COMMIT} lane: ${TOOLCATALOG_VERSION}"
echo "publish: ${STAMP}"

# Idempotent daily cron: skip when the newest release already carries this
# exact stamp (tags + commits + lane). The marker read is hardened against
# CRLF from web-UI note edits and against multiple refs: lines; any marker
# breakage fails SAFE (a duplicate publish, never a skipped needed one).
if [ "$DRY_RUN" != "1" ]; then
  last=$(gh release view --repo "$REPO" --json body --jq .body 2>/dev/null | tr -d '\r' | grep -m1 -F 'refs: ' || true)
  if [ "$last" = "$STAMP" ]; then
    echo "publish: up to date, nothing to do"
    exit 0
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Fixed extraction destinations (--strip-components=1): the tarball's
# top-level directory name is codeload convention, not a documented
# contract, so do not depend on its exact shape.
mkdir -p "$WORK/mise" "$WORK/aqua"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 5 -fsSL \
  "https://codeload.github.com/jdx/mise/tar.gz/${MISE_COMMIT}" | tar -xz --strip-components=1 -C "$WORK/mise"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 5 -fsSL \
  "https://codeload.github.com/aquaproj/aqua-registry/tar.gz/${AQUA_COMMIT}" | tar -xz --strip-components=1 -C "$WORK/aqua"

# Compile (the lane embeds its base overlays, both registry LICENSE texts,
# and a generated timestamp) and verify the engine floor: the seed template
# names plus the backend runtimes every consumer relies on. App-specific
# required sets stay in each consumer (verified at image build and again at
# every runtime refresh).
$TOOLCATALOG_RUN \
  -mise "$WORK/mise/registry" \
  -aqua "$WORK/aqua/pkgs" \
  -refs "$REFS" \
  -out "$WORK/tool-catalog.json"
$TOOLCATALOG_RUN verify -catalog "$WORK/tool-catalog.json" -require "$FLOOR"

ENTRIES=$(jq '.entries | length' "$WORK/tool-catalog.json")

if [ "$DRY_RUN" = "1" ]; then
  cp "$WORK/tool-catalog.json" ./tool-catalog.json
  echo "publish: DRY RUN — would release ${ENTRIES} entries (${STAMP}); artifact at ./tool-catalog.json"
  exit 0
fi

TAG="v$(date -u +%Y.%m.%d)"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  TAG="${TAG}.$(date -u +%H%M)" # same-day re-run with changed refs
fi

# --latest is explicit: every release here tags the same default-branch
# commit with non-semver dated tags, exactly the shape where GitHub's
# automatic latest selection (created_at + semver tie-breakers) is
# degenerate. The consumer contract IS the latest pointer; never leave
# it to the automatic mapping.
# shellcheck disable=SC2016 # the backticks are a markdown code span in the notes, not a command substitution
NOTES=$(printf '%s\nentries: %s\n\nCompiled from the mise registry and the aqua registry (both MIT; license texts embedded in the artifact). Consumers fetch `releases/latest/download/tool-catalog.json`.\n' "$STAMP" "$ENTRIES")
gh release create "$TAG" "$WORK/tool-catalog.json" --repo "$REPO" --title "$TAG" --latest --notes "$NOTES"

# Post-publish contract check: the stable latest URL must now serve THIS
# release's asset. Fail loudly if the latest pointer did not move — a
# broken pointer is exactly the failure consumers cannot see.
LOCATION=$(curl -sI -o /dev/null -w '%{redirect_url}' "https://github.com/${REPO}/releases/latest/download/tool-catalog.json")
case "$LOCATION" in
*"/${TAG}/"*) echo "publish: released ${TAG} (${ENTRIES} entries); latest pointer verified" ;;
*)
  echo "publish: ERROR released ${TAG} but the latest download URL resolves to: ${LOCATION}" >&2
  exit 1
  ;;
esac
