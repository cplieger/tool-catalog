#!/bin/bash
# Compile the tool catalog from the latest mise + aqua registry releases and
# publish it as a dated GitHub release. Runs daily from
# .github/workflows/publish.yaml; run locally with DRY_RUN=1 to produce
# ./tool-catalog.json without touching GitHub releases.
#
# Registry tarballs are fetched BY COMMIT (the tag's dereferenced commit):
# git content addressing is the integrity anchor, so no tarball checksum is
# needed and a moved tag cannot silently change what a given run ingested —
# the release notes record the exact refs.
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
FLOOR="$(cd "$(dirname "$0")/.." && pwd)/required-floor.txt"

# resolve <owner/repo> -> "latest-release-tag dereferenced-commit"
resolve() {
  local tag commit
  tag=$(gh api "repos/$1/releases/latest" --jq .tag_name)
  commit=$(gh api "repos/$1/commits/${tag}" --jq .sha)
  printf '%s %s\n' "$tag" "$commit"
}

read -r MISE_REF MISE_COMMIT < <(resolve jdx/mise)
read -r AQUA_REF AQUA_COMMIT < <(resolve aquaproj/aqua-registry)
REFS="mise=${MISE_REF},aqua=${AQUA_REF}"
STAMP="refs: ${REFS} lane: ${TOOLCATALOG_VERSION}"
echo "publish: ${STAMP}"
echo "publish: mise ${MISE_COMMIT}, aqua ${AQUA_COMMIT}"

# Idempotent daily cron: skip when the newest release already carries these
# registry refs at this lane version (its notes embed the STAMP line).
if [ "$DRY_RUN" != "1" ]; then
  last=$(gh release view --repo "$REPO" --json body --jq .body 2>/dev/null | grep -F 'refs: ' || true)
  if [ "$last" = "$STAMP" ]; then
    echo "publish: up to date, nothing to do"
    exit 0
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/registries"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 5 -fsSL \
  "https://codeload.github.com/jdx/mise/tar.gz/${MISE_COMMIT}" | tar -xz -C "$WORK/registries"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 5 -fsSL \
  "https://codeload.github.com/aquaproj/aqua-registry/tar.gz/${AQUA_COMMIT}" | tar -xz -C "$WORK/registries"

# Compile (the lane embeds its base overlays, both registry LICENSE texts,
# and a generated timestamp) and verify the engine floor: the seed template
# names plus the backend runtimes every consumer relies on. App-specific
# required sets stay in each consumer (verified at image build and again at
# every runtime refresh).
$TOOLCATALOG_RUN \
  -mise "$WORK/registries/mise-${MISE_COMMIT}/registry" \
  -aqua "$WORK/registries/aqua-registry-${AQUA_COMMIT}/pkgs" \
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

# shellcheck disable=SC2016 # the backticks are a markdown code span in the notes, not a command substitution
NOTES=$(printf '%s\nentries: %s\n\nCompiled from the mise registry and the aqua registry (both MIT; license texts embedded in the artifact). Consumers fetch `releases/latest/download/tool-catalog.json`.\n' "$STAMP" "$ENTRIES")
gh release create "$TAG" "$WORK/tool-catalog.json" --repo "$REPO" --title "$TAG" --notes "$NOTES"
echo "publish: released ${TAG} (${ENTRIES} entries)"
