# agent-harness: an agent-driven merge pipeline, as a reference extract

This is an extract from the harness one person uses to develop products with AI coding agents. It starts and supervises parallel
Claude Code sessions, reviews their pull requests, feeds a GitHub merge queue and tells the owner only when a human is needed.
It is built and used by one person, and it has run daily on one Mac for about two months.

The products it builds are [Keyorix](https://github.com/keyorixhq/keyorix), an on-premise secrets manager, and DashDiag, a second
product that will use the same harness. The harness merges pull requests into the product repository (`keyorixhq/keyorix`), not into
itself; names such as `kclone`, the Helm chart, the SDK repository and the Postgres test variables belong to the product.

**This is a reference, not a product.** The scripts are extracted from a live system and redacted. They are written for zsh on macOS,
expect `~/proj/prompts` as their home, call each other (some callees are not included) and mention local state files that are not
here. The two tests in `tests/` run offline from the extract (`zsh tests/<name>.test.zsh`, with `$HOME/proj/prompts` pointing at
this tree). Read the code for the design, copy the ideas, do not expect `make install`.

## How the code gets written
The code of the products is written by AI coding agents (Claude Code sessions) under a human owner's direction. The owner decides
what is built and personally approves the changes that matter most (CI and security-sensitive paths, and every release tag). Every
other pull request is reviewed by an independent agent session and checked by automated gates, and nothing reaches `main` without
the merge queue's CI. The harness exists to make that arrangement safe and fast: it keeps agents inside a
sandbox, keeps their work reviewable, and spends the owner's attention only where a human decision is needed.

## What is worth reading
| Idea | Where |
|---|---|
| `kwd` is the choke point for manual and session actions on the queue (hold, dedup, CI-script gate, churn limits). The automatic enqueuers (`merge-tick.sh`, `tick-filler.sh`) apply the same gates through `lib-dispatch.sh`, and an auditor catches any path that skipped them | `sbin/kwd`, `bin/lib-dispatch.sh`, `bin/queue-gate-audit.sh` |
| Sessions run in an OS sandbox that is default-deny, with a few helper tools that leave it; the session README states the design | `sandbox/` |
| A review cascade: a deep review only on a clean head, a fixer session only on CHANGES | `bin/review-pump.sh`, `bin/lib-dispatch.sh` |
| A gate that asks the owner for CI-script changes per exact head, and an auditor that catches any path that bypassed it | `bin/lib-dispatch.sh`, `bin/queue-gate-audit.sh`, `bin/test-enq-gate.sh` |
| A session launcher with caps per model, memory, load and path-overlap gates, and global modes (drain, build, mix) | `bin/start-when-slot.sh`, `bin/lib-mode.sh` |
| Questions to the owner that carry a recommendation, can be blocking or not, and are answered by a policy when it matches | `bin/kx-asks.py` |
| The rules every session reads before it starts | `sessions/COMMON-RULES.md` |
| Rules for new automation: log every action, ship in shadow mode first, measure before and after | `bin/lib-log.sh`, `bin/review-pump.sh` |
| A resource monitor for the Mac (who writes which directory, thermal state) | `tools/resmon/` |

## Lessons the code encodes
- Put a gate where the action happens, not in the caller you happened to look at: a gate placed in one enqueue loop was bypassed by
  two other loops. The fix was to apply the same gate function in every automatic enqueuer, to make `kwd` refuse the same cases for
  manual and session callers, and to add an auditor that checks the queue itself.
- New automation starts in shadow mode (it logs what it would do) and goes live only on an explicit decision, with the shadow
  log as evidence.
- Measure your own monitoring under load: a collector that looked cheap in a 90-second test used over a gigabyte of memory after an hour.

## Known limitations
- Reference extract, not a product: macOS and zsh only, a fixed home directory, no installer, no support.
- The OS sandbox is default-deny for writes and secrets, but the sandbox profiles are not published, and some helper profiles
  (preflight, pre-push) run with `allow default` plus a read deny-list and no network deny. It is a guardrail for cooperative
  agents, not a security boundary against a hostile one.
- The stop gate that blocks a session from ending with unpushed work is log-only by default, fails open on any error, and lets
  go after two blocks.
- Review quality is what an independent agent session gives: it is a second reader, not proof. The owner approves CI and
  security-sensitive changes and every release tag by hand.
- Several scripts predate the logging rule (`lib-log.sh`) and keep their own log lines; some callees, the dashboard and the
  state files are not included.
- Some comments carry dated notes from the live system; names of internal incidents and tags are left in where they explain a rule.

## License
Apache-2.0 (see `LICENSE`). Provided as is, without support.
