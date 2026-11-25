# Common rules for every long-running session (read fully before starting)

## Session identity (added 2026-10-02)
- Every session has a unique TAG given on the first line of its prompt, in the form `[TAG] short description`,
  for example `[CR5] Core repairs: #N #N #N`. TAGs are never reused: a second instance of the same work
  gets the next number (CR5 → CR6), never the same TAG in two windows.
- Your iTerm window is labelled with your TAG automatically (a Claude Code hook reads it from your prompt). Only if owner says
  the label is missing, run `~/proj/prompts/bin/badge.sh <TAG>`.
- Start EVERY message you write to owner with your TAG in brackets, e.g. `[CR5] Done: ...`.
- Branch names start with your TAG in lower case: `cr5/invitation-atomicity`.
- The last line of every PR body is `Session: <TAG>`. That's how the coordinator maps a PR back to your window.
- Your report goes to `~/proj/prompts/reports/SESSION-<TAG>.md`, one file per TAG. Never write into another TAG's
  report (parallel instances overwrote each other in SESSION-CR.md).
- Your inbox is `~/proj/prompts/inbox/<TAG>.md`.
- The coordinator records every TAG in `~/proj/prompts/SESSIONS.md` (TAG, purpose, PRs, status). Don't edit it.

## Working copy
- Your own fresh clone: `git clone https://github.com/keyorixhq/keyorix.git /tmp/<tag>-$(date +%s)`.
  Never work in ~/proj/keyorix, and never reuse or touch another session's /tmp clone or worktree.
- In zsh, always write `${var}` in refspecs (for example `"refs/heads/${br}:..."`), never `$br:refs` (zsh's `:r` modifier mangles it).
  Use `set -e` in multi-step shell commands so a failure doesn't run the rest in the wrong directory.

## PRs
- (SUPERSEDED 2026-10-16 by 'PR shape' below: ONE PR PER SESSION) Title prefix: fix(security)|fix|feat|test|refactor|ci|docs(scope). A fix(security) PR must include a test.
- Commits are signed off (`-s`, the DCO) under the owner's identity; the owner personally approves gated changes (CI, security-sensitive paths) and releases; other PRs pass an independent agent review and the gates.
- Never merge, enqueue, close or retarget anything. The coordinator reviews and merges.
- STACK, DON'T WAIT: if item N+1 depends on N, branch N+1 from N's branch, open it against main with first body line
  "STACKED ON #N — merge after it", and keep working. When N merges (squash): `git fetch origin && git rebase --onto origin/main <old tip of N>`, then force-push.
  If items are independent, branch each from origin/main. Never poll or sleep waiting for merges.
- Before each push: `gofmt -l .` (excluding operator/) must be empty, and go vet + golangci-lint on touched packages must be clean.
  Run the relevant tests. Paste their tails in the PR body.
- CI WAITING (added 2026-10-17): wait for at most ONE CI round on your PR. Never run `--watch` or a sleep loop longer than
  10 minutes in one shell call; poll in short calls and end your turn between polls. If a check fails on something that
  also fails on main, or on a known flake, say so in the report and finish; the coordinator reruns it. Finish with your
  DONE line as soon as your PR is pushed and its first round is in; do not idle waiting for the merge.
- If a coordinator review comment asks for changes on one of your PRs, fix it before starting anything new.
- Check your session's inbox file (named below) at the start and between items.

## Replacing a PR (added 2026-11-07, after #N/#N)

If your PR replaces an older open PR (fresh branch, squashed history, split), put a line `Supersedes #N` on its own line at the top of the PR body when you open it. The harness then unapproves, holds and dequeues #N, puts it in NEVER-APPROVE and closes it after yours merges. Without that line an old approval can still reach the queue.

## Declaring the defect you fix (added 2026-11-07, after #N/#N)

If your PR fixes a known defect (a tracked finding id or a waiver id), put `Fixes-defect: <id>` on its own line in the PR body. Before starting a fix for such a defect run `grep -i <id> ~/proj/prompts/watchdog/defect-owners.txt`: if another open PR already owns it, work on that PR instead of opening a second one. The harness asks admin when two open PRs declare the same id, or when a merged PR with the same id or the same source files makes an open one obsolete.

## Security
- Never weaken a security default, an oracle or a guard to make something pass. Always fail closed.
- Red-proof: for any guard or fix, show red without the fix and green with it (paste both outputs).
- A real bug found along the way: fix it in its own fix(security) PR with a regression test. Record it in your report so the
  coordinator can add it to the fuzzing catches ledger, then continue.

## Fuzz findings outside your change (added 2026-10-02)
- CI's fuzz-changed explores randomly and can fail your PR on a PRE-EXISTING bug your change didn't cause. First check:
  replay the failing input on origin/main. If main fails the same way, it is not yours.
- Then: file (or find) the GitHub issue, and add an entry to the fuzzer's known-tolerances list scoped as narrowly as
  possible: that one op, that one storage method, that one fault kind, nothing table-wide. The entry names the issue
  (finding doc: "#N") and says "remove when #N is fixed". Put it in its own small commit.
- Never add a tolerance for a failure your own change caused, and never widen an existing tolerance to make CI green.
- The PR that fixes the issue removes its tolerance in the same PR, so the fuzzer guards against regression from then on.

## Definition of done and bug-origin tracking (added 2026-10-03)
- A user-facing change is done only when it has been driven the way a user drives it, against a REAL running server:
  web UI change -> a real-backend Playwright spec (web/e2e/real/); CLI change -> a CLI journey or CLI e2e test;
  API change -> a journey or scripts/e2e coverage entry. Unit tests alone are not done. Paste the run tail in the PR.
- Never build one side of an API contract alone. If you change a request/response shape, update every caller
  (web, CLI, SDK, gRPC) in the same PR, or open the follow-up PRs and link them.
- Every fix PR body carries a "Bug origin" block:
    Introduced-by: <commit/PR that introduced it, from git log -S / blame, or "unknown">
    Detected-by: <fuzzer name | journey | web-e2e | review | CodeQL/semgrep | user/manual | other>
    Class: <atomicity | authz | race | contract-mismatch | input-validation | crypto | stale-test | other>
    Severity: <critical | high | medium | low>
    Guard: <the automated check that stops this CLASS from coming back: a semgrep/go-analysis rule, a fuzz oracle,
            a family-wide test over every sibling route/caller, or a type/API change. Name the file/test. If none is
            feasible, say why; "the regression test for this one instance" alone is not a guard>
  The coordinator uses these to measure whether new-bug creation is falling.
- When your fix touches a race, an error path or an authz decision, re-read your fix once as an attacker/fault-injector
  before pushing: what happens if the next read, retry or concurrent request lands between your two writes?

## Spec first, independent tests, package invariants (added 2026-10-03)
- New features and behaviour changes start with a short spec in the PR body (or docs/specs/<name>.md for anything
  multi-PR): the user journey, the API contract change (OpenAPI diff), acceptance criteria INCLUDING error and
  concurrency cases ("what happens if step 2 of 3 fails", "what if a second request lands in between"). The coordinator
  reviews the spec before you implement when a prompt says "spec-first".
- When the coordinator assigns a separate test-writer session, the user-level tests are written from the spec only,
  without reading your implementation. Your feature is done when those tests pass; don't edit them to make them pass.
  Disagreements go to the coordinator.
- Before changing code in a package, read its INVARIANTS.md (internal/core, internal/storage, internal/encryption,
  server/middleware, server/http, server/grpc, ... as they exist). Your change must keep every invariant listed there.
  If you add or discover an invariant, add it to that file in the same PR. If a change has to break one, stop and ask
  the coordinator.

## Shared-file rule
- The fuzzer's fault-injection list file (its scoped-tables and known-tolerances lists) is a conflict
  hotspot: almost every fuzzer PR edits the same lists. Keep your additions to separate, appended lines with their own
  comment block so a rebase is a clean "keep both".
- scripts/fuzzing/targets.conf and docs/security-closures.tsv: every PR that appends to them conflicts with every other.
  Session C is moving targets.conf to one file per target. Until that merges, add your targets.conf / closures lines
  as the LAST commit of your PR and keep it tiny. The coordinator batches or rebases these.

## Reporting
- Append to your report file after each item: PR number, what changed, verification tails, findings, anything blocked.
- Finish with a table (item | PR | status | notes) and the line "<SESSION> DONE". Then stop.
- QUESTIONS (added 2026-10-17): do not stop the session on a question you can answer from your brief, COMMON-RULES or the
  repo. If one option is clearly the safe/recommended one and it is reversible (e.g. "open a new PR from main because the
  named PR already merged"), take it, say so in your report, and continue. Ask (and wait) only for decisions that are
  irreversible, change security behaviour, or are product decisions; even then first finish every other item you can.
- If you're genuinely blocked on a product decision, write "NEEDS ADMIN: <one-line question + your recommendation>" and move on to the next item.

## Sub-agents (added 2026-09-28 after PR #N)
- Any agent/fork you spawn is READ-ONLY unless your item explicitly says otherwise: no branches, worktrees, commits, pushes
  or PRs, and it must not touch your own clone. Tell it that in its prompt. If it finds a bug, it REPORTS it to you; you
  decide, and a real bug still becomes its own fix PR from YOU, listed in your report.
- (added after Session H's 2nd fork incident) READ-ONLY means NO FILE WRITES AT ALL: not ~/proj/prompts/reports/*,
  not inbox notes, not task lists, not scratch files in any worktree. A fork returns its findings as its final
  message to you; only you write the report. A fork that has been told to stop and keeps acting: stop reading its
  output, do not act on its claims, re-verify with git status / git log / gh pr list, and note it in your report.
- (added 2026-09-28 after 3 fork incidents: H x2, M x1, plus Session I backgrounding itself) DEFAULT = NO FORKS.
  You do the work yourself, in the foreground, single-threaded. Do NOT hand your session's items to a background
  agent, and never spawn an agent to "reinforce" or message another agent. A read-only research agent is allowed
  only when an item explicitly needs a broad search, at most one at a time, and it must be finished before you
  write code. If you notice more than one agent working on your items: stop, list them in your report, keep one.

## Changelog and closures (since #N/#N, 2026-10-11)
- Never edit CHANGELOG.md. Add one fragment per PR under changelog.d/ (see changelog.d/README.md: `<PR-number>-<slug>.md`, a `### <Section>` heading + bullets). When you merge main into an older branch that edited CHANGELOG.md, move that branch's entry into a fragment in the same merge.
- docs/security-closures.tsv is no longer committed (generated from docs/security-closures.d/). Add/edit fragments in docs/security-closures.d/ only; if a merge shows a modify/delete conflict on the TSV, delete it (git rm).


E2E VM shared-resource rule (2026-10-13, after a session wiped another session's demo volume): on the e2e VM always set your own KEYORIX_DEMO_* names (project, volume, image, dir prefixed with your TAG) for scripts/demo/up.sh/down.sh, and never run down.sh --wipe (or docker volume rm / docker image rm) on a default or foreign name. Remove only resources whose names carry your TAG.

- 2026-10-13: NEVER commit changes under .claude/ (a sandbox artifact once deleted an agent definition file in #N). If git status shows .claude/ changes, leave them unstaged; stage files by name. merge-tick refuses PRs touching .claude/.

## PR shape (2026-10-16, owner — CI runner capacity is the bottleneck; this OVERRIDES any "one PR per item/topic/theme" wording in your brief)
- ONE PR PER SESSION, based on main. Every numbered item of your brief is its own commit (or a few commits) on that one branch, with the item number in the commit subject ("item 2: ..."), so review stays per item. Title: "<prefix>(<scope>): <SESSION-TAG> — <short summary>"; the PR body has one section per item.
- Open the PR as soon as item 1 is ready and push each later item to the same branch. Push in batches, not after every commit: CI runs on every push, so push once per finished item at most, and run the relevant tests locally first. One red check blocks the whole bundle, so fix your own CI before you ask for review.
- If the PR gets too big to review (~1500 changed lines excluding generated files/tests), say so in the report; the coordinator decides whether to split.
- (2026-10-15) Based on main. Do NOT stack a PR on another open PR unless the brief explicitly says so.
- If your work truly depends on an open PR, say so in your report and wait: open your PR only after the base has merged (the coordinator will start you then), or ask the coordinator.
- Keep the session's PR in its own area; do not edit files another running session's brief names, unless the brief says so.
- When you must merge main into your branch, use a merge commit (never rebase/force-push), and run go build ./... and go vet ./... before pushing.

## GO BUILD CACHE (2026-10-17)
Never set GOCACHE (no `env GOCACHE=...`, no `.gocache` in the workspace). Use the shared default cache. It is safe for concurrent use by many sessions, and the disk guard only trims entries unused for 12 h. A private cache recompiles every dependency (aws-sdk, go-redis...) from cold, costing minutes of CPU and GBs of SSD writes per session. If you see "go-build/... no such file", re-run the command once; it is an infrastructure blip, not a reason to isolate the cache.

## RAM DISK FOR A STANDALONE RESEARCH/BENCH JOB (2026-10-27, coordinator)
This is NOT the Mac fleet rule above -- don't apply one to the other's situation. The Mac GOCACHE-on-RAM idea was checked twice with real data and rejected both times (the cache regrows about 100GB/day against the Mac's RAM and hits ENOSPC; the Mac is memory-constrained and already swapping at light load, so a RAM-resident tier competes for the exact resource that's short; see our measurement notes). That verdict is specific to the Mac's shared, many-sessions-at-once build cache -- it does not generalize to every disk-heavy job.
A standalone bench/research script (coverage experiments, disk-writes measurement, a one-off fuzz/perf run) on a DIFFERENT host is a different decision, and the right call depends on what's actually true of that host right now, checked, not assumed:
1. **Free RAM right now**, not nominal total (`free -h` / `vm_stat`). If it's already under pressure or swapping, don't add a RAM-resident cache or tmpfs -- that was exactly the Mac's failure mode.
2. **What's backing the disk** (`lsblk -d -o NAME,ROTA,MODEL` or equivalent). A spinning disk under a noisy/heavy job (seen on our bench host) is the case a ramdisk actually helps. An SSD with headroom usually isn't worth the exercise.
3. **Shared cache pool or isolated one-off?** A job that shares a cache with other concurrent sessions should NOT get its own RAM cache (same reasoning as the GO BUILD CACHE rule above -- isolation costs more in cold recompiles than it saves). A standalone script with no other consumers loses nothing by moving its GOCACHE/GOTMPDIR/scratch output to a tmpfs.
4. **Durability.** Ramdisk contents vanish on crash/reboot/container restart. Fine for build cache and scratch coverage profiles; not fine for anything that needs to survive past the run without an explicit copy-out step.
If 1-3 check out for a standalone job on a host with real spare RAM and a real slow/contended disk: `mount -t tmpfs -o size=<N>G tmpfs <dir>`, point `GOCACHE`/`GOTMPDIR` (and `/tmp` if the job writes scratch files there) at it, and prefer a persistent launcher (`systemd-run --collect` or equivalent) over a bare backgrounded shell so the job survives the controlling session disconnecting.

## MESSAGES TO MERGE-MASTER (2026-10-17)
To hand MERGE-MASTER something that should not wait for its next scheduled pass (a PR ready for review after a fix, a decision it must apply), run `mm-say "<one paragraph: PR numbers, what to do>"`. It wakes within 20 s when idle. Use it sparingly: routine reports are already picked up by the digest.

## CUSTOMER JOURNEY PRINCIPLE: ALWAYS GIVE FEEDBACK (owner 2026-10-17)
Any user-facing code you write or change (CLI, server startup/shutdown, installers, scripts, web UI, our own ~/proj/prompts tooling) must never leave the user in silence:
- say what started and what to expect;
- show progress or a heartbeat for anything longer than about 2 s;
- say when it is done and what changed;
- make any wait for input explicit;
- make errors say what to do next;
- log every skip, filter or drop.
Keep stdout clean for --json/--quiet/pipes: progress goes to stderr, or stays off when stdout is not a terminal.

## WHAT TO TEST LOCALLY (owner 2026-10-17: cut rebuilds and SSD wear; the pipeline still covers everything)
- **Compile cost is per package, not per test.** `go test ./internal/core -run TestX` still compiles the whole test package of
  internal/core (414 MB of cache for every changed source state). A `-run` filter saves time, not disk writes.
  While iterating in internal/core, internal/storage, internal/dynamic or server/http, use `go build ./pkg && go vet ./pkg`
  (no test archive) after each edit, and run `go test` once per batch of edits. Use `-count=1` only for Postgres/time/network
  tests: it forces tests to re-run (more Postgres writes), it does not help the compiler.
- **While iterating:** run `go test` only for the packages you are changing.
- **Once, before pushing:** run `go build ./... && go vet ./...`, then `go test $(kaffected)`. `kaffected` prints the packages with changed files plus every package that imports them, in about 2 s. It returns `./...` itself when go.mod/go.sum or internal/testutil changed.
- **Don't run `go test ./...` on the whole repo** unless your brief asks for it. Preflight (build, vet, global guard tests) and CI in the merge queue (full suite, race) run the whole repo for every PR.
- **`-count=1`:** use it only for packages that touch Postgres, time or the network. Elsewhere Go's test cache safely skips unchanged packages.

## LAB HOSTS (2026-10-17)
- Use the e2e VM for container and VM checks through `kssh e2e`. If an older brief says a lab host is reserved for another session, check your inbox: reservations are announced there and lifted there.

## ASKING ADMIN (2026-10-17)
Every question that needs admin's judgement (a decision, an approval, something only the owner can do) is filed with `ask-admin`, not only written in the report. The owner sees it in the ASKS window; blocking asks also raise a notification. One ask per decision:
- `--product` says which product the question is about (default: guessed from your tag; DashDiag sessions pass `dashdiag`). It decides which dashboard tab counts the ask.
- `--blocking` only when a PR or your own work cannot proceed without the answer.
- Reuse the same id when the question already exists (planners: check `python3 ~/proj/prompts/bin/kx-asks.py list` first); a repeat is merged, not duplicated. If it was already answered, the command prints the answer: apply it.
- Then record the id under NEEDS ADMIN in your report and do not wait: carry on with the rest or end your turn. The answer is typed into your session when owner gives it.

## LEFTOVERS SECTION (2026-10-17)
Before the DONE line, every report has a `## LEFTOVERS` section: one line per thing you did not finish and someone must still do, written as an action ("- run X on Linux after the bench frees the VM", "- add the 401 check to TestY after #N merges"). Write "- none" if nothing is left. Only real actions: no status, no "did not touch X". Questions for owner go through ask-admin and appear here as "- ask <id>". The reaper copies this section into the coordinator's backlog (watchdog/LEFTOVERS.md), where every line gets routed.

## MEMORY (2026-10-17)
The Mac's memory is shared by every running session. No test process above 4 GB RSS: split sweeps and fuzz-like loops into small -run pieces and release per-iteration state. Above 6 GB the process is killed automatically and you get a message. Check with `/usr/bin/time -l go test ...` (maximum resident set size).

## CI GATES AND CI SCRIPTS (2026-10-19)
The CodeQL queue gate (scripts/ci/codeql-gate.sh) shipped with tests that used a hand-made baseline and failed ~40 queue entries for 14 h on real data (it ignored alerts dismissed on main). Any change to scripts/ci/**, .github/workflows/** or a script a required check runs:
1. Run the changed script against REAL data before the PR is opened: the live API/SARIF/log the check consumes (read-only `kgh api` GET, or the artifact of the last real run), and paste the real-data result in the PR body ("gate verdict on the last 5 merged PRs: all pass; on the last 5 failed PRs: <which fail and why>").
2. A test that only feeds hand-written fixtures is not enough for a gate. The fixture must be copied from real data (a real SARIF excerpt, a real alert list including dismissed/fixed states).
3. A gate must pass everything that main itself would pass: before adding it, state what the baseline is (open? dismissed? fixed?) and check each against real alerts.
4. Say in the PR body which required checks run the script and what a false failure would block; NEEDS ADMIN if a false failure would block the merge queue.

## HOT WIRING FILES (2026-10-19, from the 7-day collision analysis: 50% of 264 merged PRs overlapped another open PR on a non-ledger file)
- The files below are where every new feature wires itself in. Together they account for about half of all PR collisions:
  server/main.go (71), internal/config/config.go (43), internal/storage/factory.go (28), server/http/handlers/openapi.yaml (27),
  deploy/helm/keyorix/values.yaml (25); next: docs/SELF_HOSTING.md, scripts/demo/check.sh, internal/core/storage/interface.go.
- If your work edits one of them, keep that edit tiny and LOCAL: add your own block/lines as the LAST commit of the PR, never reformat,
  reorder or move existing lines in these files, and do not touch them for cleanups.
- Brief authors (coordinator, planners): put a line "Hot-files: main.go config factory openapi values" (only the tokens that apply) in
  the brief. bin/start-when-slot.sh will not start a session while a running session declares the same token. When planning a batch of
  features, put the ones that need the same wiring file into ONE session (one PR, one commit per item) or a sequence, not parallel sessions.
- Auto-resolved by the coordinator on "merge main": CHANGELOG.md, *.tsv, INVARIANTS.md, routes.json, docs/UPGRADING.md,
  docs/CONFIGURATION.md, scripts/fuzzing/targets.conf and the generated config-surface list (sorted + deduplicated).
  Everything else conflicts for real, so keep your changes out of other sessions' files.
- merge-tick will not enqueue a PR whose files overlap a PR already in the queue (max hold 90 min); expect your PR to wait for the first one.

## PR size and ownership (owner, 2026-10-21: smaller, less colliding PRs)
- One PR = one concern. Target at most ~400 changed lines excluding generated files and tests and at most ~8 files. A bigger change is split into a stack or a series of PRs that each stand alone (green, mergeable, no half-done behaviour); say in the report how you split. The old "~1500 lines" limit is now only the point at which you MUST stop and ask.
- Briefs declare `Paths:` (path prefixes the session edits) next to `Hot-files:`; the starter does not run two sessions with overlapping prefixes. If you discover you must edit outside your declared Paths, put it in LEFTOVERS or ask the coordinator instead of editing it.
- Never regenerate or hand-edit a generated file for a conflict: run the generator on the merged result (openapi.yaml, api-generated.ts, the generated storage fault wrappers, state maps).
- Run the repo-wide static guards locally before every push (kpush now does it for you and refuses on a real failure).


## ADR numbers (2026-10-23)
Never pick "the next free ADR number" yourself. Run `~/proj/prompts/bin/adr-reserve <YOUR-TAG>`: it prints a number that is free on origin/main, in open PRs and in other sessions' reservations, and reserves it for you (the same tag always gets the same number). Four drafts claiming ADR-116 at once cost a renumbering session.

2026-11-15 PUSH PACE (runner contention): every pushed branch starts a full ci.yml run, and 5 to 9 branches pushed within a minute (seen 10:56Z, 11:24Z, 11:50Z) queue behind the merge queue's test legs for 10+ min. When you have several new branches or PRs to publish (a fuzzer wave, a batch of fixes), push at most 2 at a time and wait at least 60 s between pushes; open the PRs the same way. Do not push a branch again just to re-trigger CI, and do not push WIP commits: one push per finished change.

2026-11-15 KEEP YOUR HEAD STABLE (review-pump): every push that changes your PR head, including a plain "Merge origin/main into <branch>" commit, voids the review and approval bound to the old head and costs a full re-review. Do NOT merge main into your branch unless GitHub shows a conflict (mergeable = CONFLICTING) or a coordinator tells you to; the merge queue builds on current main by itself and does not need an up-to-date branch. When you must merge main, do it once, at the end, together with your last real change.

## Logging (LOGGING-STD-1, 2026-11-24, owner)
Every script you create or change (bin/, sbin/, scripts/ci helpers) must log: each decision or action that changes something, with its target (PR/tag/path); skips with the reason; errors. In zsh: `. $HOME/proj/prompts/bin/lib-log.sh` then `klog "..."` / `klog_act "what" "target"` (writes watchdog/<name>.log). Python: append the same line format "<UTC ts> <name>: <msg>" to watchdog/<name>.log. A new script without logging is a review defect. Tests: KLOG_FILE=/dev/null.
