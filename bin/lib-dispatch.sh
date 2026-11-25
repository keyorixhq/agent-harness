#!/bin/zsh
# lib-dispatch.sh -- FSM-FIXALL-1 (2026-10-25, owner asked to fix every dead end in the dispatch state machine).
# Sourced by queue-failures.sh, queue-guard.sh, review-pump.sh, fixer-liveness.sh, session-limbo-watch.sh, hold-orphan-watch.sh.
#  fix_tag PR            unique fixer tag MERGE-FIX-AUTO-<PR>-<epoch s> (D9: the old %m%d%H%M tag collided: #N/#N in one minute)
#  brief_new FILE        write stdin to FILE only if it does not exist yet (noclobber), so a collision fails loudly instead of overwriting
#  dispatch_claim PR WHO per-PR dispatch lock (D9), shared by every fixer dispatcher; 0 = you may dispatch. Held while younger than
#                        DISPATCH_LOCK_TTL (1 h) or while the tag bound to it still has a process / start-when waiter.
#                        Off switch: watchdog/DISPATCH-LOCK-OFF.
#  dispatch_bind PR TAG WHO   after a successful dispatch: bind the lock to TAG and count one fixer round (D10)
#  dispatch_release PR   after a failed dispatch: drop the lock so the next pass may try again
#  fix_round_ok PR WHO   D10 round cap: at most FIX_ROUND_CAP (3) fixer dispatches per PR (counted from 2026-10-25 in
#                        watchdog/fix-rounds.txt), then ONE FOR-ADMIN line per (PR, count). Extra rounds: "PR N" in
#                        watchdog/fix-round-extra.txt. Off switch: watchdog/FIX-ROUND-CAP-OFF.
#  decline_class PR SHA  D11: DEFECT | DEFECT-NEEDS-GOAHEAD | WAITS-ON-ADMIN | "" (head not declined). Structured tag first
#                        (watchdog/decline-class.txt "PR SHA CLASS source", written by review-pump harvest from the reviewer's
#                        "DECLINE-CLASS:" line); legacy prose rows fall back to the old words, except that "author" alone now means
#                        DEFECT-NEEDS-GOAHEAD (a real defect parked on the owner's go-ahead) instead of "waits on admin".
#                        "PR" in watchdog/FIX-NEEDS-GOAHEAD.txt keeps every DEFECT of that PR (any head) at DEFECT-NEEDS-GOAHEAD;
#                        "PR" in watchdog/FIX-GOAHEAD.txt (the owner's go-ahead) turns DEFECT-NEEDS-GOAHEAD into DEFECT (fixers allowed).
#  tag_alive TAG         a claude process or a start-when-slot/opus waiter exists for TAG
#  killed_this_dispatch TAG BRIEF   D5: the kill switch killed a process of TAG that started after BRIEF was written (terminal)
#  decline_pending_review LINE   true if LINE is MERGE-MASTER's own "review owed, not declined" placeholder, not a real
#                        decline. 2026-10-29 sweep: 9 independent sites (review-pump.sh, mk-reviews-batch.sh,
#                        tick-filler.sh, merge-tick.sh, ready-feeder.sh, sbin/kwd, ready-prewarm.sh, decline_class
#                        below, fix-round-autogrant.sh's head count) each re-typed this exact string inline after
#                        discovering the same gap one at a time. Single source of truth from here on: every site
#                        that tests for the placeholder reads $DECLINE_PENDING_REVIEW_PAT or calls this function,
#                        so a future wording change (or finding a 10th site) only needs one edit.
: ${P:=$HOME/proj/prompts}; : ${W:=$P/watchdog}
[ -f $P/bin/lib-review-state.sh ] && . $P/bin/lib-review-state.sh   # REVIEW-STATE-1: rs_verdict / rs_should_review / rs_next_tag
DL_DIR=$W/dispatch-locks; DL_TTL=${DISPATCH_LOCK_TTL:-3600}; FIX_ROUND_CAP=${FIX_ROUND_CAP:-3}
DECLINE_PENDING_REVIEW_PAT='independent REVIEW-DEEP'
# 2026-11-05: the plain-substring match above missed MERGE-MASTER's own PR-numbered form
# "independent REVIEW-<N>-DEEP" (no bare "REVIEW-DEEP" substring in it) -- one PR hit this and got a real fixer
# round dispatched against a placeholder that was never a defect, burning a fix-round-autogrant slot for nothing.
# Match both forms.
# 2026-11-06 (a PR stuck ~2.5h): a THIRD MERGE-MASTER placeholder shape,
# written after a fixer round lands a new head ("<PR> <SHA> ... new head after fixer round, review pump owns
# [by:MERGE-MASTER]"), hit the exact same gap: decline_pending_review returned false, decline_class() fell
# through to its DEFECT catch-all, and review-pump looped forever ("start fixer #N" every tick) trying --
# and silently failing, since the round cap was already exhausted -- to dispatch another fixer instead of the
# re-review the new head actually needed. mk-reviews-batch.sh hit the identical block. Match this form too.
# Known residual gap, NOT fixed here (out of scope for this change, left for a follow-up): the two sites that
# bypass this function and filter $DECLINE_PENDING_REVIEW_PAT directly as a raw awk pattern
# (fix-round-autogrant.sh, tick-filler.sh) only got the plain-substring form patched here, same as before
# 2026-11-05 -- they still do not independently exclude the "independent REVIEW-<N>-DEEP" numbered form from
# the line above, unlike this function's second check. Harmless today (nheads counting / filler display text
# only, not a dispatch block), but worth closing in the same pass as this one, not silently left open.
DECLINE_PENDING_REVIEW_PAT2='new head after fixer round, review pump owns'
decline_pending_review() {
  [[ "$1" == *PENDING-REVIEW* ]] && return 0   # 2026-11-21: the explicit marker MERGE-MASTER is told to write (watchdog/PROMPT*.md)
  # 2026-11-21 GATE-RESOLVED-1 (#N sat 40 min after owner's OK: its MERGE-MASTER row "...waits on owner (not in github-approved.txt); reviewed clean" is a wait on a
  # person that the owner's kx-gh-approve resolved, yet it stayed a decline: decline_has_evidence counts "owner"/".github" as human-owned, and mk-reviews-batch's own exemption
  # refuses any row containing "reviewed", so the review never started and the PR never reached READY-LIST. A MERGE-MASTER "waits on owner/admin" row whose exact head is now in
  # github-approved.txt is a resolved wait = review owed. The sha is cut to 40 chars because the row can have text glued to it. Off: touch watchdog/GATE-RESOLVED-OFF.
  if [[ "$1" == *"[by:MERGE-MASTER]"* && "$1" == *("waits on owner"|"waits on admin")* && ! -f ${W:-$HOME/proj/prompts/watchdog}/GATE-RESOLVED-OFF && "$1" != *(CHANGES|BLOCK|[Dd]efect|[Rr]ed |[Ff]ail)* ]]; then
    local _gp=${${(s: :)1}[1]} _gs=${${(s: :)1}[2][1,40]}
    [[ $_gp == <-> && ${#_gs} -eq 40 ]] && grep -qE "^$_gp $_gs( |\$)" ${P:-$HOME/proj/prompts}/github-approved.txt 2>/dev/null && return 0
  fi
  [[ "$1" == *"$DECLINE_PENDING_REVIEW_PAT"* ]] && return 0
  # 2026-11-08: MERGE-MASTER also writes the literal letter form "independent REVIEW-N-DEEP" (a PR whose DEEP-3 APPROVE existed,
  # but the digit-only match above missed it, so ready-feeder skipped the PR for 10+ ticks and `kwd approve` had no provenance).
  # Match any "independent REVIEW-<anything>DEEP" instead of enumerating wordings one at a time.
  [[ "$1" == *"independent REVIEW-"*"DEEP"* ]] && return 0
  [[ "$1" == *"$DECLINE_PENDING_REVIEW_PAT2"* ]] && return 0
  # 2026-11-11 (owner asked why so many sessions were declined): the next wording, "risk-critical, awaits independent DEEP via pump" (#N #N #N),
  # matched nothing above, so it was read as a real decline: kx-top showed 4 PRs as "declined", decline_class gave DEFECT, and review-pump
  # dispatched Opus FIXERS (REVFIX-N-1, REVFIX-N-2) for PRs that only needed a review, while the review itself was skipped. Wording is a
  # losing game, so: any MERGE-MASTER note that mentions DEEP together with await/wait/owed/pending/needs, and carries no defect word
  # (CHANGES / BLOCK / red / fail / defect), is a "review is owed" placeholder.
  if [[ "$1" == *"[by:MERGE-MASTER]"* && "$1" == *DEEP* && "$1" == *([Aa]wait|[Ww]ait|owed|[Pp]ending|[Nn]eeds)* && "$1" != *(CHANGES|BLOCK|[Rr]ed |[Ff]ail|[Dd]efect)* ]]; then return 0; fi
  # 2026-11-21 (owner asked why new sessions did not start): MERGE-MASTER's wording "risk-critical (...), no self-approve, left to (the) review pump" matched nothing above
  # (no DEEP, no wait word), so #N #N #N #N were read as real declines: review-pump never reviewed them (head "declined") and its fixer path
  # was skipped by fixer-precheck (nothing to fix), so the PRs sat un-reviewed for hours while slots were free. A MERGE-MASTER note that says the PR is left to
  # the review pump / risk-critical / no self-approve, with no defect word, is a "review is owed" placeholder.
  if [[ "$1" == *"[by:MERGE-MASTER]"* && "$1" == *"review pump"* && "$1" == *(risk-critical|self-approve)* && "$1" != *(CHANGES|BLOCK|[Rr]ed |[Ff]ail|[Dd]efect)* ]]; then return 0; fi
  # 2026-11-16 (the merge queue sat empty and idle): the wording "risk-critical, waits for review pump [by:MERGE-MASTER]" (#N #N #N, and
  # "... deep review APPROVE-ADVICE ... waits for independent review pump" #N) has no "DEEP" in it, so the 11-11 rule above missed it. The four PRs
  # (all CLEAN, green) sat ~28 h: decline_class said DEFECT, review-pump logged "start fixer" every tick while fixer-precheck skipped ("nothing to
  # fix") and mk-reviews-batch refused ("head already declined"). Any MERGE-MASTER note that says it waits for / awaits the review pump and carries
  # no defect word is a "review is owed" placeholder.
  if [[ "$1" == *"[by:MERGE-MASTER]"* && "$1" == *"review pump"* && "$1" == *([Aa]wait|[Ww]ait)* && "$1" != *(CHANGES|BLOCK|[Rr]ed |[Ff]ail|[Dd]efect)* ]]; then return 0; fi
  # REVIEW-STATE-1 (2026-11-08): wording is a losing game (a new variant every few days). Any MERGE-MASTER note that talks about a review is
  # advisory once an independent review APPROVEd that exact head (ledger: review-outcomes.tsv). Never overrides a review-pump CHANGES line.
  if [[ "$1" == *"[by:MERGE-MASTER]"* && "$1" == *[Rr][Ee][Vv][Ii][Ee][Ww]* ]] && (( $+functions[rs_cleared] )); then
    local _pr=${${(s: :)1}[1]} _sha=${${(s: :)1}[2]}
    [[ $_pr == <-> && ${#_sha} -ge 9 ]] && rs_cleared $_pr $_sha && return 0
  fi
  # 2026-11-21 DECLINE-EVIDENCE-1 (third recurrence of the same bug: 11-11 "awaits independent DEEP", 11-16 "waits for review pump", 11-21 "left to review pump";
  # every time a new MERGE-MASTER wording was read as a real decline). Wording is a losing game, so invert the default: a declined row is REAL only when it has
  # evidence (decline_has_evidence). A row without evidence is a "review is owed" placeholder. Off by default (only logs what it WOULD change to
  # watchdog/decline-evidence.log); on: touch watchdog/DECLINE-EVIDENCE-ON.
  local _w=${W:-$HOME/proj/prompts/watchdog}
  if ! decline_has_evidence "$1"; then
    if [ -f $_w/DECLINE-EVIDENCE-ON ]; then return 0; fi
    local _k="${${(s: :)1}[1]} ${${(s: :)1}[2][1,9]}"
    [[ ${${(s: :)1}[1]} == <-> ]] && ! grep -qxF "$_k" $_w/decline-evidence.seen 2>/dev/null && { echo "$_k" >> $_w/decline-evidence.seen; echo "$(date -u +%FT%TZ) WOULD treat #${_k% *} ${_k#* } as review-owed (no evidence of a defect): ${1[1,200]}" >> $_w/decline-evidence.log; }
  fi
  return 1
}
# decline_has_evidence ROW -- exit 0 when the declined-heads row is backed by something other than a note: a review-pump verdict row, a defect word, a ledger
# verdict other than APPROVE for that exact head (review-outcomes.tsv), a structured DEFECT row (decline-class.txt), or a human-owned reason (admin, owner,
# author, park, hold, gated paths): those wait on a person, not on a review.
decline_has_evidence() {
  local _w=${W:-$HOME/proj/prompts/watchdog} row=$1 pr sha h9
  pr=${${(s: :)row}[1]}; sha=${${(s: :)row}[2]}; h9=${sha[1,9]}
  [[ $pr == <-> && ${#sha} -ge 9 ]] || return 0                      # not a parsable row: leave it alone
  [[ "$row" == *"[by:review-pump]"* ]] && return 0                   # a harvested review verdict
  [[ "$row" == *(CHANGES|BLOCK|DEFECT|[Dd]efect|[Ff]ail|"## Verdict"|" red "|"red,"|".scratch"|CONFLICT|DIRTY|[Cc]onflict|lint|creds|"force-added"|"still carries"|"not pushed"|"head unchanged")* ]] && return 0
  [[ "$row" == *(owner|admin|Admin|author|[Pp]ark|PARK|HOLD|NEVER|".github"|"scripts/ci"|"docs/adr"|ADR|"waits on")* ]] && return 0
  awk -F'\t' -v t="REVIEW-$pr-DEEP-" -v h=$h9 'index($1,t)==1 && $3==h && $4=="DONE" && $5!="APPROVE" {f=1} END{exit !f}' $_w/review-outcomes.tsv 2>/dev/null && return 0
  grep -q "^$pr $sha DEFECT" $_w/decline-class.txt 2>/dev/null && return 0
  return 1
}

fix_tag() {
  local t=MERGE-FIX-AUTO-$1-$(date +%s)
  while [ -e $P/sessions/SESSION-$t.md ]; do sleep 1; t=MERGE-FIX-AUTO-$1-$(date +%s); done
  echo $t
}
# 2026-11-12: an EMPTY brief (the sed/template pipeline failed: #N inbox-liveness left a 0-byte SESSION file, the start was refused, the claim stayed) is no brief:
# write nothing, return 1, so every caller takes its dispatch_release branch.
brief_new() { local _t; _t=$(mktemp /tmp/kx-brief.XXXXXX); cat > $_t; if [ -s $_t ]; then ( set -C; cat $_t > "$1" ) 2>/dev/null; local _rc=$?; rm -f $_t; return $_rc; fi; rm -f $_t; return 1; }

tag_alive() {
  pgrep -f "generated/$1\.json" >/dev/null 2>&1 && return 0
  pgrep -f "start-when-(slot|opus)\.sh $1( |\$)" >/dev/null 2>&1
}

_dl_held() {   # LOCKDIR: 0 = still held; sets DISPATCH_HELD_BY
  local owner otag age
  owner=$(cat $1/owner 2>/dev/null); otag=${${(s: :)owner}[3]}; DISPATCH_HELD_BY="$owner"
  # 2026-10-28 (a PR waited for re-review with no session running at all):
  # this used to be "age < DL_TTL (1h) OR tag_alive" -- i.e. age<DL_TTL short-circuited the check and kept
  # EVERY lock held for a flat hour after ANY dispatch, even one whose bound session finished cleanly in
  # 20 minutes, because tag_alive was never even consulted until the hour was up. Nothing ever releases a
  # lock early on a clean finish (dispatch_release is only called on a FAILED dispatch attempt), so a
  # fixer that converges fast just sits there blocking its own PR's next review for up to 40+ more minutes
  # for no reason. Check liveness FIRST: a dead tag frees the lock almost immediately (120s covers the gap
  # between dispatch_bind writing the owner file and the process actually starting up, not 3600s of it).
  if [ -n "$otag" ] && [ "$otag" != - ]; then
    tag_alive $otag && return 0
    age=$(( $(date +%s) - $(stat -f %m $1 2>/dev/null || echo 0) ))
    (( age < 120 ))
    return $?
  fi
  age=$(( $(date +%s) - $(stat -f %m $1 2>/dev/null || echo 0) ))
  (( age < DL_TTL ))
}
dispatch_claim() {
  local pr=$1 who=$2 d=$DL_DIR/$1.lock rc bm
  [ -f $W/DISPATCH-LOCK-OFF ] && return 0
  mkdir -p $DL_DIR
  if ! mkdir $d 2>/dev/null; then
    _dl_held $d && return 1
    # FIXALL-VERIFY-1 (2026-10-25): breaking a stale lock was "mv $d; mkdir $d", and a breaker that had checked the OLD lock could mv away
    # the NEW one (fixture: 2-5 of 15 concurrent breakers won). Breakers now serialise on $d.break and re-check the lock under it.
    bm=$(stat -f %m $d.break 2>/dev/null) && (( $(date +%s) - bm > 60 )) && rmdir $d.break 2>/dev/null   # a crashed breaker (no stat = no .break: leave it)
    mkdir $d.break 2>/dev/null || return 1
    if [ -d $d ] && _dl_held $d; then rmdir $d.break; return 1; fi
    rm -rf $d; mkdir $d 2>/dev/null; rc=$?
    rmdir $d.break
    (( rc == 0 )) || return 1
  fi
  echo "$who $(date +%s) -" > $d/owner
  return 0
}
dispatch_bind() {
  [ -d $DL_DIR/$1.lock ] && echo "$3 $(date +%s) $2" > $DL_DIR/$1.lock/owner
  echo "$1 $(date +%s) $2 $3" >> $W/fix-rounds.txt
}
dispatch_release() { [ -d $DL_DIR/$1.lock ] && rm -rf $DL_DIR/$1.lock; return 0; }
# enq_guard PR -- 2026-11-16 (owner asked for a guard so this does not repeat): GitHub refuses a push to a branch that is in the merge queue
# (GH006), so enqueueing a PR while a fixer session is still working on it makes the fixer's push fail and its work is stranded in a sandbox clone
# (#N: two Sonnet rounds, "pushed nothing"). Every dispatcher takes dispatch_claim/dispatch_bind, so a live lock = a fixer in flight.
# 0 = fine to enqueue, 1 = a live fixer holds this PR (callers skip it; the next pass retries). Off: touch watchdog/ENQ-FIXER-GUARD-OFF.
enq_guard() {
  [ -f $W/ENQ-FIXER-GUARD-OFF ] && return 0
  DISPATCH_HELD_BY=
  # a session started by hand (mk-fixer.sh without dispatch_claim, like REVFIX-N-1) has no lock: its tag still names the PR, so look for a live one
  local live; live=$(pgrep -fl "(generated/|start-when-(slot|opus)\\.sh )(REVFIX|MERGE-FIX-AUTO)-$1-" 2>/dev/null | grep -oE "(REVFIX|MERGE-FIX-AUTO)-$1-[0-9A-Za-z]+" | head -1)
  if [ -n "$live" ]; then DISPATCH_HELD_BY="by-hand 0 $live"
  else
    [ -d $DL_DIR/$1.lock ] || return 0
    _dl_held $DL_DIR/$1.lock || return 0
  fi
  local k="$1 ${${(s: :)DISPATCH_HELD_BY}[3]}" now=$(date +%s) prev
  prev=$(grep -F "$k " $W/enq-guard-seen.txt 2>/dev/null | tail -1 | awk '{print $NF}')
  if [ -z "$prev" ] || (( now - prev > 1800 )); then
    echo "$k $now" >> $W/enq-guard-seen.txt
    echo "$(date -u +%H:%MZ) enq-guard: #$1 not enqueued, fixer ${${(s: :)DISPATCH_HELD_BY}[3]} is working it (a queued branch cannot be pushed to: GH006)" >> $P/merge-tick.log
  fi
  return 1
}

fix_round_ok() {
  [ -f $W/FIX-ROUND-CAP-OFF ] && return 0
  local n=$1 who=$2 cap extra r now prev prevr prevts
  extra=$(awk -v n=$n '$1==n {s+=$2} END{print s+0}' $W/fix-round-extra.txt 2>/dev/null); cap=$(( FIX_ROUND_CAP + ${extra:-0} ))
  r=$(awk -v n=$n '$1==n' $W/fix-rounds.txt 2>/dev/null | wc -l | tr -d ' ')
  # 2026-11-12 ROUNDS-OPT (G): under the cap, still skip a dispatch that has nothing to do (bin/fixer-precheck.sh; fails open)
  (( r < cap )) && { zsh $P/bin/fixer-precheck.sh $n $who; return $?; }
  now=$(date +%s)
  # FIXALL-CAPNOTIFY-1 (2026-10-28, a gap in the cap mechanism): this used to dedup on "$n $r" alone, a flag
  # written ONCE per (PR, round count) forever. The first capped tick logged it; every tick after that returned 1 with NO log
  # line at all, since the flag already existed -- #N hit the cap at 09:08:59Z and sat silently re-failing every minute
  # for 4+ hours with nobody told after the one-time notice. Re-notify on a 1-hour cooldown instead of once-ever: still quiet
  # between checks (no per-minute spam), but a long-stuck PR keeps resurfacing to FOR-ADMIN.md/merge-tick.log until someone
  # grants extra rounds or looks at it. A fresh round (new $r) always renotifies immediately, same as before.
  prev=$(grep "^$n " $W/fix-round-capped.txt 2>/dev/null | tail -1)
  prevr=${${(s: :)prev}[2]}; prevts=${${(s: :)prev}[3]}
  if [ "$prevr" != "$r" ] || [ -z "$prevts" ] || (( now - prevts >= 3600 )); then
    echo "$n $r $now" >> $W/fix-round-capped.txt
    echo "- $(date -u +%FT%TZ) FIX-ROUND-CAP: #$n has had $r fixer rounds since 2026-10-25 (cap $cap); $who did not dispatch another. Needs your look (watchdog/fix-rounds.txt lists the tags). To allow N more: echo '$n N' >> watchdog/fix-round-extra.txt" >> $W/FOR-ADMIN.md
    echo "$(date -u +%H:%MZ) fix-round-cap: #$n at $r rounds, $who skipped the dispatch" >> $P/merge-tick.log
  fi
  return 1
}

# 2026-11-12: the .github / scripts/ci gate of review-pump as a pure function so it can be regression-tested (bin/test-ci-gate.sh).
# ci_gate_blocks PR SHA FILES(comma list) -> rc 0 = the pump must NOT review yet (reason in CI_GATE_WHY), rc 1 = go ahead.
# A head owner already OK'd (watchdog github-approved.txt via kx-gh-approve, same PR + full SHA) is never blocked: #N #N #N sat 5 h because it was.
# 2026-11-15 (fewer manual gate OKs): a PR whose every file is DATA the CI only reads (the shard weights file and
# changelog fragments) does not need the owner's gate OK; the review itself still runs. List: watchdog/GATE-DATAONLY.txt (one path or
# prefix* per line). Off: touch $P/GATE-DATAONLY-OFF. ci.yml, scripts and anything executable are never on that list.
gate_dataonly() {
  local files=$1 f ok pat
  [ -f $P/GATE-DATAONLY-OFF ] && return 1
  [ -n "$files" ] || return 1
  for f in ${(s:,:)files}; do
    ok=0
    while IFS= read -r pat; do [[ -z "$pat" || "$pat" == \#* ]] && continue; [[ "$f" == ${~pat} ]] && { ok=1; break; }; done < $P/watchdog/GATE-DATAONLY.txt
    (( ok )) || return 1
  done
  return 0
}

ci_gate_blocks() {
  local pr=$1 sha=$2 files=$3 gf=${KX_GHA_FILE:-$P/github-approved.txt}
  grep -q "^$pr $sha " $gf 2>/dev/null && return 1
  gate_dataonly "$files" && return 1
  case ",$files," in
    *,.github/*) CI_GATE_WHY="touches .github/ (waits on admin)"; return 0 ;;
    *,scripts/ci*) [[ ",$files," == *,scripts/ci/guard-inputs.tsv,* ]] || { CI_GATE_WHY="touches scripts/ci (waits on admin)"; return 0; } ;;
  esac
  return 1
}

decline_class() {
  local pr=$1 sha=$2 c dec
  c=$(awk -v p=$pr -v s=$sha '$1==p && $2==s {c=$3} END{print c}' $W/decline-class.txt 2>/dev/null)
  if [ -z "$c" ]; then
    dec=$(grep "^$pr $sha" $W/declined-heads.txt 2>/dev/null | tail -1); [ -z "$dec" ] && return 0
    # 2026-10-29 (coordinator, declined-heads-placeholder sweep, site 8): MERGE-MASTER's own "waits on independent
    # REVIEW-DEEP" note is a request for a review, not a verdict. The fallback below ("else c=DEFECT") matches
    # none of owner/adr/.github/author in that prose, so without this it misclassified a pending-review note as
    # a real defect -- feeding a false DEFECT into every caller (review-pump.sh section E's stuck-held fixer gate,
    # leftover-watch.sh's bodyfix-reconcile, fix-round-autogrant.sh's cap check). Treat it the same as no decline.
    decline_pending_review "$dec" && return 0
    if [[ "$dec" == *"owner"* || "$dec" == *"waits on admin"* || "$dec" == *"adr"* || "$dec" == *".github"* ]]; then c=WAITS-ON-ADMIN
    elif [[ "$dec" == *"author"* ]]; then
      # 2026-11-11 (sessions hung here): MERGE-MASTER writes "...waits on author" for ordinary code
      # defects too (one PR sat 13 h at CHANGES with no fixer, because this branch parked every "author" row on
      # owner's go-ahead). owner decided on 2026-10-25 that the defect bucket auto-dispatches fixers; FIX-NEEDS-GOAHEAD.txt
      # (below) is the explicit per-PR way to keep a go-ahead. So "author" now means DEFECT, except where a fixer cannot help
      # because the AUTHOR must act personally (DCO sign-off / CLA / signature): those stay NEEDS-GOAHEAD (visible in the digest).
      if [[ "$dec" == *[Ss]ign-off* || "$dec" == *[Ss]ignoff* || "$dec" == *DCO* || "$dec" == *dco-check* || "$dec" == *CLA* ]]; then c=DEFECT-NEEDS-GOAHEAD; else c=DEFECT; fi
    else c=DEFECT; fi
  fi
  # PRs owner wants to clear personally (watchdog/FIX-NEEDS-GOAHEAD.txt, any head) never get an automatic fixer without the owner's go-ahead
  [ "$c" = DEFECT ] && grep -Eq "^$pr( |\$)" $W/FIX-NEEDS-GOAHEAD.txt 2>/dev/null && c=DEFECT-NEEDS-GOAHEAD
  [ "$c" = DEFECT-NEEDS-GOAHEAD ] && grep -Eq "^$pr( |\$)" $W/FIX-GOAHEAD.txt 2>/dev/null && c=DEFECT
  echo $c
}

#  decline_source PR SHA   FSM-FIXALL-2 (2026-11-05, dedup-by-verdict fix): the "source" field of the matching
#                        watchdog/decline-class.txt row (the REVIEW-<PR>-DEEP-<k> tag that produced this verdict),
#                        or empty if this (PR,SHA) has no structured row (legacy prose-only declined-heads.txt).
#                        review-pump.sh's section D/E fixer dedup used to key watchdog/fix-started.txt on (PR,SHA)
#                        alone, so once ANY fixer was dispatched at a head it silently blocked EVERY later fixer at
#                        that same head forever -- including one needed for a brand-new, distinct DEFECT verdict a
#                        later re-review found on the SAME head (confirmed 3x in one night: #N 02:45Z/03:41Z,
#                        #N 05:42Z). Callers now key fix-started.txt on (PR,SHA,source) instead, so a new verdict
#                        (new source tag) is never shadowed by an old one; the ambiguous legacy case (no source,
#                        prose-only decline) keeps the old blanket-block behaviour via the "NOSRC" fallback both
#                        call sites use, since there is no signal there to tell two verdicts apart.
decline_source() {
  local pr=$1 sha=$2
  awk -v p=$pr -v s=$sha '$1==p && $2==s {c=$4} END{print c}' $W/decline-class.txt 2>/dev/null
}

killed_this_dispatch() {   # session-killed.txt rows: "TAG <proc start epoch> <kill epoch>" (legacy rows: "TAG" = terminal)
  local tag=$1 bm row st; local -a f
  bm=$(stat -f %m "$2" 2>/dev/null || echo 0)
  while read -r row; do
    f=(${=row}); st=${f[2]}   # FIXALL-VERIFY-1: was ${${(s: :)row}[2]}, which on a one-word legacy row is its 2nd CHARACTER, so legacy rows were not terminal
    [ -z "$st" ] && return 0
    (( st + 120 >= bm )) && return 0   # 2 min slack: the brief is written just before its process starts
  done < <(grep -E "^$tag( |\$)" $W/session-killed.txt 2>/dev/null)
  return 1
}
