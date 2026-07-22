# tool-catalog

[![License](https://img.shields.io/github/license/cplieger/tool-catalog)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/tool-catalog/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/tool-catalog)

> Daily-compiled tool catalog for the [toolbelt](https://github.com/cplieger/toolbelt) engine

A scheduled workflow joins the [mise registry](https://github.com/jdx/mise)
(tool names, descriptions, aliases, preferred install backends) with the
[aqua registry](https://github.com/aquaproj/aqua-registry) (per-package binary
install definitions with checksum sources), compiles them into one
`tool-catalog.json` with toolbelt's `toolcatalog` compiler, verifies that the
engine's required floor of tools resolves for linux amd64 and arm64, and
publishes the result as a dated release.

Consumers fetch the newest artifact from a stable URL:

```text
https://github.com/cplieger/tool-catalog/releases/latest/download/tool-catalog.json
```

The toolbelt engine downloads it at boot and on a schedule (and on demand via
its API), verifies its own required tool set against it, and keeps the last
good catalog on any failure — so a bad registry day degrades to yesterday's
knowledge instead of breaking installs.

## What a release contains

- `tool-catalog.json` — ~700 tool entries: install sources
  (`aqua:`/`npm:`/`pip:`/`cargo:`/`go:`), embedded aqua install definitions,
  descriptions, aliases, dependency and language-server markers, the upstream
  registry refs it was compiled from, both registries' MIT license texts, and
  a generation timestamp.

Each release's notes record the exact registry tags and the commits they
dereferenced to at compile time. Registry tarballs are fetched by commit, so
a moved tag cannot silently change what a run ingested.

The publish run is idempotent: when neither registry has released since the
newest catalog, the run exits without cutting a release.

## Building locally

```sh
TOOLCATALOG_VERSION=v2.1.0 DRY_RUN=1 bash scripts/publish.sh
```

`DRY_RUN=1` compiles and verifies against the latest registry releases and
writes `./tool-catalog.json` without creating a GitHub release. Requires the
`gh` CLI (registry resolution), `curl`, `jq`, and a Go toolchain.

## License

This repository's code is licensed under [GPL-3.0](LICENSE). The published
`tool-catalog.json` embeds data derived from the mise and aqua registries
(both MIT); their copyright and permission notices travel inside the artifact
itself, as MIT requires.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.
