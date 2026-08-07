# Contributing to ado-pr.nvim

Thanks for your interest in improving ado-pr.nvim. This is a small,
single-maintainer plugin — issues and PRs are welcome, but please open an
issue before starting significant work so we can align on approach first.

## Development setup

- Neovim 0.10+
- [`stylua`](https://github.com/JohnnyMorganz/StyLua) — formatting
- [`luacheck`](https://github.com/lunarmodules/luacheck) — linting

Clone the repo and point your plugin manager at the local checkout, or run
Neovim with it on `runtimepath` directly.

## Running the test suite

Tests are plain Lua scripts under `tests/`, run headless:

```sh
for f in tests/*.lua; do nvim --headless -l "$f"; done
```

## Formatting and linting

```sh
stylua --check lua/ tests/
luacheck lua/ tests/
```

Run both before opening a PR — CI enforces them (see `.github/workflows/ci.yml`).

## Commit style

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `chore:`, etc.) — `CHANGELOG.md` is generated from commit
history via `cliff.toml`.

## Pull requests

- Keep changes focused and scoped to one concern.
- Add or update tests for behavior changes.
- Update `README.md`/`CHANGELOG.md` if user-facing behavior changes.
- Ensure `stylua`, `luacheck`, and the test suite all pass.

## Reporting issues

Open a [GitHub issue](https://github.com/jinyeow/ado-pr.nvim/issues) with
repro steps, your Neovim version, and relevant `:messages` output. See
[SECURITY.md](SECURITY.md) for reporting vulnerabilities instead.
