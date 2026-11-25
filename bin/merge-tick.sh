#!/bin/zsh
# merge-tick.sh -- one deterministic merge-queue pass (no judgment involved).
#  1. enqueues every APPROVED (listed in approved.txt) open PR that is green,
#     mergeable, targets main, and is not already queued / on the hold list
#  2. re-runs CANCELLED jobs of approved PRs (runner contention, not real failures)
#  2b. merges approved docs/tests-only PRs directly (bin/fastlane.sh, kill switch FASTLANE-OFF)
#  3. writes PRs that need a human/LLM look to ~/proj/prompts/needs-attention.md
# Safe to run any time; idempotent. Log: ~/proj/prompts/merge-tick.log
setopt null_glob
R=keyorixhq/keyorix
P=~/proj/prompts
# DISK-WRITES-2 F1 (2026-10-18): one flag set for every Go process, so cache keys are shared; refill/auto-merge inherit it
. $HOME/proj/prompts/bin/go-flags.sh && export GOFLAGS="$KX_GOFLAGS"
. $HOME/proj/prompts/bin/lib-dispatch.sh   # 2026-10-29: decline_pending_review() (9-site sweep, single source of truth)
[ ! -f $HOME/proj/prompts/RAMDISK-OFF ] && [ -d /Volumes/RAMDISK/gotmp ] && [ "$(df -m /Volumes/RAMDISK | awk 'NR==2{print $4}')" -gt 1500 ] && export GOTMPDIR=/Volumes/RAMDISK/gotmp
export PATH="$HOME/proj/prompts/sbin-go:$PATH"   # 2026-10-18: go wrapper sends linker temp files to the RAM disk (sbin/go)
HOLD=" "       # PR numbers that are never auto-enqueued; edited only by `kwd hold` / `kwd unhold`, pruned daily by hold-prune.sh
LOG=$P/merge-tick.log
ATT=$P/needs-attention.md
ts() { date -u +%H:%MZ; }
# MQ-ORPHAN-1 (2026-11-22): cancel merge_group runs whose queue ref is gone (dry-run until watchdog/MQ-CANCEL-ORPHANS-LIVE exists; off: MQ-CANCEL-ORPHANS-OFF)
[ -f $P/bin/mq-cancel-orphans.sh ] && (zsh $P/bin/mq-cancel-orphans.sh </dev/null >/dev/null 2>&1 &)
# 2026-10-24 MQ-TICK-FAST-1 (owner: the queue sits empty because a tick runs 20-25 min). Mode file TICK-FAST-MODE holds
# "shadow" or "on"; a missing file, any other value or TICK-FAST-OFF = off = this tick exactly as before.
#  shadow: the old tick decides and acts; the new parts only log what they would do (watchdog/tick-shadow.log, compare with
#          bin/tick-shadow-compare.py), and the gh shim checks its snapshot answers against the real ones.
#  on:     one batched GraphQL snapshot serves the per-PR gh reads (bin/tick-snapshot.py, bin/ghs/gh); a filler pass keeps
#          2 entries queued (bin/tick-filler.sh); preflights run in the background (bin/pf-bg.sh) and the tick only reads
#          their verdicts; every enqueue re-reads the PR live first; the PR loop is time-boxed (TICK-BUDGET seconds, 300).
# Both modes write one timing line per tick to watchdog/tick-phases.log.
zmodload zsh/datetime 2>/dev/null
TF=off; [ -f $P/TICK-FAST-OFF ] || TF=$(head -1 $P/TICK-FAST-MODE 2>/dev/null); [[ "$TF" == (shadow|on) ]] || TF=off
T0=$EPOCHSECONDS; TFL=$T0; TFPH=""; TFBG=(); TFPATH0=""; TFREQ=0; TFREQS=""; TFN=(); TFSL=$P/watchdog/tick-shadow.log
TFBUDGET=$(head -1 $P/TICK-BUDGET 2>/dev/null); [[ "$TFBUDGET" == <-> ]] || TFBUDGET=300
tf_ph() { [ $TF = off ] && return 0; TFPH="$TFPH $1=$((EPOCHSECONDS-TFL))s"; TFL=$EPOCHSECONDS; }
tf_sh() { print -r -- "$(date -u +%FT%TZ) $*" >> $TFSL; }
# OVERLAP-1 (2026-11-21): same rule as ready-feeder -- do not enqueue a PR that shares a changed file with an entry already queued (that pair ends UNMERGEABLE; backtest: 54% ejection vs 31%). Fail-open; off: touch OVERLAP-OFF.
ovl_guard() { local o; o=$(zsh $P/bin/q-overlap.sh $1 2>/dev/null); [ -z "$o" ] && return 0; echo "$(ts) skip #$1: shares ${o#*:} with queued #${o%%:*} (OVERLAP-1)" >> $LOG; return 1; }
# 2026-10-22: one tick at a time. queue-empty-kick (60 s) and launchd started overlapping ticks that each ran the same
# 10-15 min preflight, doubling the load on the laptop and delaying every enqueue. A lock older than 25 min is stale.
KXTLOCK=/tmp/kx-merge-tick.lock
if ! mkdir $KXTLOCK 2>/dev/null; then
  lage=$(( $(date +%s) - $(stat -f %m $KXTLOCK 2>/dev/null || echo 0) ))
  if (( lage < 1500 )); then echo "$(ts) tick skipped: another tick is running (${lage}s)" >> $LOG; exit 0; fi
  rmdir $KXTLOCK 2>/dev/null; mkdir $KXTLOCK 2>/dev/null
fi
trap 'rmdir $KXTLOCK 2>/dev/null' EXIT
echo "== $(ts) tick" >> $LOG
(nohup zsh $P/bin/main-canary.sh >/dev/null 2>&1 &)   # 2026-10-23 main canary (own lock, runs only when main moved)
(nohup zsh $P/bin/approved-prune.sh >/dev/null 2>&1 &)   # 2026-10-28 keep approved.txt/github-approved.txt current (own lock, own hourly gate)
(nohup python3 $P/bin/asks-triage.py >/dev/null 2>&1 &)   # 2026-10-28 archive asks whose referenced PR(s) already merged/closed (own hourly gate via asks-triage.stamp below)
zsh $P/bin/fix-round-autogrant.sh   # 2026-10-28 auto-grant +1 fixer round for a capped DEFECT-class PR making real progress (own 2-min gate); foreground so review-pump/queue-guard see it THIS tick
[ $TF != off ] && tf_sh "== tick mode=$TF pid=$$"

# Disk guard (2026-10-06): parallel sessions regrow the Go build cache to ~100 GB
# a day and fill the disk. Under 40 GB free, clear it (safe, it's only a cache)
# and notify once.
freeg=$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')
# 2026-10-17: trim instead of wiping. Go refreshes a cache entry's mtime when it uses it, so deleting entries
# untouched for 12 h keeps the hot set and running builds intact (a full wipe broke a running preflight).
# Full `go clean -cache` only as a last resort under 15 GB free.
if [ -n "$freeg" ] && [ "$freeg" -lt 60 ] && ! pgrep -f "go-build -type f -mmin" >/dev/null; then
  GC=$(go env GOCACHE 2>/dev/null); [ -d "$GC" ] && (nohup find "$GC" -type f -mmin +720 -delete >/dev/null 2>&1 &)
  echo "$(ts) DISK: ${freeg}G free -> trimming Go build cache entries unused for 12 h" >> $LOG
fi
if [ -n "$freeg" ] && [ "$freeg" -lt 15 ]; then
  (nohup go clean -cache >/dev/null 2>&1 &)
  echo "$(ts) DISK: ${freeg}G free -> go clean -cache (last resort)" >> $LOG
  osascript -e "display notification \"Disk ${freeg} GB free: clearing the Go build cache\" with title \"Keyorix merge-tick\"" >/dev/null 2>&1
fi

tf_ph prep

# queue snapshot
queued=" $(gh api graphql -f query='{repository(owner:"keyorixhq",name:"keyorix"){mergeQueue(branch:"main"){entries(first:100){nodes{pullRequest{number}}}}}}' -q '.data.repository.mergeQueue.entries.nodes[].pullRequest.number' | tr '\n' ' ') "
# 2026-10-11 stack cleanup: a queued PR whose STACKED ON base is open but no longer queued (base failed/was
# dequeued/held) must leave the queue too, or it would merge the base's code under its own PR.
for qp in ${=queued}; do
  zsh $P/bin/stack-top.sh $qp >/dev/null 2>&1 && continue   # 2026-10-15: top of a fully approved stack carries its bases
  for sb in $(gh pr view $qp -R $R --json body -q .body 2>/dev/null | grep -oiE 'stacked on #[0-9]+' | grep -oE '[0-9]+'); do
    [ "$sb" = "$qp" ] && continue   # a body may mention its own number ("#N STACKED ON #N" lists)
    if [ "$(gh pr view $sb -R $R --json state -q .state 2>/dev/null)" = OPEN ] && [[ "$queued" != *" $sb "* ]]; then
      $P/sbin/kwd dequeue $qp >/dev/null 2>&1; echo "$(ts) dequeued #$qp: its base #$sb left the queue unmerged" >> $LOG
      echo "- #$qp: dequeued, base #$sb left the queue unmerged" >> /tmp/mt-att.txt; queued=${queued/ $qp / }
    fi
  done
done
# 2026-10-16 (owner: queue drained extremely slowly): an UNMERGEABLE queue entry (conflict with main after an
# earlier group merged) stalls everything behind it. Take it out and let auto-merge-main.sh merge main into it
# (mechanical ledger conflicts only; a code conflict is reported for a session). clean-merge-reapprove re-queues it.
for un in $(gh api graphql -f query='{repository(owner:"keyorixhq",name:"keyorix"){mergeQueue(branch:"main"){entries(first:100){nodes{state pullRequest{number}}}}}}' -q '.data.repository.mergeQueue.entries.nodes[]|select(.state=="UNMERGEABLE")|.pullRequest.number' 2>/dev/null); do
  $P/bin/unmergeable-forensics.sh $un >/dev/null 2>&1   # 2026-10-19: log why before dequeuing (watchdog/unmergeable-forensics.tsv)
  # 2026-10-23: an entry whose merge-group build has FAILED CHECKS is not conflicting: merging main into it only starts another
  # doomed build (a red web smoke test on main caused 111 such cycles). Dequeue it and HOLD it at this head sha (bin/qfail-held.sh).
  _cls=$(zsh $P/bin/queue-fail-classify.sh $un)
  # 2026-10-23 MQ-BLAME-FIRST-ENTRY-1: merge groups are cumulative; if every failed check also failed on an entry AHEAD of this one,
  # the failure belongs to that first entry. Dequeue this one without blaming or holding it; it is re-enqueued when the first
  # entry is out of the way (tests/qfc-test.sh).
  if [[ "$_cls" == COLLATERAL* ]]; then
    $P/sbin/kwd dequeue $un >/dev/null 2>&1; echo "$(ts) dequeued #$un: COLLATERAL of ${_cls##* } (${_cls#COLLATERAL }) -> NOT held" >> $LOG
    echo "- #$un: collateral queue failure (${_cls#COLLATERAL }): not held" >> /tmp/mt-att.txt; queued=${queued/ $un / }; continue
  fi
  # 2026-10-23 QUARANTINE: a queue failure made ONLY of quarantined flaky checks (bin/flake-detector.sh, watchdog/QUARANTINE.txt)
  # dequeues the PR without holding it; clean-merge-reapprove re-queues it.
  if [[ "$_cls" == REAL* && -s $P/watchdog/QUARANTINE.txt ]]; then
    _allq=1; for _c in ${(s:,:)${_cls#REAL }}; do grep -qxF -- "$_c" $P/watchdog/QUARANTINE.txt || { _allq=0; break; }; done
    _qh=$(gh pr view $un -R $R --json headRefOid -q .headRefOid 2>/dev/null)
    # at most 2 free passes per head sha: a PR that really breaks a quarantined check must not loop through batches
    [ $_allq = 1 ] && [ "$(grep -c "^$un $_qh$" $P/watchdog/quar-count.txt 2>/dev/null)" -ge 2 ] && _allq=0
    [ $_allq = 1 ] && echo "$un $_qh" >> $P/watchdog/quar-count.txt
    if [ $_allq = 1 ]; then $P/sbin/kwd dequeue $un >/dev/null 2>&1; echo "$(ts) dequeued #$un: only quarantined flaky checks failed (${_cls#REAL }) -> NOT held" >> $LOG; queued=${queued/ $un / }; continue; fi
  fi
  if [[ "$_cls" == REAL* && ! -f $P/QFAIL-HOLD-OFF ]]; then
    _hs=$(gh pr view $un -R $R --json headRefOid -q .headRefOid 2>/dev/null)
    $P/sbin/kwd dequeue $un >/dev/null 2>&1
    # 2026-10-23 shared-cause rule: if ANOTHER PR failed one of the same checks within the last 30 min, the cause is main/infra, not
    # this PR: do not hold it (preflight keeps it out until main is green). History: watchdog/QFAIL-HIST.txt "PR epoch checks".
    _now=$(date +%s); _shared=""
    for _c in ${(s:,:)${_cls#REAL }}; do
      _o=$(awk -v n=$_now -v pr=$un -v c="$_c" '$1!=pr && n-$2<1800 && index(","$3",", ","c",")>0 {print $1; exit}' $P/watchdog/QFAIL-HIST.txt 2>/dev/null)
      [ -n "$_o" ] && { _shared="$_c (also #$_o)"; break; }
    done
    echo "$un $_now ${_cls#REAL }" >> $P/watchdog/QFAIL-HIST.txt
    if [ -n "$_shared" ]; then
      echo "$(ts) dequeued #$un: SHARED-CAUSE failure $_shared -> NOT held (main/infra, not this PR)" >> $LOG
      echo "- #$un: shared-cause queue failure $_shared: not held" >> /tmp/mt-att.txt
      echo "$(date +%s) $_shared" > $P/watchdog/SHARED-FAIL.txt
      queued=${queued/ $un / }; continue
    fi
    echo "$un $_hs $(date +%s) ${_cls#REAL }" >> $P/watchdog/QFAIL-HOLD.txt
    echo "$(ts) dequeued #$un: merge-group checks FAILED (${_cls#REAL }) -> held at ${_hs:0:8}, NOT merging main (lift: bin/qfail-lift.sh $un)" >> $LOG
    echo "- #$un: held, real check failure in the queue: ${_cls#REAL }" >> /tmp/mt-att.txt
    queued=${queued/ $un / }; continue
  fi
  $P/sbin/kwd dequeue $un >/dev/null 2>&1; echo "$(ts) dequeued #$un: UNMERGEABLE in queue -> auto-merge-main" >> $LOG
  zsh $P/bin/auto-merge-main.sh $un >/dev/null 2>&1 || echo "- #$un: UNMERGEABLE, auto-merge-main failed (code conflict?)" >> /tmp/mt-att.txt
  queued=${queued/ $un / }
done
tf_ph cleanup
# MQ-TICK-FAST-1: one batched read of every open PR, served to this tick's per-PR gh reads by bin/ghs/gh (shadow: verified
# against the real answers instead). Processes started from here that act on GitHub get the real gh ($TFBG).
if [ $TF != off ]; then
  KX_GH_REAL=$(whence -p gh); export KX_GH_REAL
  find /tmp/ -maxdepth 1 -name 'kx-tick-snap.*' -mmin +60 -exec rm -rf {} + 2>/dev/null   # left by a killed tick
  KX_TICK_SNAP=/tmp/kx-tick-snap.$$; rm -rf $KX_TICK_SNAP; mkdir -p $KX_TICK_SNAP
  trap 'rmdir $KXTLOCK 2>/dev/null; rm -rf /tmp/kx-tick-snap.$$' EXIT
  if [ -n "$KX_GH_REAL" ] && python3 $P/bin/tick-snapshot.py $KX_TICK_SNAP 2>$KX_TICK_SNAP/snap.err; then
    TFPATH0=$PATH
    export KX_TICK_SNAP KX_GHS_MODE=$TF KX_GHS_LOG=$TFSL PATH="$P/bin/ghs:$PATH"
    TFBG=(env -u KX_TICK_SNAP -u KX_GHS_MODE PATH=$TFPATH0)
    [ $TF = shadow ] && tf_sh "snapshot: $(tail -1 $KX_TICK_SNAP/snap.err)"
  else
    echo "$(ts) tick-fast: no snapshot this tick ($(tail -1 $KX_TICK_SNAP/snap.err 2>/dev/null)); gh reads stay live" >> $LOG
    [ $TF = shadow ] && tf_sh "snapshot FAILED: $(tail -1 $KX_TICK_SNAP/snap.err 2>/dev/null)"
  fi
  tf_ph snap
  # filler: if fewer than 2 entries are queued, enqueue the oldest approved PR with an exact cached PASS (shadow: log only)
  for _n in $(zsh $P/bin/tick-filler.sh $TF "$queued" "$HOLD" 2>>$KX_TICK_SNAP/filler.err); do
    [ $TF = on ] && queued="$queued$_n "
  done
  tf_ph fill
fi
open=$(gh pr list -R $R --state open --limit 200 --json number -q '.[].number' | sort -u)
# 2026-10-13: ticks at 11:53/12:03Z did nothing silently while a manual run enqueued 2 PRs: log empty inputs
[ -z "$open" ] && echo "$(ts) ERROR: gh pr list returned nothing (gh auth/network under launchd?): $(gh auth status 2>&1 | tail -1)" >> $LOG
[ "$queued" = "  " ] && echo "$(ts) note: merge queue list empty" >> $LOG
: > /tmp/mt-att.txt
approved_local=$(comm -12 <(grep -Eo '^[0-9]+' $P/approved.txt | sort -u) <(echo "$open"))
# Label-approved PRs (Sonnet reviewer) count ONLY if they touch no high-risk path;
# a high-risk PR must also be in approved.txt, which only the coordinator writes.
RISKY='^(pkg/(core|storage|crypto|auth)/|server/(middleware|admin)/|server/handlers/(auth|session|roles)|migrate/|\.github/)|^docs/adr'   # example map with invented paths: the real one lists the product's security-critical directories
# 2026-10-06: REVIEW-BOT retired; the watchdog is the only reviewer and approved.txt
# the only approval list. bot-approved.txt is no longer read (it let #N through).
approved_label=""
approved=$(printf '%s\n' ${=approved_local} ${=approved_label} | sort -un)
# 2026-10-27 lever A: reorder by priority (READY.txt blocking count, then age) before the pf-cache
# split below, which decides performance tiering, not priority -- priority decides order within each
# tier. Off switch: touch MQ-PRIORITY-OFF (falls back to the sort -un order above). bin/mq-priority.sh
approved=$(zsh $P/bin/mq-priority.sh "$approved" 2>/dev/null | grep . || echo "$approved")
# 2026-10-20: PRs with a cached preflight PASS go first, so a free enqueue never waits behind an earlier PR's ~3-10 min fresh preflight
# (#N sat out of an empty queue behind #N's preflight). Cache line: PR headsha mainsha RESULT...
_first=""; _rest=""
for _p in ${=approved}; do
  if awk -v p=$_p '$1==p && $4 ~ /^PASS/ {f=1} END{exit !f}' $P/preflight-cache.txt 2>/dev/null; then _first="$_first $_p"; else _rest="$_rest $_p"; fi
done
approved=$(printf '%s\n' ${=_first} ${=_rest} | grep .)
# WHOLE-STACK (2026-10-15, owner): GitHub refuses a stacked child queued behind its base (invalid_merge_commit).
# For a fully approved stack, queue only the top PR; its merge commit lands the bases too. COVERED = bases of such tops.
covered=" "
for tp in ${=approved}; do
  b=$(zsh $P/bin/stack-top.sh $tp 2>/dev/null) && covered="$covered${b// / } "
done


# preflight gate: 0 = OK to enqueue. Runs ~/proj/prompts/bin/preflight.sh (merge into
# today's main + drift/ledger/build/vet/guard checks); at most MAXPF fresh runs per tick.
PF=0; MAXPF=2   # 2026-10-19: was 6; a tick with 6 x ~10 min preflights ran an hour and starved enqueue + UNMERGEABLE cleanup (approved->enqueue p90 155 min)
pf_ok() {
  [ $TF = on ] && { pf_cached "$@"; return; }   # MQ-TICK-FAST-1: on-mode never runs a preflight inline
  local p=$1 pf
  if [ $PF -ge $MAXPF ] && ! grep -q "^$p " $P/preflight-cache.txt 2>/dev/null; then return 1; fi
  # 2026-10-23 PREVENT: failing preflights were never cached, so the same low-numbered red PRs used both fresh slots every
  # tick and starved the rest (#N). A PR whose preflight FAILED on this head within 25 min is skipped without using a slot.
  local _hd _fc=$P/watchdog/pf-fail-cache.txt _t; _hd=$(gh pr view $p -R $R --json headRefOid -q .headRefOid 2>/dev/null)
  if [ -n "$_hd" ]; then
    _t=$(grep "^$p $_hd " $_fc 2>/dev/null | tail -1 | cut -d' ' -f3)
    if [ -n "$_t" ] && [ $(( $(date +%s) - _t )) -lt 1500 ]; then return 1; fi
  fi
  local _pt=$EPOCHSECONDS
  pf=$($P/bin/preflight.sh $p 2>/dev/null | tail -1)
  [ $TF = shadow ] && [[ "$pf" != *cached* ]] && tf_sh "pf: #$p ran a preflight inline for $((EPOCHSECONDS-_pt))s (${pf:-no result}); on-mode would leave it to bin/pf-bg.sh and read the verdict next tick"
  [[ "$pf" != *cached* ]] && PF=$((PF+1))
  [[ "$pf" == FAIL* && -n "$_hd" ]] && echo "$p $_hd $(date +%s)" >> $_fc
  if [[ "$pf" != PASS* ]]; then
    echo "- #$p: preflight ${pf:-no result} (log /tmp/preflight-$p.log)" >> /tmp/mt-att.txt
    [[ "$pf" != *cached* ]] && echo "$(ts) preflight #$p ${pf:-no result}" >> $LOG
    return 1
  fi
  echo "$(ts) preflight #$p $pf" >> $LOG
  return 0
}
# MQ-TICK-FAST-1 on-mode preflight gate: read the verdict for the current (head, main, queue) key from the cache (or an
# earlier PASS that bin/preflight-reuse.py may reuse) without running a check: PF_CACHE_ONLY=1 bin/preflight.sh. No verdict
# yet = ask bin/pf-bg.sh for one and skip the PR this tick. $2=fl (the fast-lane call, which comes BEFORE the hold checks):
# ask only for a docs-only PR, so a background slot never goes to a PR the holds would refuse.
typeset -A PFC_M
pf_cached() {
  local p=$1 why=${2:-} pf _hd _fc=$P/watchdog/pf-fail-cache.txt _t _k
  _hd=$(gh pr view $p -R $R --json headRefOid -q .headRefOid 2>/dev/null)
  if [ -n "$_hd" ]; then
    _t=$(grep "^$p $_hd " $_fc 2>/dev/null | tail -1 | cut -d' ' -f3)
    if [ -n "$_t" ] && [ $(( $(date +%s) - _t )) -lt 1500 ]; then
      [[ " $TFFAILS " == *" $p "* ]] || { TFFAILS="${TFFAILS:-} $p"; echo "- #$p: preflight failed on ${_hd:0:8} $(( ($(date +%s) - _t) / 60 )) min ago (log /tmp/preflight-$p.log); retried 25 min after the failure" >> /tmp/mt-att.txt; }
      return 1
    fi
  fi
  _k="$p ${_hd:-none} ${queued// /,}"
  if [ -n "${PFC_M[$_k]:-}" ]; then pf=${PFC_M[$_k]}
  else pf=$(KX_GHS_BYPASS=1 PF_CACHE_ONLY=1 $P/bin/preflight.sh $p 2>/dev/null | tail -1); PFC_M[$_k]=${pf:-none}
    [[ "$pf" == PASS* ]] && echo "$(ts) preflight #$p $pf" >> $LOG
  fi
  [[ "$pf" == PASS* ]] && return 0
  if [[ "$pf" == MISS* ]]; then
    # fast-lane call: only a docs-only PR (one the fast lane could merge) is worth a background run before the holds
    if [ "$why" = fl ] && gh pr view $p -R $R --json files -q '.files[].path' 2>/dev/null | grep -qvE '(\.md$|^docs/|^changelog\.d/)'; then return 1; fi
    # A real failing check of its own (anything but build-and-test / fuzz*) closes both enqueue paths below (ENQUEUE GATE:
    # _egreal != 0, and then real != 0; such a check is a FAILURE, so nfail != 0 and the last enqueue is never reached).
    # The verdict cannot matter this tick: no background run; the tick goes on to its rerun / needs-attention handling,
    # which the old tick reached only after spending a preflight on it.
    if [ ! -f $P/ENQUEUE-GATE-OFF ] && [ "$(echo "$failnames" | tr ',' '\n' | grep -v -E '^(build-and-test|fuzz.*)$' | grep -c .)" != 0 ]; then
      [ "$why" = fl ] && return 1
      return 0
    fi
    [ -n "$_hd" ] || return 1
    grep -q "^$p $_hd " $P/watchdog/pf-bg-queue.txt 2>/dev/null || { echo "$p $_hd $(date +%s)" >> $P/watchdog/pf-bg-queue.txt; echo "$(ts) preflight #$p: no verdict for ${_hd:0:8} yet; queued for bin/pf-bg.sh (next tick reads it)" >> $LOG; }
    [[ " $TFREQS " == *" $p "* ]] || { TFREQS="$TFREQS $p"; echo "- #$p: preflight running in the background (bin/pf-bg.sh); verdict next tick" >> /tmp/mt-att.txt; }
    [ $TFREQ = 1 ] || { TFREQ=1; (nohup $TFBG zsh $P/bin/pf-bg.sh >/dev/null 2>&1 &); }
    return 1
  fi
  echo "- #$p: preflight ${pf:-no result} (log /tmp/preflight-$p.log)" >> /tmp/mt-att.txt
  return 1
}
# MQ-TICK-FAST-1: right before an enqueue, re-read the PR live; it must be what this tick decided on (snapshot reads can be
# a few minutes old). mergeable may only have gone UNKNOWN -> MERGEABLE. on: any other change skips the PR until the next
# tick; shadow: logged.
tf_recheck() {
  [ $TF = off ] && return 0
  local now; now=$(KX_GHS_BYPASS=1 gh pr view $1 -R $R --json state,mergeable,baseRefName,isDraft,statusCheckRollup,headRefOid -q '
    [.state, .mergeable, .baseRefName, (.isDraft|tostring), .headRefOid,
     (.statusCheckRollup | group_by([(.name // .context), (.workflowName // "")]) | map(max_by(.completedAt // .startedAt // ""))) as $cr |
     ([$cr[]|select((.conclusion // .status)=="FAILURE" or .conclusion=="TIMED_OUT")]|length|tostring),
     ([$cr[]|select(.conclusion=="CANCELLED")]|length|tostring),
     ([$cr[]|select((.conclusion // "") == "" and (.state // "") != "SUCCESS")]|length|tostring),
     ([$cr[]|select(.conclusion=="FAILURE")|.name]|join(","))] | join("|")' 2>/dev/null)
  local a=("${(@s:|:)info}") b=("${(@s:|:)now}")
  [[ "$now" == "$info" ]] && return 0
  [[ ${a[2]} == UNKNOWN && ${b[2]} == MERGEABLE ]] && a[2]=MERGEABLE && [[ "${(j:|:)a}" == "$now" ]] && return 0
  if [ $TF = shadow ]; then tf_sh "recheck: #$1 changed between the decision and the enqueue (decided '$info', live '$now'); on-mode would skip it this tick"; return 0; fi
  echo "$(ts) skip #$1: changed during the tick (decided '$info', live '${now:-unreadable}'); next tick" >> $LOG
  return 1
}
# 2026-10-17 main-red reflex: while QUEUE-PAUSED exists (bin/main-red.sh, required check red on main)
# only PRs titled "[fix-main]" may enter the queue.
paused_skip() { [ -f $P/QUEUE-PAUSED ] || return 1; local t; t=$(gh pr view $1 -R $R --json title -q .title 2>/dev/null); [[ "$t" == *"[fix-main]"* ]] && return 1; echo "$(ts) skip #$1: QUEUE-PAUSED (main red)" >> $LOG; return 0; }
RERUNS=0; MAXRERUNS=8
maindate=$(gh api repos/$R/commits/main -q .commit.committer.date 2>/dev/null)   # 2026-10-21: for bin/head-blocked.sh
for p in ${=approved}; do
  # MQ-TICK-FAST-1 time box: past TICK-BUDGET only PRs with a cached PASS are still handled (cleanup and filler ran first)
  if [ $TF != off ] && (( EPOCHSECONDS - T0 >= TFBUDGET )) && [[ " $_first " != *" $p "* ]]; then
    if [ $TF = on ]; then echo "$(ts) skip #$p: tick time budget (${TFBUDGET}s) spent; next tick" >> $LOG; continue; fi
    [ -z "${TFBUD:-}" ] && { TFBUD=1; tf_sh "budget: ${TFBUDGET}s spent at #$p after $((EPOCHSECONDS-T0))s; on-mode would leave the PRs without a cached PASS from here to the next tick"; }
  fi
  if [[ "$covered" == *" $p "* ]]; then
    [[ "$queued" == *" $p "* ]] && { $P/sbin/kwd dequeue $p >/dev/null 2>&1; echo "$(ts) dequeued #$p: merges inside its stack's top PR" >> $LOG; queued=${queued/ $p / }; }
    continue
  fi
  [[ "$HOLD" == *" $p "* || "$queued" == *" $p "* ]] && continue
  zsh $P/bin/qfail-held.sh $p && { echo "$(ts) skip #$p: held after a real queue check failure (bin/qfail-lift.sh $p)" >> $LOG; continue; }
  istop=0; [[ "$covered" != " " ]] && zsh $P/bin/stack-top.sh $p >/dev/null 2>&1 && istop=1
  # FIXING: the coordinator is fixing this PR by hand; do not re-enqueue it meanwhile.
  [ -f $P/FIXING ] && grep -qx "$p" $P/FIXING && continue
  # QUEUE-PAUSED (main is red): only the PRs listed in that file may be enqueued/handled.
  [ -f $P/QUEUE-PAUSED ] && ! grep -qx "$p" $P/QUEUE-PAUSED && continue
  info=$(gh pr view $p -R $R --json state,mergeable,baseRefName,isDraft,statusCheckRollup,headRefOid -q '
    [.state, .mergeable, .baseRefName, (.isDraft|tostring), .headRefOid,
     (.statusCheckRollup | group_by([(.name // .context), (.workflowName // "")]) | map(max_by(.completedAt // .startedAt // ""))) as $cr |
     ([$cr[]|select((.conclusion // .status)=="FAILURE" or .conclusion=="TIMED_OUT")]|length|tostring),
     ([$cr[]|select(.conclusion=="CANCELLED")]|length|tostring),
     ([$cr[]|select((.conclusion // "") == "" and (.state // "") != "SUCCESS")]|length|tostring),
     ([$cr[]|select(.conclusion=="FAILURE")|.name]|join(","))] | join("|")' 2>/dev/null) || { echo "$(ts) skip #$p: gh pr view failed" >> $LOG; continue; }
  IFS='|' read -r state mergeable base draft prhead nfail ncancel npend failnames <<< "$info"
  [ "$state" != "OPEN" ] && continue
  # .github / ADR guard (2026-10-10, after #N merged CI changes without an explicit OK): PRs touching
  # .github/** or docs/adr* are enqueued only if owner approved them (listed in github-approved.txt).
    # stack guard (2026-10-10 19:50): never enqueue a PR whose body says STACKED ON #N while #N is still open
    for sb in $( [ $istop = 1 ] || gh pr view $p -R $R --json body -q .body 2>/dev/null | grep -oiE 'stacked on #[0-9]+' | grep -oE '[0-9]+'); do
      [ "$sb" = "$p" ] && continue
      # 2026-10-11: a stacked PR may join the queue BEHIND its base once the base is queued (queue tests
      # base+child together; stacks no longer drain one 40-min cycle at a time). Base open and not queued -> skip.
      if [ "$(gh pr view $sb -R $R --json state -q .state 2>/dev/null)" = OPEN ] && [[ "$queued" != *" $sb "* ]]; then echo "- #$p: STACKED ON #$sb (open, not queued); not enqueued" >> /tmp/mt-att.txt; continue 2; fi
    done
  if gh pr view $p -R $R --json files -q '.files[].path' 2>/dev/null | grep -qE '^(\.github/|\.claude/|docs/adr)'; then
    grep -qE "^$p $prhead( |\$)" $P/github-approved.txt 2>/dev/null || { echo "- #$p: touches .github/ or an ADR; needs admin's OK on this head ${prhead:0:8} (bin/kx-gh-approve $p)" >> /tmp/mt-att.txt; continue; }
  fi
  # 2026-11-24 CIGATE-FILLER-1: scripts/ci is gated too (lib-dispatch ci_gate_blocks); #N was enqueued here with no OK in github-approved.txt (data-only guard-inputs.tsv exempt)
  _gf=$(gh pr view $p -R $R --json files -q '[.files[].path]|join(",")' 2>/dev/null)
  if ci_gate_blocks $p $prhead "$_gf"; then echo "- #$p: $CI_GATE_WHY; needs admin's OK on this head ${prhead:0:8} (bin/kx-gh-approve $p)" >> /tmp/mt-att.txt; continue; fi
  # Commit-pinned approval (2026-10-10, kwd approve N SHA): if the approval names a head SHA and the
  # PR has moved since, it needs re-review; don't enqueue. Number-only lines (older approvals) still count.
  pin=$(grep -E "^$p [0-9a-f]{40}" $P/approved.txt | tail -1 | cut -d' ' -f2)
  if [ -n "$pin" ] && ! grep -q "^$p $pin " $P/watchdog/approval-provenance.txt 2>/dev/null; then echo "$(ts) skip #$p: approval at ${pin:0:8} has no provenance" >> $LOG; echo "- #$p: approved at ${pin:0:8} with no provenance record (needs a review APPROVE on that head)" >> /tmp/mt-att.txt; continue; fi
  if [ -n "$pin" ]; then
    hd=$(gh pr view $p -R $R --json headRefOid -q .headRefOid 2>/dev/null)
    if [ -n "$hd" ] && [ "$hd" != "$pin" ]; then
      # 2026-10-11: a head that differs from the approved one only by CLEAN merges of main is re-approved mechanically
      if $TFBG zsh $P/bin/clean-merge-reapprove.sh $p $pin $hd; then echo "$(ts) auto-reapproved #$p ${pin:0:8} -> ${hd:0:8} (clean merge of main)" >> $LOG; pin=$hd
      else echo "- #$p: approved at ${pin:0:8}, head now ${hd:0:8} (needs re-review)" >> /tmp/mt-att.txt; continue; fi
    fi
  fi
  # 2026-10-28: this loop is the actual enqueue path (the one labelled MERGE-MASTER in kwd.log) and, unlike
  # ready-feeder.sh/tick-filler.sh, it never checked declined-heads.txt -- only approved.txt/provenance. A head that
  # a review had declined for two real defects was enqueued an hour later anyway. sbin/kwd got the same check (its
  # own enqueue subcommand had the identical gap), but this loop calls the GraphQL mutation directly, so it needed
  # its own.
  dchk=${pin:-$prhead}
  # 2026-10-29: same gap as above, third occurrence -- MERGE-MASTER's own "waits on independent REVIEW-DEEP" placeholder
  # line is not a decline, it's a request for a review that may since have come back APPROVE (review-pump's harvest adds
  # the head to READY-LIST.txt on APPROVE but never retracts this placeholder line), so it must not match here either.
  # Moved to decline_pending_review() (lib-dispatch.sh) -- single source of truth after the 9-site sweep.
  _dl=$(grep "^$p $dchk " $P/watchdog/declined-heads.txt 2>/dev/null | tail -1)
  decline_pending_review "$_dl" && _dl=""
  if [ -n "$dchk" ] && [ -n "$_dl" ]; then
    echo "$(ts) skip #$p: declined head ${dchk:0:8} (declined-heads.txt)" >> $LOG
    echo "- #$p: head ${dchk:0:8} is in declined-heads.txt; a review has not cleared it (needs a fix + re-approval, or the decline is stale)" >> /tmp/mt-att.txt
    continue
  fi
  if [ "$base" != "main" ]; then echo "- #$p: stacked on $base (retarget after base merges)" >> /tmp/mt-att.txt; continue; fi
  if [ "$mergeable" = "CONFLICTING" ]; then
    # Auto-rebase approved PRs whose conflicts are only in append-only ledgers (TSV / INVARIANTS.md),
    # at most 2 running at once, in the background; code conflicts go to needs-coordinator.txt.
    if [ "$base" = "main" ] && [ "$(pgrep -f auto-merge-main.sh | wc -l | tr -d ' ')" -lt 2 ]; then
      (nohup $TFBG $P/bin/auto-merge-main.sh $p >/dev/null 2>&1 &)
      echo "- #$p: merge conflict, auto-rebase attempted" >> /tmp/mt-att.txt
    else
      echo "- #$p: merge conflict, needs rebase" >> /tmp/mt-att.txt
    fi
    continue
  fi
  # repo-guards (PR-only guard/sweep tests) failed: the merge_group run would fail too.
  # Hold it back so it does not waste a queue slot; surface it for a fix.
  if [[ ",$failnames," == *",repo-guards,"* ]]; then
    echo "- #$p: repo-guards failed (guard/sweep drift), not enqueued; fix before queueing" >> /tmp/mt-att.txt
    continue
  fi
  # 2026-10-21 RETRY WAIT (QUEUE-REDESIGN item 1): a head whose queue run failed is not re-enqueued until something
  # lands on main (rule, replay numbers and gaps in bin/head-blocked.sh; off: touch HEAD-BLOCK-OFF).
  if hbw=$(zsh $P/bin/head-blocked.sh $p $prhead $maindate); then
    echo "$(ts) skip #$p: head ${prhead:0:8} waits for main to move ($hbw)" >> $LOG
    continue
  fi
  # PREFLIGHT (2026-10-06): merge the PR into TODAY's main locally and run the cheap
  # checks that most often fail merge_group after other PRs landed (generated-file
  # drift, ledgers, build/vet, guard tests). A PR that fails never enters the queue,
  # so it can't fail a whole batch. Only for PRs whose own CI has finished. At most
  # MAXPF fresh (uncached) preflights per tick; cached PASSes are free.
  # 2026-10-13: log silent skips (#N sat out of the queue 15+ min with no trace)
  [ "$npend" != "0" ] && { echo "$(ts) skip #$p: $npend check(s) pending" >> $LOG; continue; }
  # FAST LANE (2026-10-15, owner): approved docs/tests-only PRs merge directly (bin/fastlane.sh has the rules).
  # 2026-10-23: fast lane only after a passing preflight (guards run on the merge with TODAY's main). A docs-only PR that was behind main went in without it and turned main red on a repo-wide guard test for every PR.
  [ "$draft" != "true" ] && pf_ok $p fl && $TFBG zsh $P/bin/fastlane.sh $p && continue
  # 2026-10-19 overlap hold: do not enqueue a PR that edits the same files as one already queued (bin/overlap-hold.sh; off: touch OVERLAP-HOLD-OFF)
  [ "$draft" != "true" ] && [ ! -f $P/OVERLAP-HOLD-OFF ] && zsh $P/bin/overlap-hold.sh $p "$queued" && continue
  # 2026-10-20 global-rule hold (rerun reduction #1): a PR that changes a repo-wide rule goes through the queue alone (bin/global-rule-hold.sh; off: touch GLOBAL-HOLD-OFF)
  [ "$draft" != "true" ] && [ ! -f $P/GLOBAL-HOLD-OFF ] && zsh $P/bin/global-rule-hold.sh $p "$queued" && continue
  if [ "$draft" != "true" ] && ! pf_ok $p; then echo "$(ts) skip #$p: preflight not run/failed (PF=$PF)" >> $LOG; continue; fi
  # Try to enqueue FIRST, whatever the PR rollup says: GitHub itself enforces the
  # required checks at enqueue time, and the queue's merge_group CI is the real gate.
  # Only if GitHub refuses do we fall through to the rerun/attention logic below.
  # 2026-10-23 ENQUEUE GATE (owner: fix the merge trouble): a PR with a REAL failing check of its own (anything except the
  # build-and-test gate and fuzz shards) is not enqueued: it falls through to the rerun / known-flake / attention logic below.
  # #N entered the queue with Web CI red and put a batch of four at risk. Off: touch ENQUEUE-GATE-OFF.
  _egreal=$(echo "$failnames" | tr ',' '\n' | grep -v -E '^(build-and-test|fuzz.*)$' | grep -c .)
  if [ "$draft" != "true" ] && { [ -f $P/ENQUEUE-GATE-OFF ] || [ "${_egreal:-0}" = 0 ]; }; then
    paused_skip $p && continue
    tf_recheck $p || continue
    enq_guard $p || continue; ovl_guard $p || continue   # 2026-11-16: a fixer is working this PR; a queued branch cannot be pushed to (GH006)
    id=$(gh pr view $p -R $R --json id -q .id)
    out=$(gh api graphql -f query="mutation{enqueuePullRequest(input:{pullRequestId:\"$id\"}){mergeQueueEntry{position}}}" -q .data.enqueuePullRequest.mergeQueueEntry.position 2>&1 | tail -1)
    if [[ "$out" == <-> ]]; then echo "$(ts) enqueue #$p -> $out" >> $LOG; queued="$queued$p "; continue; fi   # 2026-10-15: a stacked child can follow its base in the same tick
  fi
  # The merge queue runs its own full CI (merge_group) and is the real gate, and
  # GitHub accepts an enqueue with a red PR rollup. A PR whose ONLY failure is the
  # build-and-test gate (upstream jobs cancelled by runner contention / superseded
  # runs) is enqueued directly instead of re-running its PR CI.
  real=$(echo "$failnames" | tr ',' '\n' | grep -v -E '^build-and-test$' | grep -c .)
  if [ "$nfail" != "0" ] && [ "$real" = "0" ] && [ "$npend" = "0" ] && [ "$draft" != "true" ] && pf_ok $p; then
    paused_skip $p && continue
    tf_recheck $p || continue
    enq_guard $p || continue; ovl_guard $p || continue   # 2026-11-16: a fixer is working this PR; a queued branch cannot be pushed to (GH006)
    id=$(gh pr view $p -R $R --json id -q .id)
    out=$(gh api graphql -f query="mutation{enqueuePullRequest(input:{pullRequestId:\"$id\"}){mergeQueueEntry{position}}}" -q .data.enqueuePullRequest.mergeQueueEntry.position 2>&1 | tail -1)
    echo "$(ts) enqueue (gate-only red, queue CI decides) #$p -> $out" >> $LOG
    # Enqueue refused (e.g. "N of M required status checks are expected" when a required
    # job never reported): fall through to the rerun logic below.
    [[ "$out" == <-> ]] && continue
  fi
  if [ "$nfail" != "0" ]; then
    # Fuzz-only failures (known pre-existing oracle findings flake unrelated PRs), or a
    # build-and-test gate failure caused by cancelled upstream jobs (runner contention).
    # Re-run them ONCE per head SHA automatically; after that, escalate.
    nonfuzz=$(echo "$failnames" | tr ',' '\n' | grep -v -E '^(fuzz|build-and-test$)' | grep -c .)
    # KNOWN FLAKES (2026-10-15): if every failed run's log matches known-flakes.txt, treat it like a fuzz flake (one rerun per SHA).
    if [ "$nonfuzz" != "0" ] && [ -s $P/known-flakes.txt ]; then
      pat=$(grep -vE '^\s*(#|$)' $P/known-flakes.txt | sed -E 's/[[:space:]]+#.*$//' | paste -sd '|' -)
      allknown=1
      for run in $(gh pr checks $p -R $R --json state,link -q '.[]|select(.state=="FAILURE")|.link' 2>/dev/null | sed -E 's#.*/runs/([0-9]+)/.*#\1#' | sort -u); do
        gh run view $run -R $R --log-failed 2>/dev/null | grep -qE "$pat" || { allknown=0; break; }
      done
      [ $allknown = 1 ] && { nonfuzz=0; echo "$(ts) #$p: failures match known-flakes.txt" >> $LOG; }
    fi
    sha=$(gh pr view $p -R $R --json headRefOid -q .headRefOid)
    if [ "$nonfuzz" = "0" ] && [ $RERUNS -lt $MAXRERUNS ] && [ "$(grep -c "^$p $sha$" $P/fuzz-reruns.txt 2>/dev/null)" -lt 3 ]; then
      for run in $(gh pr checks $p -R $R --json state,link -q '.[]|select(.state=="FAILURE")|.link' 2>/dev/null | sed -E 's#.*/runs/([0-9]+)/.*#\1#' | sort -u); do
        gh run rerun $run --failed -R $R >/dev/null 2>&1 && echo "$(ts) rerun fuzz/gate-only failure run $run (#$p)" >> $LOG
      done
      echo "$p $sha" >> $P/fuzz-reruns.txt; RERUNS=$((RERUNS+1))
      continue
    fi
    [ $TF = on ] && echo "$(ts) skip #$p: failing checks of its own ($failnames)" >> $LOG   # MQ-TICK-FAST-1: was silent in this log
    echo "- #$p: failing checks: $failnames" >> /tmp/mt-att.txt; continue
  fi
  if [ "$ncancel" != "0" ]; then
    [ $RERUNS -ge $MAXRERUNS ] && continue; RERUNS=$((RERUNS+1))
    for run in $(gh pr checks $p -R $R --required --json state,link -q '.[]|select(.state=="CANCELLED")|.link' 2>/dev/null | sed -E 's#.*/runs/([0-9]+)/.*#\1#' | sort -u); do
      gh run rerun $run --failed -R $R >/dev/null 2>&1 && echo "$(ts) rerun cancelled run $run (#$p)" >> $LOG
    done
    continue
  fi
  [ "$npend" != "0" ] && continue
  [ "$draft" = "true" ] && continue
  paused_skip $p && continue
  tf_recheck $p || continue
  enq_guard $p || continue; ovl_guard $p || continue   # 2026-11-16: a fixer is working this PR; a queued branch cannot be pushed to (GH006)
  id=$(gh pr view $p -R $R --json id -q .id)
  out=$(gh api graphql -f query="mutation{enqueuePullRequest(input:{pullRequestId:\"$id\"}){mergeQueueEntry{position}}}" -q .data.enqueuePullRequest.mergeQueueEntry.position 2>&1 | tail -1)
  echo "$(ts) enqueue #$p -> $out" >> $LOG
done
# MQ-TICK-FAST-1: the PR phase is over; everything below reads GitHub live again.
if [ $TF != off ]; then
  tf_ph loop
  TFN=(); for _c in real served verified mismatch; do TFN+=("gh_$_c=$( [ -f $KX_TICK_SNAP/n.$_c ] && wc -c < $KX_TICK_SNAP/n.$_c | tr -d ' ' || echo 0)"); done
  [ -n "$TFPATH0" ] && export PATH=$TFPATH0
  unset KX_TICK_SNAP KX_GHS_MODE; TFBG=()
  [ $TF = on ] && [ -s $P/watchdog/pf-bg-queue.txt ] && (nohup zsh $P/bin/pf-bg.sh >/dev/null 2>&1 &)
fi

# Main-red detector: if the latest completed CI run on main failed, every merge-queue group will
# fail too. Surface it loudly (top of needs-attention + macOS notification once per main SHA).
# 2026-11-04: gh run list --workflow ci.yml hits GitHub's workflow-scoped runs endpoint, which can lag the generic
# /actions/runs endpoint by an hour or more. Root cause confirmed live: it is specifically the status=completed
# QUERY PARAM that is served from a stale index -- the same generic endpoint with no status param (filtering status
# client-side instead) returns the newest run correctly and immediately, while ?status=completed kept returning an
# older run (over an hour stale) on both the workflow-scoped AND the generic endpoint. Never pass status= in the
# query string; filter it in jq.
mainrun=$(gh api "repos/$R/actions/runs?branch=main&event=push&per_page=30" -q '[.workflow_runs[]|select(.name=="CI")|select(.status=="completed")][0]|.conclusion+" "+.head_sha' 2>/dev/null)
mainhead=$(gh api repos/$R/commits/main -q .sha 2>/dev/null)
# Only unpause when the push CI run for the CURRENT main HEAD succeeded (strict match, logged).
if [[ -n "$mainhead" && "$mainrun" == "success $mainhead" && -f $P/QUEUE-PAUSED && ! -f $P/watchdog/QUEUE-SYSTEMIC.sig ]]; then   # 2026-11-17 QUEUE-SYSTEMIC-1: a pause set for a queue-wide step failure is cleared by bin/queue-systemic.py (a green merge_group run), not by a green push run
  # 2026-11-04: this used to trust conclusion=="success" alone. GitHub marks a push run "success" even when its
  # test-suite job is SKIPPED (changes-filter) -- exactly what happened once: a real failure from an earlier main
  # commit was still unfixed, but this check cleared QUEUE-PAUSED anyway and let PRs straight back into a queue that
  # was still doomed.
  # Require the test-suite job to show an actual non-skipped conclusion before trusting the green.
  mrid=$(gh api "repos/$R/actions/runs?branch=main&event=push&per_page=30" -q '[.workflow_runs[]|select(.name=="CI")|select(.status=="completed")][0]|.id' 2>/dev/null)
  tsskip=0
  [ -n "$mrid" ] && tsskip=$(gh api "repos/$R/actions/runs/$mrid/jobs?per_page=100" -q '[.jobs[]|select(.name|test("^test-suite"))|select(.conclusion=="skipped")]|length' 2>/dev/null)
  if [ "${tsskip:-0}" -gt 0 ]; then
    # 2026-11-04: push CI deliberately skips re-running test-suite when it
    # reuses a SHA already verified by merge_group (the "changes" job's queue_verified branch) -- that is
    # normal merge-queue behaviour, not a false green, and without this fallback QUEUE-PAUSED could never
    # auto-clear for an ordinary queue-landed merge. Check the merge_group run for this same head SHA instead
    # of giving up (no branch= filter: merge_group runs report a gh-readonly-queue/* head_branch, not main).
    mgid=$(gh api "repos/$R/actions/runs?event=merge_group&per_page=50" -q "[.workflow_runs[]|select(.name==\"CI\")|select(.head_sha==\"$mainhead\")|select(.status==\"completed\")][0]|.id" 2>/dev/null)
    mgts=0; mgbad=1
    if [ -n "$mgid" ]; then
      mgts=$(gh api "repos/$R/actions/runs/$mgid/jobs?per_page=100" -q '[.jobs[]|select(.name|test("^test-suite"))]|length' 2>/dev/null)
      mgbad=$(gh api "repos/$R/actions/runs/$mgid/jobs?per_page=100" -q '[.jobs[]|select(.name|test("^test-suite"))|select(.conclusion!="success")]|length' 2>/dev/null)
    fi
    if [ -n "$mgid" ] && [ "${mgts:-0}" -gt 0 ] && [ "${mgbad:-1}" = 0 ]; then
      rm -f $P/QUEUE-PAUSED
      echo "$(ts) main is green again ($mainrun): push test-suite was skipped (queue-verified reuse) but merge_group run $mgid for the same head ran $mgts test-suite shard(s) green -- QUEUE-PAUSED cleared" >> $LOG
    else
      echo "$(ts) main shows green ($mainrun) but test-suite was skipped on push, and no matching all-green merge_group test-suite run found for this head either -- NOT clearing QUEUE-PAUSED, needs a real green test-suite run" >> $LOG
    fi
  else
    rm -f $P/QUEUE-PAUSED; echo "$(ts) main is green again ($mainrun): QUEUE-PAUSED cleared" >> $LOG
  fi
fi
if [[ "$mainrun" == failure* ]]; then
  sha=${mainrun#failure }
  { echo "- MAIN IS RED at ${sha[1,9]}: every merge-queue group will fail until it is fixed"; cat /tmp/mt-att.txt; } > /tmp/mt-att2.txt && mv /tmp/mt-att2.txt /tmp/mt-att.txt
  if ! grep -qx "$sha" $P/main-red-notified.txt 2>/dev/null; then
    echo "$sha" >> $P/main-red-notified.txt
    osascript -e "display notification \"main CI is red at ${sha[1,9]} — merge queue will stall\" with title \"Keyorix merge-tick\"" >/dev/null 2>&1
    echo "$(ts) MAIN IS RED at ${sha[1,9]}" >> $LOG
  fi
fi
# 2026-10-11: merge main into ANY conflicting open PR (approved or not, not HOLD, not owned by a running
# session) when the conflicts are only CHANGELOG.md / ledger TSVs / security-closures.tsv. Max 2 at once.
owned=" $(for t in $(pgrep -fl 'claude.*--settings' | grep -oE 'generated/[A-Z0-9-]+' | cut -d/ -f2); do grep -hE '^Owns:' $P/sessions/SESSION-$t.md 2>/dev/null; done | grep -oE '[0-9]{3,5}' | tr '\n' ' ') "
for dp in $(gh pr list -R $R --state open --limit 100 --json number,mergeStateStatus,isDraft -q '.[] | select(.mergeStateStatus=="DIRTY" and (.isDraft|not)) | .number'); do
  [[ " $HOLD " == *" $dp "* || "$owned" == *" $dp "* ]] && continue
  [ "$(pgrep -f auto-merge-main.sh | wc -l | tr -d ' ')" -lt 2 ] || break
  (nohup $P/bin/auto-merge-main.sh $dp >/dev/null 2>&1 &)
done
# 2026-10-17 risk classes: record every open PR touching critical paths (auth, crypto, audit, storage writer,
# migrations, Helm templates) in watchdog/risk-critical.txt; MERGE-MASTER gives those a DEEP review (PROMPT.md rule 3b).
RC=$P/watchdog/risk-critical.txt; touch $RC
for rp in $(gh pr list -R $R --state open --limit 200 --json number,isDraft -q '.[]|select(.isDraft|not)|.number' 2>/dev/null); do
  grep -q "^$rp " $RC && continue
  cls=$(zsh $P/bin/risk-class.sh $rp 2>/dev/null) || continue
  [[ $cls == critical* ]] && echo "$rp $cls" >> $RC
done
# 2026-10-17 SUPERFAN: once a day (06:xxZ) start a reviewer of yesterday's merged critical-path PRs.
if [ "$(date -u +%H)" = 06 ]; then
  sf=SUPERFAN-$(date -u +%m%d)
  if [ ! -f $P/sessions/SESSION-$sf.md ]; then
    sed "s/SUPERFAN-TAG/$sf/g" $P/sessions/TEMPLATE-SUPERFAN.md > $P/sessions/SESSION-$sf.md
    echo $sf >> $P/SESSIONS-FROZEN-ALLOW
    # 2026-10-25 FSM-FIXALL-1 (D25): was a FOREGROUND start-session, which loops while NO-NEW-SESSIONS is set and the tag is not in
    # NO-NEW-SESSIONS-ALLOW: the tick wedged until its 25-min lock went stale. Self-register in both ALLOW lists and start detached via
    # start-when-slot (gates + start verification), like mk-fixer.sh / queue-failures.sh.
    grep -qx $sf $P/NO-NEW-SESSIONS-ALLOW 2>/dev/null || echo $sf >> $P/NO-NEW-SESSIONS-ALLOW
    (nohup zsh $P/bin/start-when-slot.sh $sf >/dev/null 2>&1 &)
    echo "$(ts) queued $sf (start-when-slot, detached)" >> $LOG
  fi
fi
# 2026-10-17 queue-guard: metrics, review-first list, auto-start one MERGE-FIX when the queue is low, alert when dry
zsh $P/bin/queue-failures.sh 2>>$P/watchdog/queue-failures.err
zsh $P/bin/ci-outage-guard.sh 2>>$P/watchdog/ci-outage.err   # 2026-10-19: same job failing for 3+ PRs = infra outage, pause auto-fixers, alert
zsh $P/bin/vuln-guard.sh 2>>$P/watchdog/vuln-guard.err
# 2026-11-14 hold-prune: once a day drop CLOSED/MERGED PRs from the HOLD= line above (stamp watchdog/hold-prune.stamp)
(zsh $P/bin/hold-prune.sh >/dev/null 2>&1 &)
# 2026-11-12 admin-triage (level 1+2 over the NEED ADMIN items; the rule table must pass --selftest before it may act), at most every 10 min, in the background; log: watchdog/triage.log; off: touch watchdog/TRIAGE-OFF
if [ ! -f $P/watchdog/TRIAGE-OFF ] && [ $(( $(date +%s) - $(stat -f %m $P/watchdog/.triage-last 2>/dev/null || echo 0) )) -ge 600 ]; then touch $P/watchdog/.triage-last; ( { /opt/homebrew/bin/python3 $P/bin/admin-triage.py --selftest >/dev/null 2>>$P/watchdog/triage.err && /opt/homebrew/bin/python3 $P/bin/admin-triage.py --run; } >>$P/watchdog/triage.err 2>&1 & ); fi   # 2026-11-11: a new reachable govulncheck finding blocks everyone: pause fixers, start the bump session, alert (1 PR is enough)
# 2026-11-12 pump-invariants: catches a review pump that is blind to a PR (e.g. #N #N #N sat 5 h, gate skip ignored the OK) within 45 min; also runs bin/test-ci-gate.sh. Every 10 min in the background; log watchdog/pump-invariants.log; off: touch watchdog/PUMP-INV-OFF
if [ ! -f $P/watchdog/PUMP-INV-OFF ] && [ $(( $(date +%s) - $(stat -f %m $P/watchdog/.pump-inv-last 2>/dev/null || echo 0) )) -ge 600 ]; then touch $P/watchdog/.pump-inv-last; ( /opt/homebrew/bin/python3 $P/bin/pump-invariants.py >>$P/watchdog/pump-invariants.err 2>&1 & ); fi
# 2026-11-12 queue-starve: when the queue has < 2 entries, clear mechanical blockers of idle PRs (gate ask, preflight-FAIL fixer, rerun red). Every 5 min, background; log watchdog/starve.log; off: touch watchdog/STARVE-OFF
if [ ! -f $P/watchdog/STARVE-OFF ] && [ $(( $(date +%s) - $(stat -f %m $P/watchdog/.starve-last 2>/dev/null || echo 0) )) -ge 300 ]; then touch $P/watchdog/.starve-last; ( zsh $P/bin/queue-starve.sh >>$P/watchdog/starve.err 2>&1 & ); fi
# 2026-11-12 red-no-fixer: ANY open PR red on its current head for >= 20 min with no session, no hold and no admin/author marker gets one fixer (bin/red-no-fixer.sh). Every 5 min, background; log watchdog/red-nofixer.log; off: touch watchdog/RED-NOFIXER-OFF
if [ ! -f $P/watchdog/RED-NOFIXER-OFF ] && [ $(( $(date +%s) - $(stat -f %m $P/watchdog/.rednofixer-last 2>/dev/null || echo 0) )) -ge 300 ]; then touch $P/watchdog/.rednofixer-last; ( zsh $P/bin/red-no-fixer.sh >>$P/watchdog/red-nofixer.err 2>&1 & ); fi
zsh $P/bin/disk-emergency.sh 2>>$P/watchdog/disk-emergency.err   # 2026-10-19: runaway writer guard
zsh $P/bin/main-red.sh 2>>$P/watchdog/main-red.err
zsh $P/bin/queue-guard.sh 2>>$P/watchdog/queue-guard.err
# 2026-10-11: close finished sessions and their iTerm2 windows (bin/reap-done-sessions.sh)
zsh $P/bin/reap-done-sessions.sh 2>/dev/null
{ echo "# Needs attention ($(ts))"; echo; cat /tmp/mt-att.txt; } > $ATT
echo "$(ts) done; $(grep -c '^- ' $ATT) need attention" >> $LOG
# 2026-10-11: ownership audit over ALL open PRs (not only approved ones); see bin/queue-audit.py
AUD=$(python3 $P/bin/queue-audit.py --short 2>&1)
{ echo; echo "## Ownership audit"; echo "$AUD"; } >> $ATT
echo "$AUD" | grep -E '^(- #|ALERT)' | sed 's/^/  audit: /' >> /tmp/mt-att.txt
echo "$(ts) audit: $(echo "$AUD" | grep -m1 '^UNOWNED') $(echo "$AUD" | grep -c '^ALERT') alert(s)" >> $LOG
if echo "$AUD" | grep -qE '^(- #|ALERT)'; then echo "$(ts) $AUD" | tr '\n' ' ' >> $P/watchdog/audit-alerts.log; echo >> $P/watchdog/audit-alerts.log; fi
if [ $TF != off ]; then
  tf_ph tail
  echo "$(date -u +%FT%TZ) mode=$TF total=$((EPOCHSECONDS-T0))s$TFPH ${TFN[*]} pf_inline=$PF pf_bg_requests=$(print -r -- ${=TFREQS:-} | wc -w | tr -d ' ')" >> $P/watchdog/tick-phases.log
  [ $TF = shadow ] && tf_sh "== end total=$((EPOCHSECONDS-T0))s$TFPH ${TFN[*]} pf_inline=$PF"
fi
tail -n 15 $LOG
