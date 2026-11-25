#!/bin/zsh
# tick-filler.sh MODE "<queued PR numbers>" "<HOLD list>"  -- quick filler pass at the start of every merge tick
# (MQ-TICK-FAST-1, 2026-10-24; owner: the queue keeps sitting empty while approved PRs wait).
# If the merge queue has fewer than TICK_FILL_TARGET (default 2) entries, enqueue the OLDEST approved PR (approved.txt
# order) that passes every gate below, until the target is reached. Uses only an EXACT cached preflight PASS for the
# current (head, main, queue) key; it never runs a preflight. Every gate is the main loop's gate or stricter, so the filler
# can only enqueue earlier what the main loop would enqueue; anything unusual is left to the main loop:
#   pinned approval == current head; open, base main, not draft, mergeStateStatus CLEAN, MERGEABLE, no failed / cancelled /
#   pending check; not queued, not HOLD (merge-tick), not FIXING, not NEVER-APPROVE, not a declined head
#   (watchdog/declined-heads.txt); not stacked ("stacked on #"), not the
#   base or top of a stack; no .github/.claude/ADR file; not docs-only (the fast lane takes those); not qfail-held, not
#   head-blocked; global-rule hold (bin/global-rule-hold.sh, DRYRUN: no state written) and, stricter than the main loop, a
#   global, .github or risk-critical PR only into an EMPTY queue and nothing next to a queued one; no non-ledger file shared
#   with a queued PR (the overlap-hold rule without its 90-min release); a live re-read right before the enqueue matches.
# MODE shadow: decide exactly the same way, enqueue nothing, write "WOULD enqueue" lines. MODE on: enqueue.
# Prints the PR numbers it enqueued (on) or would enqueue (shadow), one per line. Off switch: touch TICK-FILLER-OFF.
# Needs the tick snapshot ($KX_TICK_SNAP); without it the filler does nothing.
setopt null_glob extendedglob
mode=${1:?mode}; queued=" ${2:-} "; HOLD=" ${3:-} "
P=$HOME/proj/prompts; R=keyorixhq/keyorix; LOG=$P/merge-tick.log; SL=$P/watchdog/tick-shadow.log
S=${KX_TICK_SNAP:-}; TARGET=${TICK_FILL_TARGET:-2}
. $P/bin/lib-dispatch.sh   # 2026-10-29: $DECLINE_PENDING_REVIEW_PAT (9-site sweep, single source of truth)
ts() { date -u +%H:%MZ; }
say() {   # one line per decision: shadow log in both modes, tick log too in on-mode
  print -r -- "$(date -u +%FT%TZ) filler[$mode]: $*" >> $SL
  [[ $mode == on ]] && print -r -- "$(ts) filler: $*" >> $LOG
  return 0
}
[[ $mode == (on|shadow) ]] || exit 0
[ -f $P/TICK-FILLER-OFF ] && exit 0
[ -n "$S" ] && [ -d $S/prs ] || { say "no snapshot; filler skipped"; exit 0; }
[ -f $P/QUEUE-PAUSED ] && { say "QUEUE-PAUSED (main red): filler skipped"; exit 0; }
LEDGER='(^|/)CHANGELOG\.md$|\.tsv$|(^|/)INVARIANTS\.md$|^scripts/e2e/routes\.json$'   # 2026-11-21 OVERLAP-1: UPGRADING/CONFIGURATION/targets.conf no longer exempt (backtest: they were 550 of the overlap pairs that ended 54% ejected)
SAFE='(\.md$|^docs/|^changelog\.d/)'
CRIT='^(pkg/(core/(auth|audit|session|token)|crypto|storage/migrations?)|server/handlers/(auth|session)|server/admin|migrate/|.*\.sql$|deploy/helm/templates/)'   # example map with invented paths: the real one lists the product's security-critical paths
GRX='^(\.github/workflows/|scripts/ci/[^/]*\.(py|sh|txt|tsv)$|watchdog/global-guards)'
real=${KX_GH_REAL:-gh}
# the same rollup counts merge-tick computes (failed/timed out, cancelled, pending, failed names)
INFOQ='[.state, .mergeable, .baseRefName, (.isDraft|tostring), .headRefOid,
     (.statusCheckRollup | group_by([(.name // .context), (.workflowName // "")]) | map(max_by(.completedAt // .startedAt // ""))) as $cr |
     ([$cr[]|select((.conclusion // .status)=="FAILURE" or .conclusion=="TIMED_OUT")]|length|tostring),
     ([$cr[]|select(.conclusion=="CANCELLED")]|length|tostring),
     ([$cr[]|select((.conclusion // "") == "" and (.state // "") != "SUCCESS")]|length|tostring),
     ([$cr[]|select(.conclusion=="FAILURE")|.name]|join(","))] | join("|")'

# live main + queue (one GraphQL read, never the snapshot: the count and the preflight key must be current).
# Output: "main <oid>" then one "q <number> <headRefOid>" per entry in position order.
liveq() {
  KX_GHS_BYPASS=1 $real api graphql -f query='{repository(owner:"keyorixhq",name:"keyorix"){ref(qualifiedName:"refs/heads/main"){target{oid}} mergeQueue(branch:"main"){entries(first:100){nodes{position pullRequest{number headRefOid}}}}}}' \
    -q '"main \(.data.repository.ref.target.oid)", (.data.repository.mergeQueue.entries.nodes|sort_by(.position)[]|"q \(.pullRequest.number) \(.pullRequest.headRefOid)")' 2>/dev/null
}
files() { jq -r '.files[].path' $S/prs/$1.json 2>/dev/null; }
complete() { [[ $(jq -r ._files_complete $S/prs/$1.json 2>/dev/null) == true ]]; }
alone() {   # must go through the queue alone: a global rule / CI change, .github/ADR, or risk-critical paths
  local f; complete $1 || return 0; f=$(files $1)
  # scripts/ci/guard-inputs.tsv is pure coverage-mapping DATA, not CI logic (same category as docs/review-coverage.d/*.tsv,
  # already exempt below) -- FIXALL-CIDATAGATE-1 2026-10-28, mirrors the same exemption in review-pump.sh/ready-feeder.sh.
  print -r -- "$f" | grep -vE '^scripts/ci/guard-inputs\.tsv$' | grep -qE "$GRX|^(\\.github/|\\.claude/|docs/adr)" && return 0
  print -r -- "$f" | grep -vE '\.md$|INVARIANTS' | grep -qE "$CRIT" && return 0
  grep -q "^$1 critical" $P/watchdog/risk-critical.txt 2>/dev/null && return 0
  return 1
}

lq=$(liveq); main=${${(M)${(f)lq}:#main *}#main }
[[ $main == [0-9a-f](#c40) ]] || { say "cannot read the live queue/main; filler skipped"; exit 0; }
qlines=(${(M)${(f)lq}:#q *})
qnums() { local l x; for l in $qlines; do x=(${(s: :)l}); print -n "${x[2]} "; done; }
n=${#qlines}
(( n >= TARGET )) && exit 0
for ql in $qlines; do
  qn=${${(s: :)ql}[2]}
  alone $qn && { say "queue has #$qn (global/.github/risk-critical: runs alone); nothing added"; exit 0; }
done
maindate=${$(<$S/main.txt)#* }
# every PR some open PR names as its stack base: the main loop handles stacks
bases=" $(jq -r .body $S/prs/*.json 2>/dev/null | grep -oiE 'stacked on #[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ') "
seen=" "
# approved.txt order = approval order (kwd approve rewrites a PR's line at the end); pinned approvals only, last pin wins
for line in ${(f)"$(grep -E '^[0-9]+ [0-9a-f]{40}' $P/approved.txt 2>/dev/null)"}; do
  (( n >= TARGET )) && break
  p=${line%% *}
  [[ $seen == *" $p "* ]] && continue; seen="$seen$p "
  pin=$(grep -E "^$p [0-9a-f]{40}" $P/approved.txt | tail -1 | cut -d' ' -f2)
  j=$S/prs/$p.json; [ -f $j ] || continue
  livq=" $(qnums)"
  [[ $queued == *" $p "* || $livq == *" $p "* ]] && continue
  why=
  info=$(jq -r "$INFOQ" $j 2>/dev/null)
  IFS='|' read -r state mergeable base draft head nfail ncancel npend failnames <<< "$info"
  ms=$(jq -r .mergeStateStatus $j)
  if [[ $HOLD == *" $p "* ]]; then why="on HOLD"
  elif [ -f $P/FIXING ] && grep -qx "$p" $P/FIXING; then why="FIXING"
  elif grep -qE "^$p( |\$)" $P/NEVER-APPROVE.txt 2>/dev/null; then why="NEVER-APPROVE"
  elif ! grep -q "^$p $pin " $P/watchdog/approval-provenance.txt 2>/dev/null; then why="approval has no provenance (no review/owner/clean-merge record for this head)"
  elif [[ $head != $pin ]]; then
    why="approved at ${pin:0:8}, head ${head:0:8}"
    # 2026-10-26 (a PR sat 17 min after a post-approval push before MERGE-MASTER re-reviewed it,
    # because nothing woke it early; the watchdog loop otherwise only re-checks every 20 min / after a 15-min minpass).
    # Ping the MERGE-MASTER inbox once per (PR, head) so it wakes within ~20s instead of waiting out that cycle.
    if [[ $mode == on ]] && ! grep -qx "$p $head" $P/watchdog/.stale-approval-pinged 2>/dev/null; then
      echo "$p $head" >> $P/watchdog/.stale-approval-pinged
      zsh $P/bin/mm-say "re-review #$p: pushed ${head:0:8} after approval at ${pin:0:8} -- please re-review and re-approve" >/dev/null 2>&1
    fi
  elif [[ $state != OPEN || $base != main || $draft != false ]]; then why="state $state, base $base, draft $draft"
  elif [[ $ms != CLEAN || $mergeable != MERGEABLE ]]; then why="merge state $ms/$mergeable"
  elif [[ $nfail != 0 || $ncancel != 0 || $npend != 0 ]]; then why="checks: $nfail failed, $ncancel cancelled, $npend pending"
  # 2026-10-29 (the review-pump/mk-reviews-batch bug plus this one together left a PR stalled all night): MERGE-MASTER's
  # own placeholder line ("waits on independent REVIEW-DEEP") means "a review is still owed", not "declined forever" -- once that
  # review comes back APPROVE, review-pump's harvest adds the (PR, head) to READY-LIST.txt but never goes back and removes the
  # now-stale placeholder line from declined-heads.txt, so without this exclusion the filler keeps blocking it anyway.
  # 2026-11-06: added pat2 (DECLINE_PENDING_REVIEW_PAT2, lib-dispatch.sh) -- same exclusion, for the "new head
  # after fixer round, review pump owns" MERGE-MASTER placeholder (#N), so a real review-owed reminder isn't
  # mislabeled "declined head" here either.
  elif awk -v p=$p -v h=$head -v pat="$DECLINE_PENDING_REVIEW_PAT" -v pat2="$DECLINE_PENDING_REVIEW_PAT2" '$1==p && length($2)>=7 && index(h, substr($2,1,8))==1 && $0 !~ pat && $0 !~ pat2 {f=1} END{exit !f}' $P/watchdog/declined-heads.txt 2>/dev/null; then why="declined head"
  elif jq -r .body $j | grep -qiE 'stacked on #[0-9]+'; then why="stacked PR (main loop)"
  elif [[ $bases == *" $p "* ]]; then why="base of a stack (main loop)"
  elif ! complete $p; then why="more than 100 files (main loop)"
  elif files $p | grep -qE '^(\.github/|\.claude/|docs/adr)'; then why=".github/ADR (main loop, github-approved.txt)"
  # 2026-11-24 CIGATE-FILLER-1 (#N: the filler enqueued a scripts/ci PR with no OK from owner; this loop only knew .github/.claude/ADR, while review-pump's ci_gate_blocks
  # also gates scripts/ci -- the rule "no enqueue without the owner's yes" held in one place only). Same function, same github-approved.txt row, same data-only exemption.
  elif ci_gate_blocks $p $head "$(files $p | paste -sd, -)"; then why="$CI_GATE_WHY (main loop, no OK in github-approved.txt for this head)"
  elif ! files $p | grep -qvE "$SAFE"; then why="docs only (fast lane)"
  fi
  [ -n "$why" ] && { say "skip #$p: $why"; continue; }
  # exact preflight key, built the way bin/preflight.sh builds it: main + q<shasum of the queued "N head" lines minus this PR>
  qj=$(for ql in $qlines; do x=(${(s: :)ql}); [[ ${x[2]} != $p ]] && print -r -- "${x[2]} ${x[3]}"; done)
  qsig=$(print -r -- "$qj" | shasum | cut -c1-10)
  if ! grep -qx "$p $head $main+q$qsig PASS" $P/preflight-cache.txt 2>/dev/null; then say "skip #$p: no exact preflight PASS for ${head:0:8} on ${main:0:8}+q$qsig (main loop)"; continue; fi
  if ! enq_guard $p; then say "skip #$p: a fixer session is working it (enq-guard)"; continue; fi   # 2026-11-16: GH006, see lib-dispatch.sh
  if zsh $P/bin/stack-top.sh $p >/dev/null 2>&1; then say "skip #$p: stack top (main loop)"; continue; fi
  if zsh $P/bin/qfail-held.sh $p </dev/null; then say "skip #$p: qfail-held"; continue; fi
  if hbw=$(zsh $P/bin/head-blocked.sh $p $head $maindate); then say "skip #$p: head-blocked ($hbw)"; continue; fi
  if (( n > 0 )) && alone $p; then say "skip #$p: global/.github/risk-critical, waits for an empty queue"; continue; fi
  if [ ! -f $P/GLOBAL-HOLD-OFF ] && g=$(DRYRUN=1 zsh $P/bin/global-rule-hold.sh $p "$livq"); then say "skip #$p: global-rule hold ($g)"; continue; fi
  mine=$(files $p | grep -vE "$LEDGER" | sort -u); ov=
  for ql in $qlines; do
    x=(${(s: :)ql}); q=${x[2]}
    if [ ! -f $S/prs/$q.json ] || ! complete $q; then ov="#$q (file list unknown)"; break; fi
    o=$(comm -12 <(print -r -- "$mine") <(files $q | grep -vE "$LEDGER" | sort -u) | head -2 | tr '\n' ' ')
    [ -n "$o" ] && { ov="#$q ($o)"; break; }
  done
  [ -n "$ov" ] && { say "skip #$p: shares files with queued $ov"; continue; }
  now=$(KX_GHS_BYPASS=1 $real pr view $p -R $R --json state,mergeable,baseRefName,isDraft,statusCheckRollup,headRefOid -q "$INFOQ" 2>/dev/null)
  if [[ "$now" != "$info" ]]; then say "skip #$p: changed since the snapshot (live: ${now:-unreadable})"; continue; fi
  if [[ $mode == shadow ]]; then
    say "WOULD enqueue #$p at ${head:0:8} (queue $n -> $((n+1)), preflight PASS on ${main:0:8}+q$qsig)"
  else
    # the key above must still be the live one: same main, same queue entries
    lq2=$(liveq); lq2l=(${(M)${(f)lq2}:#q *})
    if [[ ${${(M)${(f)lq2}:#main *}#main } != $main || "${lq2l[*]}" != "${qlines[*]}" ]]; then say "main or the queue moved during the pass; stopping (the main loop continues)"; break; fi
    id=$(jq -r .id $j)
    out=$(KX_GHS_BYPASS=1 $real api graphql -f query="mutation{enqueuePullRequest(input:{pullRequestId:\"$id\"}){mergeQueueEntry{position}}}" -q .data.enqueuePullRequest.mergeQueueEntry.position 2>&1 | tail -1)
    if [[ $out != <-> ]]; then say "enqueue #$p refused: ${out[1,200]}"; continue; fi
    say "enqueue #$p -> $out (queue $n -> $((n+1)), preflight PASS on ${main:0:8}+q$qsig)"
  fi
  qlines+=("q $p $head"); n=$((n+1)); queued="$queued$p "
  print $p
  alone $p && break   # a PR that runs alone gets nothing next to it
done
exit 0
