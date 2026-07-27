# Changelog

All notable changes to the reusable workflows and host scripts in this repo.
Consumers must pin an immutable `vX.Y.Z` tag — never `@main`.

## [v1.1.2] - 2026-07-27

### Fixed

- **Staging rsync silently deleted every `docs/` and `tests/` directory in the
  app tree, at any depth.** All three deploy workflows staged the release with
  `--exclude='tests' --exclude='docs'`, intending the two repo-root
  directories. An rsync pattern containing no slash is matched against the
  *basename of every path it walks*, not against the transfer root, so those
  two patterns also dropped `resources/views/docs/`,
  `resources/views/tests/`, `app/**/docs/`, and any other directory that
  happened to share the name. Both are now anchored to the transfer root as
  `--exclude='/tests' --exclude='/docs'`.

  Symptom that surfaced it: paylab's `/docs` route returned 500 with
  `View [docs.index] not found` — `resources/views/docs/` was tracked in git,
  built fine in CI, and was absent from every staged release on the host. Any
  app deployed through this runtime with a view, config, or asset directory
  named `docs` or `tests` below the root was affected, on both the cloud and
  the VPS flavour.

  Affected: `laravel-cloud-deploy.yml`, `laravel-vps-deploy.yml`,
  `vps-deploy.yml`. The staging rsync in each runs from the app root
  (`./ → _artifact/`, under `app/<source_dir>` where the input applies), so a
  leading `/` anchors to the repo root exactly as intended.

  Deliberately left unanchored: `node_modules`, `.git`, `.github`, `.vscode`,
  `.idea`, `.claude`, `.agents`, `.gemini`, `*.log`, `*.sqlite`, `*.map`,
  `.env*` — these are meant to match at any depth. `deploy.sh` already
  anchored its own excludes (`/.htaccess`, `/.env`, `/storage`) and needed no
  change.

  Side effect for callers: released artifacts now also retain `vendor/**/docs`
  and `vendor/**/tests`, so a staged release is slightly larger than on
  v1.1.1. No behaviour change beyond that; no input or secret changes.

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
