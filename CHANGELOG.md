# Changelog

All notable changes to the reusable workflows and host scripts in this repo.
Consumers must pin an immutable `vX.Y.Z` tag — never `@main`.

## [Unreleased]

- **laravel-vps-deploy: the seeded `.env` carries mail placeholders.** A fresh host
  ran with the `log` mailer and nothing said so; password resets and every
  notification email went to `storage/logs`. The template now sets
  `MAIL_MAILER=log` explicitly with commented SMTP keys and a note to fill them
  in before the first real user. Existing hosts keep their `.env` — add the keys
  by hand.
- **laravel-vps-deploy: the console password is no longer printed** into the
  workflow log when `.env` is seeded. Read it from `.env` on the host.

## [v1.4.3] - 2026-09-06

- **laravel-vps-deploy: a deploy no longer wipes the live database.** The host
  rsync ran `--delete --force --delete-excluded` with `.env`, `storage/app`,
  sessions and logs as `--exclude`s. `--delete-excluded` deletes receiver paths
  that match an exclude, so every deploy removed `.env` (then re-seeded it from
  the template, discarding any edits) and, because the artifact never contains
  `*.sqlite`, plain `--delete` removed `database/database.sqlite` too -- every
  deploy of a SQLite app started from an empty database. Found on task-off.com,
  where `migrate:fresh` then failed on a freshly recreated 64 KB file. Those
  paths are now rsync *protect* filters (`P`): never deleted, and never
  overwritten because nothing in the artifact matches them. `--delete` still
  clears stale code. Affects every VPS app on this workflow.

## [v1.4.2] - 2026-09-01

### Fixed

- **The queue-worker health check polls instead of glancing.** The deploy runs
  `queue:restart` moments before the check, so a healthy supervised worker is
  mid-respawn — exited on the signal, back inside ~2 seconds. A single `pgrep`
  landed exactly in that gap on studio-creator (2026-09-01: warning at
  00:57:19.4, between the worker's exit at :18.7 and RUNNING at :20.7) and
  reported a live worker as missing — alarming the deploy log and, where the
  NOPASSWD grant exists, triggering a needless reinstall. The check now polls
  up to 15s (5 × 3s) before calling the worker missing. A host with no worker
  pays those 15 seconds once per deploy; a healthy one answers on the first
  try.

## [v1.4.1] - 2026-08-31

### Fixed

- **`vps-provision.sh --adopt` no longer sweeps `.deploy/` into the snapshot.**
  The adopt path moves every loose top-level entry of the site dir into
  `shared/backups/pre-atomic-<stamp>/` — and `.deploy/` (the host scripts
  `vps-deploy.yml` had uploaded seconds earlier) went with it, so the very next
  step failed with `htdocs/<domain>/.deploy/vps-deploy.sh: No such file or
  directory`. Caught on paylab's first VPS deploy (2026-08-30). Both the
  loose-tree count and the move now exclude `.deploy`. A run that already hit
  this only needs a re-run with `adopt: false` — provisioning is complete and
  the scripts are re-uploaded every run.

## [v1.4.0] - 2026-08-13

### Changed

- **The Cloud Startup smoke test now fails the run on a 5xx.** It previously
  ended in `|| echo "warning: /up smoke failed (TLS or DNS not yet ready)"`,
  which swallowed *every* outcome — connection refused and HTTP 500 alike. A
  site serving a hard error therefore finished the deploy green.

  **Why.** Caught on `dari-jo`'s first deploy: `provision-app.sh` writes an
  `apps/shared/.env` containing nothing but a branding comment, so the freshly
  activated release had no `APP_KEY` and returned 500 on every request. The run
  reported success on all 22 steps. The failure surfaced only because the URL
  was opened by hand afterwards. Any app whose `.env` is unseeded, whose
  `DB_DATABASE` path is wrong, or whose storage tree is unwritable would fail
  the same way, silently.

  **New behaviour**, in order of precedence:

  | Response | Result |
  |---|---|
  | 2xx / 3xx | pass |
  | 404 on `/up` | re-probe `/`, judge that instead (apps with no health route) |
  | 5xx, or any other 4xx | **fail the run**, with the release still activated |
  | connection failure (`000`) | warning only — DNS and TLS genuinely lag a first deploy |

  Each probe is attempted up to 3 times, 10 s apart, so a slow first byte after
  activation does not trip it. The error annotation names the usual causes
  (`APP_KEY`, `DB_DATABASE`, `storage/logs`) so the next person does not have to
  rediscover them.

  Note the release is **activated before** the smoke test, and this change does
  not roll it back — a red run means "live and broken", not "not deployed".

### Added

- **`smoke_strict` input** (boolean, default `true`). Set `false` to keep the
  old warn-only behaviour for a site expected to error immediately after
  activation. An unreachable host stays a warning regardless; this governs only
  responses the server actually produced.

### Upgrade notes

Repin the caller to `@v1.4.0`. No other change is required. Be aware that an
app already deploying onto a broken configuration will now go **red** where it
previously went green — that is the point, but it means the first run after
repinning can fail on a pre-existing fault rather than anything in that release.
Consumers stay on their current tag until they repin, so nothing changes fleet-wide
until each repo opts in.

## [v1.3.1] - 2026-08-05

### Changed

- **Connect-retry now backs off twice: 75 s, then 150 s.** The helper installed
  at `~/.ssh-retry.sh` by all three reusable deploy workflows runs
  attempt → wait 75 s → attempt → wait 150 s → final attempt, ~4.5 min worst
  case, before failing with:

  > `remote connect failed three times across ~4 minutes — treat as host outage, not transient path loss`

  **Why.** v1.3.0's single 75 s backoff was sized on the assumption that a
  window surviving 75 s was no longer transient. It is: after v1.3.0 shipped,
  `dari-platform`'s `publish-extras` job failed its first attempt on three
  consecutive deploys over two days, each losing *both* tries ~75 s apart,
  while a manual re-run 5–10 min later succeeded every time. The Hostinger↔Azure
  blackhole windows have been observed past 105 s and sometimes run several
  minutes, so the second, longer backoff is what actually clears them — and the
  cost is paid only on deploys that would otherwise have failed outright.

  Nothing else changes: the same commands are wrapped, the non-idempotent
  activation steps keep their unretried form behind a retryable `ssh … true`
  gate, and the helper stays POSIX sh. Callers get it by repinning to
  `@v1.3.1`.

## [v1.3.0] - 2026-08-04

### Added

- **Automatic connect-retry on every remote command, 75 s apart.** All three
  reusable deploy workflows (`vps-deploy.yml`, `laravel-cloud-deploy.yml`,
  `laravel-vps-deploy.yml`) now install a small POSIX `retry` helper at
  `~/.ssh-retry.sh` in the "Trust host key" step and wrap the SSH/SCP/rsync
  commands that are safe to run twice. On failure the step waits **75 s**,
  retries **once**, and if that also fails the job dies with:

  > `remote connect failed twice ~75s apart — likely VPS-side outage, not transient path loss`

  **Why.** GitHub-hosted (Azure) runners intermittently blackhole the *first*
  connection to the Hostinger host: `ssh: connect to host … port …: Connection
  timed out`, exit 255, after the 30 s `ConnectTimeout` — while the identical
  job re-run minutes later succeeds. Diagnosed on `dari-platform` on
  2026-08-04: three consecutive deploys failed attempt 1 and passed on retry.
  **fail2ban was ruled out** — no bans recorded at any of the failure times and
  the runner IPs were never jailed (v1.1.1 already removed the `ssh-keyscan`
  that used to earn those bans; do not reintroduce it). This is transient path
  loss between the two networks.

  **Why 75 s and only one retry.** The blackhole windows last *minutes*, so
  back-to-back attempts inside one 30 s `ConnectTimeout` all land in the same
  hole — the reason the previous 3×30 s helper in `dari-platform` did not help.
  A single long backoff clears the common case; a second failure 75 s later is
  no longer "transient" and should page a human rather than burn more runner
  minutes.

  **Retry safety.** Only idempotent commands are wrapped: `mkdir -p` / `chmod`
  over SSH, artifact `scp`/`rsync` uploads, and the provisioning scripts, which
  are idempotent by design and already guarded (`vps-provision.sh` only runs
  when `shared/.env` is absent). The **release-activation** steps — which run
  migrations and flip the `current` symlink — are deliberately **not** retried.
  They instead get a *connectivity gate*: a retryable `ssh … true` immediately
  before, so a blackholed path absorbs the 75 s backoff and the activation
  itself still runs exactly once, on a path already proven open. Atomic-release
  semantics, ordering, and idempotency are unchanged.

  No new inputs, no new secrets, no behaviour change on a healthy path (the
  helper adds one extra authenticated connection before activation). Existing
  callers get it by repinning to `@v1.3.0`.

  Deliberately left unwrapped: the post-deploy **smoke test** and **queue worker
  health check**. Both are advisory — the queue check already swallows failure
  with `|| true`, and the smoke assertion's result is discarded by the step's
  trailing `curl` — so retrying them would only add 75 s to deploys where they
  legitimately report nothing.

### Fixed

- **`deploy.sh`: generate `APP_KEY` when `shared/.env` was seeded without one.**
  `shared/.env` is hand-seeded on first deploy and an empty `APP_KEY` is an easy
  omission: `/up` still returns 200 (it never decrypts), so provisioning looks
  healthy, but the first request touching the encrypted session cookie throws
  `MissingAppKeyException` and every real page 500s — and `config:cache` then
  bakes the empty key in. `deploy.sh` now runs `php artisan key:generate --force`
  in place when `APP_KEY` is missing/empty (idempotent; writes to the shared
  `.env` via the symlink). Host-side script change — consumers do **not** repin;
  the host's `deploy-runtime` clone is pulled and `deploy.sh` re-copied on each
  new app's first-deploy provision.

## [v1.2.1] - 2026-08-02

### Fixed

- **`templates/cloudpanel-vhost-laravel.conf` emitted `{{php_settings}}` bare**
  inside the 8080 server's `location ~ \.php$` block. On current CloudPanel that
  placeholder expands to a raw PHP ini string (e.g.
  `error_log=/home/<user>/logs/php/error.log`), which nginx rejects with
  `[emerg] unknown directive` — the vhost fails its config test and the site
  will not serve. The token is now wrapped as
  `fastcgi_param PHP_VALUE "{{php_settings}}";`, matching CloudPanel's own stock
  vhost. Verified live on `studio.codenzia.com`.

  Template-only change — no workflow behavior changed, so **consumers do not
  need to repin**. The vhost is pasted by hand into CloudPanel; any site created
  from the old template must have that one line corrected in
  **Sites → &lt;site&gt; → Vhost**.

## [v1.2.0] - 2026-07-30

### Added

- **Every deploy now stamps the release with `build.json`.** All three
  reusable deploy workflows (`vps-deploy.yml`, `laravel-cloud-deploy.yml`,
  `laravel-vps-deploy.yml`) write a small JSON manifest into the staged
  artifact immediately before the rsync to the host, so a running release can
  always be traced back to the commit and CI run that produced it:
  `commit`, `commit_short`, `ref`, `branch`, `run_number`, `run_id`,
  `workflow`, `repository`, `target`, `domain`, `deployed_at` (UTC ISO-8601,
  taken from the stamping step). All values are strings.

  Every value comes from the GitHub context — **no new inputs, no new
  secrets, fully backward compatible.** Existing callers get the stamp simply
  by repinning to `@v1.2.0`. `target` is populated from the `target` input on
  `vps-deploy.yml` and is `""` on the two workflows that have no such input.

  The file is written *after* the staging rsync (so no `--exclude` can strip
  it) at the release root — Laravel's `base_path()`, next to `artisan` and
  never under `public/`. It is therefore not web-servable on any of the three
  targets (see README § "Build stamp"), and it carries only public Git/CI
  metadata, never secrets. `deploy.sh` does not exclude it, so it survives the
  local activation rsync on shared hosting.

  Consumed by `codenzia/filament-panel-base` ≥ `v0.6.2`, which reads
  `base_path('build.json')` and shows the deployed build in its Version Info
  widget. Absent file (local dev) or malformed JSON → the widget silently
  omits the row.

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
