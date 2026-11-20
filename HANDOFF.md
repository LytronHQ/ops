# Handoff — 2026-10-20

## State
- Latest release: v6.1.0 (2026-10-19). It adds retries to `secrets.sh env` for a
  failed bws read and shows bws's whole error (#93, #94).
- `main` is at `c0a923b`, CI is green. There are no open issues, no open PRs and
  no branches other than `main`.
- Dashboard status file `status/ops.json` is on schema v5. It reports v6.1.0 with
  47 closed issues and has no owner tasks and no next steps. It is valid and was
  written by hand on 2026-10-20.
  `activity` is written by the user timer `projects-dashboard-activity.timer`
  (daily 06:30 UTC) on the container `claude`, not a laptop. Leave that field alone.

## This session
- Only read the rules and kept the status file current. Across the session it
  went from schema v1 to v5 (`links`, `closed_issues`, `activity`), and its
  version and summary followed the releases v5.0.2, v6.0.0 and v6.1.0.
- Deleted the merged remote branch `docs/83-trim-claude-md`.
- No code changes.

## Done at wrap
- #95 / #96: README installs ops-get from v6.1.0, and CLAUDE.md now says the
  README bump happens on every release, even when ops-get is unchanged.
- There is deliberately no "latest" (DECISIONS.md, "Pinned releases, verified,
  and no latest"). README pins a tag and a hash.

## Next
- Nothing is queued. nabz already pins v6.0.0 (`deploy/ops.lock`). Whether nabz
  should move to v6.1.0 is nabz's decision, not ops's.
