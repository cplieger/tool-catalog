# tool-catalog

[![License](https://img.shields.io/github/license/cplieger/tool-catalog)](LICENSE)

tool-catalog publishes `tool-catalog.json`, a list of about 900 developer tools and how to install each one, for the [toolbelt](https://github.com/cplieger/toolbelt) Go engine. It joins the mise and aqua registries into one file and rebuilds it after each release of either registry. Any program can download the file, and it uses toolbelt's `Catalog` format. The repository is licensed under Apache-2.0.

## What a release contains

Each release holds one file of about 1.1 MB. Consumers fetch the newest one from a stable URL:

```text
https://github.com/cplieger/tool-catalog/releases/latest/download/tool-catalog.json
```

The file holds:

- About 900 tools that run on Linux, each with its mise registry name, description, aliases and one install source: `aqua:`, `release:`, `npm:`, `pip:`, `go:` or `cargo:`. The source is the first one in the tool's mise registry list that toolbelt can install. Tools the registry marks for other systems only are left out.
- For each `aqua:` tool, the aqua registry's install definition. When aqua records it, the definition also says where the tool's release checksums are published.
- The registry tools that have no usable install source, each with the reason, such as a mise `vfox:` plugin or no Linux build.
- The tool each package source needs installed first: `node` for `npm:`, `uv` for `pip:`, `go` for `go:` and `rust` for `cargo:`.
- The registry versions it was compiled from, the MIT license texts of both registries and the time it was compiled.

The format is the `Catalog` type of the toolbelt Go module, documented on [pkg.go.dev](https://pkg.go.dev/github.com/cplieger/toolbelt/v3#Catalog). Each release is compiled by the toolbelt version that `.github/workflows/publish.yaml` pins, so the file matches that version's format. An older toolbelt engine ignores the fields a newer one added. A release carries no signature or separate checksum file.

## Using it with toolbelt

toolbelt's `DefaultCatalogURL` is the URL above. With `Config.Refresh` set, the engine downloads the catalog on its `Interval` and whenever you call `RefreshCatalog`. An `Interval` of zero keeps downloads on demand only. `ParseCatalogRefresh` turns a setting such as `24h` or `off` into that interval, with 24 hours as its default. The engine checks each download, including that it has the tool names you list in `Require`. It saves the download under its config folder and keeps its last good catalog when a download or a check fails. The [toolbelt README](https://github.com/cplieger/toolbelt) shows the setup.

Consider mise's [`registry_floating` setting](https://mise.jdx.dev/configuration/settings.html) if you want mise itself to use the newest registries. It fetches the latest mise and aqua registries and falls back to the copies bundled with your mise release.

## How each release is built

[`registries.env`](registries.env) pins both registries by tag and commit. [Renovate](https://docs.renovatebot.com/) opens a pull request to bump a pin when its registry releases, and each merged bump runs `scripts/publish.sh`. The script runs these steps in order:

- It stops early, publishing nothing, when the newest release already has the same registry commits, toolbelt version and `required-floor.txt`.
- It downloads each registry by commit, so a moved upstream tag cannot change what a run reads.
- It compiles the catalog with toolbelt's `toolcatalog` command, at the toolbelt version the workflow pins as `TOOLCATALOG_VERSION`.
- It checks that every tool in [`required-floor.txt`](required-floor.txt) has install data for Linux on amd64 and arm64. The file lists `go`, `node` and `uv`, which toolbelt needs to install `go:`, `npm:` and `pip:` tools, plus `rust-analyzer` and `gh`.
- It publishes a release tagged with the date, such as `v2026.10.03`, or with the time added for a second release that day, such as `v2026.10.03.1309`. Then it checks that the latest URL points at the new release.

Each release's notes record the registry tags and commits, the toolbelt version, a digest of `required-floor.txt` and the number of tools. If a download, the compile or the floor check fails, nothing is published and the previous release stays the latest. A daily run at 05:17 UTC publishes again when an earlier publish failed and does nothing otherwise.

## Building locally

From the repository root:

```sh
TOOLCATALOG_VERSION=$(sed -n 's/.*TOOLCATALOG_VERSION: //p' .github/workflows/publish.yaml) DRY_RUN=1 bash scripts/publish.sh
```

`TOOLCATALOG_VERSION` is the toolbelt version whose compiler runs, and the command reads the one the workflow pins. `DRY_RUN=1` compiles and checks the pinned registry versions and writes `./tool-catalog.json` without creating a GitHub release. It needs `curl`, `jq`, `tar` and a Go toolchain. The `gh` CLI is needed only for publishing.

## Credits

The tool names, descriptions, aliases and install-source choices come from the [mise registry](https://mise.jdx.dev/registry.html). The install definitions come from the [aqua registry](https://github.com/aquaproj/aqua-registry). Both are MIT-licensed. toolbelt's `toolcatalog` command, by the same author, compiles them into one file.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).

The published `tool-catalog.json` embeds data derived from the mise and aqua registries (both MIT); their copyright and permission notices travel inside the artifact itself, as MIT requires.
