#!/bin/bash
# Compile the tool catalog from the registry pins in registries.env and publish
# it as a dated GitHub release. Tarballs are fetched BY COMMIT, so a moved
# upstream tag re-publishes rather than skips and no tarball checksum is kept.
#
# Environment:
#   TOOLCATALOG_VERSION  (required) toolbelt tag the compiler runs at, e.g. v3.0.1
#   TOOLCATALOG_RUN      (optional) override the compiler invocation
#   DRY_RUN=1            (optional) compile + verify only, write
#                        ./tool-catalog.json, create no release
set -euo pipefail

TOOLCATALOG_VERSION="${TOOLCATALOG_VERSION:?set TOOLCATALOG_VERSION (toolbelt tag, e.g. v3.0.1)}"
# Derived, never written beside the pin: Renovate bumps this across a major
# boundary and cannot rewrite a hardcoded path, so a written suffix would ask
# the proxy for toolbelt/v2@v3.0.1 and stall every publish (hit 2026-08-21).
# A tag this cannot parse stops here, not at a 404 mid-fetch.
TOOLCATALOG_MAJOR="${TOOLCATALOG_VERSION%%.*}"
case "$TOOLCATALOG_MAJOR" in
  v0 | v1) TOOLCATALOG_MODULE="github.com/cplieger/toolbelt" ;;
  v[1-9]*) TOOLCATALOG_MODULE="github.com/cplieger/toolbelt/${TOOLCATALOG_MAJOR}" ;;
  *)
    echo "publish: ERROR TOOLCATALOG_VERSION='${TOOLCATALOG_VERSION}' is not a vN tag" >&2
    exit 1
    ;;
esac
TOOLCATALOG_RUN="${TOOLCATALOG_RUN:-go run ${TOOLCATALOG_MODULE}/cmd/toolcatalog@${TOOLCATALOG_VERSION}}"
DRY_RUN="${DRY_RUN:-0}"
REPO="${GITHUB_REPOSITORY:-cplieger/tool-catalog}"
# Absolute: TOOLCATALOG_RUN may change the compiler's working directory
# (the local-simulation `go run -C <lane> .` case).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOOR="$ROOT/required-floor.txt"

# Guard every pin: a malformed value must fail here, loudly, not as a 404
# mid-fetch or a tarball of the wrong tree.
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
# The stamp carries commits as well as tags (a moved tag must re-publish, never
# skip) and a floor digest, so a floor change re-publishes and the merge
# verifies the new floor instead of hiding a regression until the next bump.
FLOOR_DIGEST=$(sha256sum "$FLOOR" | cut -c1-12)
STAMP="refs: mise=${MISE_REF}@${MISE_COMMIT},aqua=${AQUA_REF}@${AQUA_COMMIT} lane: ${TOOLCATALOG_VERSION} floor: ${FLOOR_DIGEST}"
echo "publish: ${STAMP}"

# Skip when the newest release already carries this exact stamp. The marker read
# tolerates CRLF from web-UI note edits and pins one line; any breakage fails
# SAFE, as a duplicate publish rather than a skipped needed one.
if [ "$DRY_RUN" != "1" ]; then
  last=$(gh release view --repo "$REPO" --json body --jq .body 2>/dev/null | tr -d '\r' | grep -m1 -F 'refs: ' || true)
  if [ "$last" = "$STAMP" ]; then
    echo "publish: up to date, nothing to do"
    exit 0
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# --strip-components=1: the tarball's top-level directory name is codeload
# convention, not a documented contract, so nothing may depend on its shape.
mkdir -p "$WORK/mise" "$WORK/aqua"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 5 -fsSL \
  "https://codeload.github.com/jdx/mise/tar.gz/${MISE_COMMIT}" | tar -xz --strip-components=1 -C "$WORK/mise"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 5 -fsSL \
  "https://codeload.github.com/aquaproj/aqua-registry/tar.gz/${AQUA_COMMIT}" | tar -xz --strip-components=1 -C "$WORK/aqua"

# Verify the ENGINE floor only: seed template names plus the backend runtimes
# every consumer relies on. App-specific required sets stay in each consumer.
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

# --latest is explicit: these are non-semver dated tags on the same commit,
# exactly where GitHub's automatic latest selection is degenerate, and the
# consumer contract IS the latest pointer.
# shellcheck disable=SC2016 # the backticks are a markdown code span in the notes, not a command substitution
NOTES=$(printf '%s\nentries: %s\n\nCompiled from the mise registry and the aqua registry (both MIT; license texts embedded in the artifact). Consumers fetch `releases/latest/download/tool-catalog.json`.\n' "$STAMP" "$ENTRIES")
gh release create "$TAG" "$WORK/tool-catalog.json" --repo "$REPO" --title "$TAG" --latest --notes "$NOTES"

# The stable latest URL must now serve THIS release's asset: a pointer that did
# not move is exactly the failure consumers cannot see.
LOCATION=$(curl -sI -o /dev/null -w '%{redirect_url}' "https://github.com/${REPO}/releases/latest/download/tool-catalog.json")
case "$LOCATION" in
  *"/${TAG}/"*) echo "publish: released ${TAG} (${ENTRIES} entries); latest pointer verified" ;;
  *)
    echo "publish: ERROR released ${TAG} but the latest download URL resolves to: ${LOCATION}" >&2
    exit 1
    ;;
esac
