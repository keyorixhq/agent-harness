# Architecture: from task file to merged PR

```
 owner ──asks/answers──► kx-asks ◄──ask-owner── sessions (sandboxed Claude Code, one per task, own clone, own branch)
   ▲                                                  │ push
   │ dashboard (what needs a human)                   ▼
   │                                          pull request ──► CI
 watchdogs ──► review-pump ──► deep review (Sonnet; Opus confirms on security-critical paths) ──► verdict APPROVE / CHANGES
                    │                                   │ CHANGES: fixer session
                    ▼ APPROVE                           ▼
              merge-tick / ready-feeder ──► (same gates as kwd) ──► GitHub merge queue ──► main
```

## Sessions
`start-when-slot.sh` starts a session only when a slot is free: a cap per model, a total cap, free memory, load average, no overlap
of declared paths with a running session, and the global mode allows it (`drain` starts only review and fix work). Each session gets a
brief (`sessions/SESSION-*.md`), `COMMON-RULES.md`, an OS sandbox (`sandbox/README-session.md` describes the design; default-deny,
with helper tools that leave it), a stop gate (log-only by default) that can block a DONE with unpushed work up to twice, and an
inbox and report file named by its tag.

## Review and merge
1. A PR is reviewed only when its head is clean in CI (`review-pump.sh`), so no review is spent on a head that will change. A
   documented exception lets a BLOCKED head be re-reviewed when it already has a verdict.
2. The review runs as its own session, separate from the author, and ends with a verdict pinned to the exact head SHA.
3. CHANGES starts a fixer session on the same branch; APPROVE records provenance for that head and lets the PR through.
4. `kwd` is the choke point for manual and session actions on the queue: it holds, deduplicates, checks the CI-script gate and the
   churn limits, refuses an enqueue while a deep review is still running, and dequeues. `merge-tick.sh` and `tick-filler.sh` are
   automatic enqueuers; they call the GitHub mutation directly and apply the same gates through `lib-dispatch.sh`
   (`ci_gate_blocks`, the declined-heads check, the fixer guard).
5. Changes to CI scripts and workflows need the owner's approval on the exact head (`ci_gate_blocks` in `lib-dispatch.sh`); data-only
   changes are exempt. `queue-gate-audit.sh` looks at the queue itself and dequeues anything that got in without it.

## Asking a human
Sessions call `ask-owner` with a stable id, the options and a recommendation, and mark the ask blocking or not. Answers go through
`kx-asks.py`; a policy file can answer a class of asks automatically. The dashboard shows only what needs a person, separated from
what is merely slow.

## Conventions
- Scripts log one line per action; new ones use `lib-log.sh` (the rule dates from late in the project, so older scripts still use
  their own log lines).
- New behaviour ships with a mode file (off, shadow, on) and logs what it would do before it is allowed to act.
- Policy lives in small plain files (caps, modes, hold lists) so it can be changed without editing code.
- State and statistics (per-PR wait breakdown, review outcomes, fix rounds) are kept as TSV files; decisions about the pipeline are
  made from those numbers, not from impressions.

## Not included
The dashboard, the stuck-PR doctor, most helper scripts, the sandbox profiles and guards, the product-specific session briefs and
every file of state.
