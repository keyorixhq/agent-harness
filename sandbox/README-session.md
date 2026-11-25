# You are a SANDBOXED session (read this first; it overrides COMMON-RULES where they differ)

Every session runs inside an OS-level sandbox on the owner's Mac. Routine shell commands are approved
automatically, and the sandbox cannot be escaped, so do not try to work around a refusal: report it instead.
The design is default-deny: a session can read and write its own workspace and reach the network only as far as
its task needs. Everything else goes through a small set of helper tools that run outside the sandbox and
enforce their own rules.

## Where you work
- Your workspace is your current directory, `~/proj/work/<TAG>`. Clone the product with `kclone [repo] [name]`
  from there (a plain `git clone` does not work inside the sandbox). Branch, commit, fetch, rebase and
  cherry-pick work normally. For a second PR, make a second clone rather than a second worktree.
- You write to your workspace, your own report `~/proj/prompts/reports/SESSION-<TAG>.md` and the build caches.
  Everything else is read-only. Use `$TMPDIR` or your workspace for temporary files.

## The helper tools that leave the sandbox
- `kclone` clones one of the project's own repositories into your workspace.
- `kgh ...` is `gh` for the product repository, restricted to a subset of GitHub operations (reading PRs and
  runs, creating a PR, commenting). Anything that changes merge state (merge, close, label, retarget, review)
  belongs to the coordinator.
- `kpush <branch> [--force-with-lease]` pushes HEAD of the repo you are in, never main. **It is slow, not hung:
  it takes 1-6 minutes** (sign-off check, guards, lint, content gate, then the push) and prints a phase line
  every 20 s. Run it as a standalone command with a long tool timeout and never start a second one in parallel.
  If the call returns without "kpush: pushing" and without a REFUSED line, it timed out: run
  `git ls-remote origin <branch>` to see whether the push landed, and if not, write NEEDS COORDINATOR with the
  commit sha.
- `kpg dsn <db>` creates a Postgres database for you and prints its DSN. Name it after your tag and drop it with
  `kpg drop <db>` when you finish. Postgres tests in different packages collide on one database: use one
  database per package, or run the Postgres-backed packages with `go test -p 1 -parallel 1`.
- `kssh <host> <command>` / `kssh --cp <src> <dst>` reach the lab hosts. If it refuses because a benchmark is
  running, do other work and retry later; never work around it.
- `mm-say`, `ask-admin`, `kwd`: talk to the coordinator, file a question for the owner, record merge-queue
  actions (see COMMON-RULES.md).

**Run each of these as a command of its own.** A pipe, a redirect, `cd ... &&` or `$(...)` around them keeps
the call inside the sandbox, where they cannot read their credentials and fail. Do `cd` in a separate command
first, and read the whole output (or use `--json` with `-q`) instead of piping it.

## If something is blocked
A blocked write shows `Operation not permitted`; a blocked host names the host. If your task truly needs it,
write the exact need in your report under "Needs coordinator" and carry on with the rest.

## Where heavy things run
- Unit and integration tests, `go test`, `make` targets that do not need containers, linters, `helm
  template/lint`, JS installs and tests: run them in the sandbox. If one fails there, report the exact error;
  do not install a workaround tree.
- Container-based end-to-end runs, `kind`/Kubernetes and browser tests against a real server do not run on the
  Mac. Run them on the lab VM with `kssh`, in your own directory, name containers and clusters with your tag,
  and clean up what you created (and only that). If the VM cannot do it, rely on CI's end-to-end jobs and say so.
- Benchmarks and long fuzz runs belong on the lab host, respecting its bench lock.
- Tests that need the internet fail here by design: note them, do not work around it.

## Fewer PRs
The open-PR count is the bottleneck. Put review fixes and closely related changes on an EXISTING open PR (yours
or the one your task names) instead of opening a new one; open a new PR only for an independent change. One PR
may close several related issues.

## Changelog and closures
- Never edit CHANGELOG.md. Add one fragment per PR under changelog.d/ (see changelog.d/README.md:
  `<PR-number>-<slug>.md`, a `### <Section>` heading and bullets). When you merge main into an older branch that
  edited CHANGELOG.md, move that branch's entry into a fragment in the same merge.
- The security-closures table is generated from docs/security-closures.d/. Add or edit fragments there only; if
  a merge shows a modify/delete conflict on the generated file, delete it.

## Benchmark and measurement raw data
- Raw measurement data (per-cell TSV/CSV, logs, profiles, configs) is never left only on a bench host or in a
  scratch dir. Before you finish, archive it, copy it into your workspace, verify the SHA-256 on both sides and
  write a MANIFEST.sha256 next to it. Say the path in your report.
- Written result tables are not a substitute: the cell-level files must be recoverable.
- Never delete raw data on a bench host. Cleanup of images, databases and containers is fine; raw data is
  removed only by the coordinator after the copy is verified.

## Environment tools
- First thing: `~/.claude/scripts/agent-preflight.sh`. On a BLOCKER, stop and say so in your report instead of
  discovering it mid-run.
- Go tests: `~/.claude/scripts/gotest.sh <args>`. It keeps output in `.scratch/` and prints only failures. Never
  stream full `go test ./...` output.
- Background servers and daemons only through `~/.claude/scripts/spawn.sh --name <n> --ttl <secs> -- <cmd>`
  (it self-terminates after the TTL). Run `~/.claude/scripts/reap.sh` before you finish.
- Checkpoint after each milestone with `~/.claude/scripts/ckpt.sh "<phase>" "<next action>"`; on start read
  `.scratch/CHECKPOINT.md` first and resume. Wrap long runs in `caffeinate -i`.
- Log lines for the overnight log: `mm-log "<line>"`.
- Review and diagnose against `git fetch origin` + `origin/main`, not a stale checkout. New test doubles must not
  embed the whole storage interface. Security fixes need red/green proof. Approvals need test evidence at the
  reviewed SHA; security-sensitive reviews go to the stronger model only.
- Red/green proof for a fix: do not edit production code to make a test fail. Run
  `~/.claude/scripts/redproof.sh <base-ref> <package> '<TestRegex>' <new test files>`: it runs the new tests
  against the pre-fix commit (red) and at HEAD (green) in a scratch export, with no edit to your tree. Put its
  output in the report.
- Common avoidable errors: your shell may start in the workspace, not the clone (`cd` into the clone before
  git/go); a missing file is usually the wrong directory (check `pwd`); `kgh pr checks` exits non-zero while
  checks are pending, which is not a failure; for queue state use `kwd status`.

## Scratch space and the tree you test
- Your Go work directory (`GOTMPDIR`) is your own subdirectory on a RAM disk shared by all sessions; it is
  removed when your session exits. Never write into another session's directory.
- Run ONE heavy test package at a time (anything Postgres-backed, the core and storage packages): packages in
  parallel once filled the RAM disk and every session's tests failed with "no space left on device". Before a
  broad run check the RAM disk usage; above about 85%, put the Go work directory on the SSD inside your
  workspace instead of waiting. New sessions do not start while the RAM disk is above that mark.
- Before you collect test evidence (red/green proofs, review verdicts, PR test tails), run `ktree
  <expected-sha-or-ref>` in your clone: it prints the clone, branch and HEAD sha and refuses a tree without
  .git, a clone outside your workspace, modified tracked files, or a HEAD that is not the reviewed commit.
  `gotest.sh` prints `tree=<sha>` on its summary line: paste it with the result. Results from a leftover export
  or an old clone do not count; if you are unsure what a directory is, make a fresh `kclone`.
- Put throwaway exports and copies in `<workspace>/tmp/`; the coordinator's cleanup removes it after your report
  ends with `<TAG> DONE`. Do not work around a refused delete; leave it there.
- ADR numbers: run `adr-reserve <YOUR-TAG>` as a standalone command. It prints a number only after it recorded
  the reservation; on an error nothing is reserved, so retry later and never pick a number yourself.
