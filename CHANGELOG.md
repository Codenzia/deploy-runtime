# Changelog

All notable changes to the reusable workflows and host scripts in this repo.
Consumers must pin an immutable `vX.Y.Z` tag — never `@main`.

## [v1.1.1] - 2026-07-26

### Fixed

- **`vps-deploy.yml`: removed `ssh-keyscan`, the cause of intermittent deploy
  failures.** The VPS runs fail2ban, and a keyscan is a pure pre-auth
  connection that closes without authenticating — exactly the log line the
  `sshd` jail counts. Every deploy therefore accumulated bans against the Azure
  runner IP pool it depends on (jail totals at diagnosis: 81 banned, 499
  failed). A ban DROPs packets, so the failure mode was a silent timeout at
  `ssh-keyscan`'s 5 s default (`-T 5`), intermittent because bans expire and
  each job lands on a different runner IP.

  The host key is now pinned by `StrictHostKeyChecking accept-new` in
  `~/.ssh/config` (plus `ConnectTimeout 30` / `ServerAliveInterval 15`), which
  applies the same trust-on-first-use model on the connection that then
  authenticates — nothing pre-auth remains for the jail to count. No security
  regression, and no behaviour change for callers.

  This is *not* an `sshd MaxStartups` problem: the host was idle (load 0.06)
  with stock `10:30:100` at failure time, and this workflow never overlaps its
  own SSH connections. Do not reintroduce keyscans or add keyscan retries.

  `laravel-vps-deploy.yml` and `laravel-cloud-deploy.yml` already used
  `accept-new` and were unaffected.

## [v1.1.0] and earlier

See `git log` — releases before this changelog was introduced are not
retro-documented.
