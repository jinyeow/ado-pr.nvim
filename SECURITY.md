# Security Policy

## Supported Versions

ado-pr.nvim is pre-1.0 (MVP). Only the latest release/`main` is supported —
please update before reporting an issue.

## Reporting a Vulnerability

If you find a security vulnerability, please **do not open a public issue**.
Instead, report it privately via
[GitHub Security Advisories](https://github.com/jinyeow/ado-pr.nvim/security/advisories/new)
for this repository.

Include:

- A description of the vulnerability and its impact
- Steps to reproduce
- Affected version/commit

You should receive an initial response within a few days. This plugin does
not store or transmit credentials itself — it shells out to the `az` CLI and
relies entirely on `az login` for authentication — but please still report
any issue involving credential handling, command injection, or unsafe
shelling out to external processes.
