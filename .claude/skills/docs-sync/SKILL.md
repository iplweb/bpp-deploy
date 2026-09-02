---
name: docs-sync
description: Use when changing bpp-deploy behavior (a make target, env var, service, compose file, script, SSL/backup/monitoring flow) or when README, CLAUDE.md, or docs/ feel out of date, duplicated, or too long — keeps the three documentation surfaces consistent and routes each kind of content to its correct home.
---

# docs-sync — keeping README, CLAUDE.md and docs/ in sync

## Overview

`bpp-deploy` has **three documentation surfaces** that drift apart easily because
they overlap. This skill is the single map of *what belongs where* and a checklist
for *which files to touch when something changes*. The goal: one source of truth per
topic, no rot.

The MkDocs site (`docs/`, Material theme, published to GitHub Pages by
`.github/workflows/docs.yml`) is the **canonical home for operational detail**.
README is the front door; CLAUDE.md steers AI agents.

## The three surfaces — what belongs where

| Surface | Audience | Owns (source of truth for…) | Must NOT contain |
|---|---|---|---|
| **README.md** | New operator on GitHub, first 5 minutes | Install (Linux/macOS/Windows), common first-run config, a short "Dokumentacja" pointer into the site, license. Polish. | Deep operational how-tos, architecture internals, troubleshooting catalog, monitoring internals |
| **docs/** (MkDocs) | Operator who already runs BPP and needs a specific procedure — **plus, under `rozwoj/`, whoever edits this repo** | Everything operational + reference: konfiguracja, eksploatacja, monitoring, architektura, rozwiązywanie problemów. **And in `rozwoj/`: the evidence behind repo rules** — measurements, reproductions, rejected alternatives, incident forensics. Polish. | Nothing an agent must know *before* it acts — that's a tripwire, it belongs in CLAUDE.md |
| **CLAUDE.md** | Claude Code / AI agents editing this repo | The **tripwires**: imperative rules, the symptom that identifies each situation, and the anti-fix ("don't solve this by …"). Repo conventions, contracts, file-path pointers. | The *evidence* for those rules — measurements, dates, `Matched Data:` dumps, regression history. Link to `docs/rozwoj/pulapki-*.md` instead |

**Rule of thumb:** if a human running the deployment needs it → `docs/`. If it only
matters while *editing this repo* → `CLAUDE.md`. If it's the first thing a stranger
must do → `README.md`.

## Synchronized pairs (deliberate duplication)

These intentionally exist in two places and **must be edited together**:

- **Install + first-run config**: `README.md` (concise canonical front-door copy)
  ↔ `docs/instalacja/*` (full canonical copy so the site stands alone). Change one,
  change the other. They may differ in *depth*, never in *facts* (commands, paths,
  env var names).

Everything else should live in exactly one place and be **linked** from the others.

## Change → files to touch (checklist)

Make a TodoWrite item per applicable row before you start editing.

| You changed… | Update these |
|---|---|
| A **make target** (added/renamed/removed in `mk/*.mk`) | `docs/eksploatacja/komendy.md` (+ topic page if it's a workflow, e.g. backup/ssl/postgres); README only if it's an install/first-run command |
| An **env var** (name, default, semantics) | The topic page in `docs/` that documents it; `CLAUDE.md` backwards-compat section **if** it's a rename (fallback + init-configs migration are mandatory — see below); README only if first-run-relevant |
| A **service** (added/removed in `docker-compose.*.yml`) | `docs/architektura/uslugi.md`, relevant `docs/monitoring/*` or `docs/architektura/*`; add `logging: *default-logging` to the service (see CLAUDE.md logging note) |
| **SSL** flow (manual/Let's Encrypt) | `docs/konfiguracja/ssl.md`; README first-run SSL snippet (synced pair) |
| **Backup / rclone / restore** | `docs/eksploatacja/backup-i-rclone.md`, `docs/eksploatacja/przenosiny-serwera.md` |
| **PostgreSQL** version/upgrade flow | `docs/konfiguracja/postgresql.md` |
| **Monitoring** (Netdata/Loki/Grafana/Alloy, dashboards, alerts) | `docs/monitoring/*` |
| **Scheduled jobs / nightly restarts** (Ofelia labels) | `docs/architektura/zadania-ofelia.md` |
| **Install prerequisites / OS steps** | `README.md` **and** `docs/instalacja/*` (synced pair) |
| **Resource limits** model | `docs/konfiguracja/limity-zasobow.md` |
| A **production incident** whose cause was non-obvious (dashboards, Alloy pipeline, deploy session, auto-update loop) | The matching `docs/rozwoj/pulapki-*.md` gets the evidence; `CLAUDE.md` gets **at most** rule + symptom + anti-fix, and a link |

## Tripwire vs evidence — the CLAUDE.md split

CLAUDE.md is loaded into **every** session, so every byte is paid for repeatedly.
It grew 3.7× in two months because each fixed incident appended its full
forensics. The split that keeps it useful without letting it swell again:

**Stays in CLAUDE.md** — what must fire *before* an agent touches anything:

- the imperative (*"never change the mount to `/var/lib/postgresql`"*),
- the **symptom**, so the agent recognizes the situation it's in
  (*"every panel shows No data"*, *"`[emerg]` → the whole site fails to start"*),
- the **anti-fix** — the plausible wrong solution to head off
  (*"don't 'fix' this by excluding `932110`"*).

**Moves to `docs/`** — what only matters once you're already investigating:
measurements, dates, `Matched Data:` dumps, rejected alternatives, regression
history, commit ranges.

**A bare link with no symptom does NOT work** — agents read the rule, assume they
understand, and never open the page. The symptom is what makes the link get
clicked. Trimming a rule down to *"details: docs/…"* re-creates the bug the rule
was written for.

Sections that are already a list of imperatives (edge hardening, downtime
contracts, auto-update) are **at their floor** — cutting them further deletes
protection, not prose. Don't cut to hit a size target.

## Invariants you must preserve when documenting

These are facts about the system the docs describe — keep them accurate:

1. **Force-synced configs.** `grafana/provisioning/dashboards/*`,
   `grafana/provisioning/datasources/datasources.yaml.tpl`, `alloy/config.alloy`,
   and — rendered host-side from their `.tpl` — `netdata/netdata.conf` and
   `loki/local-config.yaml` are overwritten on every `make up`/`refresh`. The
   authoritative list is the `copy_always` call sites in
   `scripts/ensure-config-files.sh`, mirrored in CLAUDE.md; check it rather than
   trusting this line. Everything else under the config dir is `copy_if_missing`
   and survives upgrades. Don't tell users to hand-edit force-synced files —
   point them at `.env` knobs.
2. **Backwards compatibility.** A new `bpp-deploy` must run on the **old** `.env`
   with no manual edits. Renames need a reader fallback **and** an `init-configs`
   migration. Any doc that introduces a renamed var must reflect both names.
3. **`make` over raw `docker compose`.** Prefer documenting the `make` target; only
   drop to raw compose when no target exists.

## Building and previewing the site

```bash
pip install -r docs/requirements.txt   # mkdocs-material
mkdocs serve                           # live preview at http://127.0.0.1:8000
mkdocs build --strict                  # fail on broken links / nav (run before committing)
```

`mkdocs build --strict` is the verification gate — a broken internal link or a page
missing from nav fails the build. Run it after any docs edit.

## Workflow

1. Classify the change → use the *what belongs where* table to pick the home.
2. Run the *change → files* checklist; make a todo per file.
3. Edit the **single source of truth**; from other surfaces, **link** rather than copy
   (except the synced install pair).
4. Check the invariants above are still described correctly.
5. `mkdocs build --strict` → fix any broken link/nav.
6. If README's table of contents or "Dokumentacja" links changed, verify they resolve.

## Common mistakes

- **Pasting an operational how-to into README** because it was open. → It belongs in
  `docs/`; put a one-line pointer in README instead.
- **Editing only README's install steps**, leaving `docs/instalacja/` stale (or vice
  versa). → They're a synced pair.
- **Adding a renamed env var to docs** without the backwards-compat fallback +
  migration. → Breaks `git pull && make up` on existing installs.
- **Telling users to edit a force-synced file** (`netdata.conf`, Grafana dashboards).
  → It gets overwritten on next `make up`; document the `.env` knob.
- **Skipping `mkdocs build --strict`** → broken nav/links ship silently.
