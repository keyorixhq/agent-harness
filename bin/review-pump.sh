#!/bin/zsh
# review-pump.sh -- 2026-10-25 (built as one of four related changes). Keeps watchdog/READY-LIST.txt supplied so the merge queue does not idle.
# Run every 60 s from queue-empty-kick.sh. Off switch: watchdog/REVIEW-PUMP-OFF. Dry run: REVIEW_DRY=1 (prints, changes nothing).
#  A. HARVEST  finished review sessions: report last line "REVIEW-<N>-DEEP-<k> DONE (APPROVE)" and the PR head still equals the reviewed
#              head -> READY-LIST.txt.   "(CHANGES)" -> declined-heads.txt (so it is not re-reviewed on the same head).
#  B. LOW-RISK open, CLEAN, non-draft PRs whose files are ONLY plain docs (docs/**.md without adr/design/security-closures, changelog.d/*.md)
#              with every check green -> READY-LIST directly (tag LOWRISK-DOCS). No ADR/design docs: those wait on admin.
#  C. REVIEW   if fewer than 3 items are in flight (ready + running review/fix sessions + queued), start a deep review (mk-reviews-batch.sh)
#              of the next reviewable PR: open, CLEAN, not draft, not held/never-approve, head not declined, no .github/scripts/ci files.
#  D. FIX      a head declined with a reason that is NOT "waits on admin" gets ONE bounded fixer session (Opus) from the decline reason.
export KX_ACTOR=review-pump; . $HOME/proj/prompts/bin/lib-actor.sh
P=$HOME/proj/prompts; R=keyorixhq/keyorix; W=$P/watchdog; LOG=$P/merge-tick.log
export PATH=$HOME/proj/prompts/bin/ghlog:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
. $P/bin/lib-unstable-why.sh   # 2026-11-22 UNSTABLE-HEAL-1: unstable_why
. $P/bin/lib-dispatch.sh; . $P/bin/lib-readylist.sh   # FSM-FIXALL-1: dispatch lock / round cap / decline class (D9 D10 D11), locked READY-LIST (D14)
ts(){ date -u +%H:%MZ; }
setopt null_glob
waitsA() { grep -Eq "^$1( |$)" $W/WAITS-ON-ADMIN.txt 2>/dev/null; }
[ -f $W/REVIEW-PUMP-OFF ] && exit 0
mkdir /tmp/kx-pump.lock 2>/dev/null || { [ $(( $(date +%s) - $(stat -f %m /tmp/kx-pump.lock) )) -gt 600 ] && rmdir /tmp/kx-pump.lock; exit 0; }
trap 'rmdir /tmp/kx-pump.lock 2>/dev/null' EXIT
touch $W/READY-LIST.txt $W/review-harvested.txt $W/fix-started.txt $P/sessions/.keep 2>/dev/null
say() { if [ -n "$REVIEW_DRY" ]; then echo "DRY: $*"; else echo "$(ts) review-pump: $*" >> $LOG; fi; }
# 2026-11-12: (1) every reason this pump leaves an open PR un-reviewed is logged once per (PR, head, class), so idle waits are explainable;
# (2) the in-flight / running cap is 5 (was 4). Undo: echo 4 > watchdog/REVIEW-CAP (or rm the file for the default 5). Backup: bin/review-pump.sh.bak-1112-skiplog.
MAXINF=5; [ -f $W/REVIEW-CAP ] && MAXINF=$(tr -dc 0-9 < $W/REVIEW-CAP); : ${MAXINF:=5}; [ "$MAXINF" -ge 1 ] 2>/dev/null || MAXINF=5
skipnote() { # skipnote PR SHA CLASS MESSAGE...
  local _pr=$1 _sha=$2 _cl=$3; shift 3
  [ -n "$REVIEW_DRY" ] && return 0
  grep -qxF "$_pr ${_sha[1,9]} $_cl" $W/review-skip-seen.txt 2>/dev/null && return 0
  echo "$_pr ${_sha[1,9]} $_cl" >> $W/review-skip-seen.txt
  [ "$_cl" = ms-UNSTABLE ] && set -- "$*; non-passing checks: $(unstable_why $_pr $_sha)"   # 2026-11-22 UNSTABLE-HEAL-1: only after the once-per-head dedup above, so at most one gh call per PR+head
  say "review-skip #$_pr ${_sha[1,9]}: $*"
}
ready_add() { grep -q "^$1 $2" $W/READY-LIST.txt || { [ -n "$REVIEW_DRY" ] || rl_append "$1 $2 $3 $(kx_by)"; say "READY +#$1 ${2[1,9]} ($3)"; }; }
# FSM-FIXALL-1 (D8/D9/D10): one guarded fixer dispatch. fix-started.txt is written only when mk-fixer.sh succeeded (it was "; echo",
# so a failed dispatch counted as done for that head forever). Returns 1 when the round cap or another dispatcher's lock says no.
fix_dispatch() {   # PR SHA REASON ADRNOTE SRC(FSM-FIXALL-2: decline_source PR SHA, or NOSRC)
  fix_round_ok $1 review-pump || return 1
  dispatch_claim $1 review-pump || { say "fixer #$1 skipped: dispatch lock held ($DISPATCH_HELD_BY)"; return 1; }
  local out; local -a ol; out=$(zsh $P/bin/mk-fixer.sh $1 $2 "$3" "$4" 2>&1)
  ol=(${(f)out}); out=${ol[-1]}   # FIXALL-VERIFY-1: ${${(@f)out}[-1]} still returned the last CHARACTER of a one-line output ("made REVFIX-N-1" -> "1"), so every normal dispatch read as FAILED and was re-dispatched; an explicit array keeps the line
  if [[ "$out" == "made "* ]]; then echo "$1 $2 ${5:-NOSRC}" >> $W/fix-started.txt; dispatch_bind $1 ${out#made } review-pump; echo "$(date -u +%FT%TZ) review-pump: fixer dispatched #$1 ${2[1,9]} tag=${out#made } why=${${3//$'\n'/ }[1,80]}" >> $W/fix-dispatch.log 2>/dev/null; return 0; fi   # 2026-11-24 LOGGING-STD-1: dated dispatch line (verdict->fixer latency)
  dispatch_release $1; say "fixer #$1 dispatch FAILED (${out[1,120]}); not recorded in fix-started, next pass retries"; return 1
}
# ---- A. harvest
for rep in $P/reports/SESSION-REVIEW-*-DEEP-*.md(N); do
  tag=${${rep:t}#SESSION-}; tag=${tag%.md}
  last=$(grep -v '^[[:space:]]*$' $rep | tail -1)
  [[ "$last" == "$tag DONE ("* ]] || continue
  pr=$(echo $tag | sed -E 's/REVIEW-([0-9]+)-DEEP-[0-9]+/\1/')
  brief=$P/sessions/SESSION-$tag.md; sha=$(grep -oE 'head [0-9a-f]{40}' $brief 2>/dev/null | head -1 | awk '{print $2}')
  if [ -z "$sha" ]; then
    # FIXALL-NOHEAD-1 (2026-11-04): a brief missing its head line (e.g. #N, an older PR) used to
    # retry and log every tick forever, since nothing was ever written to review-harvested.txt for it. Record a
    # NOHEAD marker the first time so later ticks skip silently -- a brief never grows a head after the fact.
    grep -qx "$tag NOHEAD" $W/review-harvested.txt && continue
    say "harvest $tag: no head in brief, giving up (recorded as NOHEAD, wont retry)"
    [ -n "$REVIEW_DRY" ] || echo "$tag NOHEAD" >> $W/review-harvested.txt
    continue
  fi
  # FIXALL-TAGREUSE-1 (2026-10-28): dedup key used to be the bare tag name, so a session TAG reused on a
  # later day (e.g. REVIEW-N-DEEP-1 run again against a fresh head after a fixer round) was silently skipped
  # forever -- the report file is overwritten in place, review-harvested.txt already had the tag from the first
  # run, and the new CHANGES/APPROVE verdict at the new head never reached declined-heads.txt/decline-class.txt,
  # so no fixer was ever dispatched (#N, #N sat stuck with no notice). Key on tag+head instead: idempotent
  # for a genuine re-harvest of the same (tag, head), but a reused tag at a new head is processed again.
  grep -qx "$tag $sha" $W/review-harvested.txt && continue
  cur=$(gh pr view $pr -R $R --json state,headRefOid -q 'if .state=="OPEN" then .headRefOid else "" end' 2>/dev/null </dev/null)
  # REAPER-VERDICT-1 (2026-10-28): a session the reaper force-closes writes its own generic
  # last line ("... DONE (auto-detected by reaper from final message)"), which matches neither (APPROVE) nor
  # (CHANGES), so a real, well-formed verdict already written in the report's own "## Verdict" section fell
  # into the unknown-verdict branch below and was never classified -- #N sat with no declined-heads entry
  # and no READY-LIST entry, invisible to every feeder, even though the review itself finished cleanly.
  # Fall back to the report's own "## Verdict" line before giving up.
  if [[ "$last" != *"(APPROVE)"* && "$last" != *"(CHANGES)"* ]]; then
    bv=$(awk 'BEGIN{f=0} /^## *Verdict/{f=1;next} f && NF{print;exit}' "$rep")
    if [[ "$bv" == *APPROVE* ]]; then last="$tag DONE (APPROVE)"
    elif [[ "$bv" == *CHANGES* ]]; then last="$tag DONE (CHANGES)"
    fi
  fi
  if [[ "$last" == *"(APPROVE)"* && ! -f $W/OPUSFINAL-OFF ]] && grep -qx "$tag" $W/sec-sonnet-tags.txt 2>/dev/null; then
    # OPUSFINAL-1 (2026-11-22, owner): a Sonnet APPROVE on security-critical paths is not final; the Opus confirmation (OPUS_CONFIRM) owes the verdict. rs_verdict says SONNETOK meanwhile.
    if [ "$cur" = "$sha" ]; then
      say "harvest $tag: Sonnet APPROVE on security-critical paths, NOT ready: Opus confirmation owed (OPUSFINAL-1)"
      [ -n "$REVIEW_DRY" ] || { grep -qx "$pr $sha $tag" $W/opus-confirm-needed.txt 2>/dev/null || echo "$pr $sha $tag" >> $W/opus-confirm-needed.txt; }
    else say "harvest $tag: Sonnet APPROVE but head moved (${sha[1,9]} -> ${cur[1,9]}), needs a new review"; fi
  elif [[ "$last" == *"(APPROVE)"* ]]; then
    if [ "$cur" = "$sha" ]; then ready_add $pr $sha $tag; else say "harvest $tag: APPROVE but head moved (${sha[1,9]} -> ${cur[1,9]}), needs a new review"; fi
  elif [[ "$last" == *"(CHANGES)"* ]]; then
    why=$(grep -m1 -E '^\*\*CHANGES\*\*|CHANGES' $rep | cut -c1-160 | tr '\n' ' ')
    # 2026-10-29 (coordinator, declined-heads-placeholder sweep, site 10): a plain `grep -q "^$pr $sha"` dedup
    # matches ANY line for this PR+head, including MERGE-MASTER's own "waits on independent REVIEW-DEEP"
    # placeholder written when the risk-critical PR got a non-review approval -- so once that placeholder
    # existed, harvest's own real CHANGES verdict was never appended at all (a reproduced defect sat with no
    # declined-heads row and decline_class() callers downstream saw an empty/pending decline forever, so
    # section C/D never reached the DEFECT fixer dispatch). Strip the
    # placeholder the same way every other site does before deciding whether a real row already exists.
    existing=$(grep "^$pr $sha" $W/declined-heads.txt | tail -1); decline_pending_review "$existing" && existing=""
    [ -n "$existing" ] || { [ -n "$REVIEW_DRY" ] || echo "$pr $sha $why $(kx_by)" >> $W/declined-heads.txt; }
    # FSM-FIXALL-1 (D11): the reviewer's structured verdict class, not the prose, decides fixer vs. owner
    dc=$(grep -oE 'DECLINE-CLASS:[[:space:]]*(DEFECT|WAITS-ON-ADMIN|WAITS-ON-OWNER)' $rep | tail -1 | awk '{print $NF}'); dc=${dc#DECLINE-CLASS:}; dc=${dc/WAITS-ON-OWNER/WAITS-ON-ADMIN}
    [ -n "$dc" ] && ! grep -q "^$pr $sha " $W/decline-class.txt 2>/dev/null && { [ -n "$REVIEW_DRY" ] || echo "$pr $sha $dc $tag $(date -u +%FT%TZ)" >> $W/decline-class.txt; }
    say "harvest $tag: CHANGES on #$pr${dc:+ (class $dc)}"
  else
    # FSM-FIXALL-1 (D2b): a verdict other than APPROVE/CHANGES used to be marked harvested and dropped silently
    [ -n "$REVIEW_DRY" ] || echo "- $(date -u +%FT%TZ) REVIEW-UNKNOWN-VERDICT: $tag on #$pr ended '${last[1,100]}' (neither APPROVE nor CHANGES); review-pump will not act on it. Read reports/SESSION-$tag.md." >> $W/FOR-ADMIN.md
    say "harvest $tag: unknown verdict '${last[1,60]}', told owner"
  fi
  [ -n "$REVIEW_DRY" ] || echo "$tag $sha" >> $W/review-harvested.txt
done
# ---- A2. OPUSFINAL-1 sweep (2026-11-22, owner): every Sonnet APPROVE on security-critical paths owes an Opus confirmation. opus-confirm-needed.txt lines: "PR SHA TAG".
# Drop a line when the PR is closed, the head moved (a new review comes anyway) or the head's verdict is no longer SONNETOK (the confirmation wrote its own row);
# otherwise start the confirmation unless one is already in flight (a live brief with "OPUS CONFIRMATION" for this head, no ledger row for its tag, younger than 6 h).
if [ -s $W/opus-confirm-needed.txt ] && [ ! -f $W/OPUSFINAL-OFF ]; then
  _keep=(); _n=0
  while read -r _cp _cs _ct; do
    [ -n "$_cp" ] || continue
    _cc=$(gh pr view $_cp -R $R --json state,headRefOid -q 'if .state=="OPEN" then .headRefOid else "" end' 2>/dev/null </dev/null)
    [ -n "$_cc" ] && [ "$_cc" = "$_cs" ] || { say "OPUSFINAL-1 #$_cp: closed or head moved, confirmation line dropped"; continue; }
    # 2026-11-22 (#N): harvest runs when the report appears, the ledger row a few minutes later; rs_verdict is INFLIGHT in between and the line was dropped
    # as "confirmed", so the Opus confirmation never started. INFLIGHT = the Sonnet review is not closed yet: keep the line, retry next pass.
    _rv=$(rs_verdict $_cp $_cs)
    if [ "$_rv" = INFLIGHT ]; then _keep+=("$_cp $_cs $_ct"); continue; fi
    [ "$_rv" = SONNETOK ] || { say "OPUSFINAL-1 #$_cp ${_cs[1,9]}: confirmed or re-reviewed ($_rv), line dropped"; continue; }
    _keep+=("$_cp $_cs $_ct")
    _fl=""; for _bf in $P/sessions/SESSION-REVIEW-$_cp-DEEP-*.md(N); do
      grep -q "OPUS CONFIRMATION" $_bf 2>/dev/null && grep -q "head $_cs" $_bf 2>/dev/null || continue
      _bt=${${_bf:t}%.md}; _bt=${_bt#SESSION-}
      awk -F'\t' -v t=$_bt '$1==t{f=1} END{exit !f}' $W/review-outcomes.tsv 2>/dev/null && continue
      [ -n "$(find $_bf -mmin +360 -print 2>/dev/null)" ] && continue
      _fl=1
    done
    [ -n "$_fl" ] && continue
    [ $_n -ge 2 ] && continue
    say "OPUSFINAL-1 #$_cp ${_cs[1,9]}: starting the Opus confirmation of $_ct"
    [ -n "$REVIEW_DRY" ] || { RS_FORCE=1 OPUS_CONFIRM=1 zsh $P/bin/mk-reviews-batch.sh $_cp >/dev/null 2>&1; }
    _n=$((_n+1))
  done < $W/opus-confirm-needed.txt
  [ -n "$REVIEW_DRY" ] || { printf '%s\n' "${_keep[@]}" > $W/opus-confirm-needed.txt.new; [ -s $W/opus-confirm-needed.txt.new ] || : > $W/opus-confirm-needed.txt.new; mv $W/opus-confirm-needed.txt.new $W/opus-confirm-needed.txt; }
fi
# ---- candidates
held=" $(sed -nE 's/^HOLD="([^"]*)".*/\1/p' $P/bin/merge-tick.sh | grep -oE '[0-9]{4,5}' | tr '\n' ' ')"
pj=$(gh pr list -R $R --state open --base main --limit 100 --json number,headRefOid,mergeStateStatus,isDraft,files -q '.[]|"\(.number) \(.headRefOid) \(.mergeStateStatus) \(.isDraft) \([.files[].path]|join(","))|0"' 2>/dev/null </dev/null)
[ -z "$pj" ] && { say "gh pr list returned nothing, skipped"; exit 0; }
# REVIEW-PUMP-2 (2026-11-15, five items). Item 4: PRs that already had an approval (their head moved since) go FIRST -- a re-review there is the cheapest way to
# get a mergeable PR back. Item 1: shadow classification of approval carry-over (bin/approval-carry-shadow.sh, logs only). Undo: cp bin/review-pump.sh.bak-1115-pump2 bin/review-pump.sh
prio=" $(cat $P/approved.txt $W/approval-provenance.txt 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
pa=""; pb=""
while IFS= read -r _l; do _n=${_l%% *}; if [[ "$prio" == *" $_n "* ]]; then pa+="$_l"$'\n'; else pb+="$_l"$'\n'; fi; done <<<"$pj"
pj="${pa}${pb}"; pj=${pj%$'\n'}
[ -n "$REVIEW_DRY" ] || (zsh $P/bin/approval-carry-shadow.sh >/dev/null 2>&1 &)
# FSM-FIXALL-1 (D15): only READY-LIST rows the feeder could actually queue count as supply: PR open on main, row head == PR head,
# CLEAN, not held. A merged/parked/dirty row used to count and stopped new reviews exactly when the queue was busy.
supply=0
while read -r rpr rsha rrest; do
  [ -z "$rpr" ] && continue
  [[ "$held" == *" $rpr "* ]] && continue
  waitsA $rpr && continue; grep -Eq "^$rpr( |$)" $P/NEVER-APPROVE.txt 2>/dev/null && continue   # REVIEW-PUMP-2 item 3: rows that cannot enter the queue are not supply
  # 2026-11-18 SUPPLY-2: a DRAFT row or a row whose head is in declined-heads.txt can never be enqueued by the feeder, but counted as supply: 8 such rows
  # (4 drafts, 2 declined, 1 stacked, 1 gated) kept inflight >= the demand cap and blocked every new review while the queue ran dry. Off: touch watchdog/SUPPLY-2-OFF.
  if [ ! -f $W/SUPPLY-2-OFF ]; then
    [[ $'\n'"$pj" == *$'\n'"$rpr $rsha "*" true "* ]] && continue
    grep -q "^$rpr $rsha" $W/declined-heads.txt 2>/dev/null && continue
  fi
  [[ $'\n'"$pj" == *$'\n'"$rpr $rsha CLEAN "* || $'\n'"$pj" == *$'\n'"$rpr $rsha UNKNOWN "* ]] && supply=$((supply+1))
done < $W/READY-LIST.txt
inflight=$supply
running=$(pgrep -fl 'claude.*--settings .*generated/' | grep -oE 'generated/(REVIEW-[0-9]+-DEEP|REVFIX-[0-9]+)[A-Z0-9-]*' | sort -u | wc -l | tr -d ' ')
qn=$(gh api graphql -f query='{repository(owner:"keyorixhq",name:"keyorix"){mergeQueue(branch:"main"){entries(first:5){totalCount}}}}' -q .data.repository.mergeQueue.entries.totalCount 2>/dev/null </dev/null); : ${qn:=0}
inflight=$(( inflight + running + qn ))
# REVIEW-PUMP-2 item 3: in-flight cap follows demand: merges per hour (last 3 h, rounded up) + queue depth ENQUEUE-MAX + 2, floored at 6, ceiling REVIEW-CAP.
# Off: touch watchdog/PUMP-DEMAND-OFF (cap = REVIEW-CAP as before).
ENQ=$(tr -dc 0-9 < $W/ENQUEUE-MAX 2>/dev/null); : ${ENQ:=2}
m3=$(gh pr list -R $R --state merged --base main --limit 40 --json mergedAt -q "[.[]|select(.mergedAt > \"$(date -u -v-3H +%FT%TZ)\")]|length" 2>/dev/null </dev/null)
INFCAP=$MAXINF
if [ ! -f $W/PUMP-DEMAND-OFF ] && [[ "$m3" == <-> ]]; then INFCAP=$(( (m3+2)/3 + ENQ + 2 )); [ $INFCAP -lt 6 ] && INFCAP=6; [ $INFCAP -gt $MAXINF ] && INFCAP=$MAXINF; fi
_since=$(date -u -v-24H +%FT%TZ)
_sh=$(awk -v s=$_since '$1>s' $W/approval-carry-shadow.log 2>/dev/null)
_c=$(echo "$_sh" | grep -c 'MERGE-ONLY clean'); _o=$(echo "$_sh" | grep -c 'MERGE-ONLY overlap'); _x=$(echo "$_sh" | grep -c ' CHANGED'); _u=$(echo "$_sh" | grep -c ' UNKNOWN')
if [ -z "$REVIEW_DRY" ]; then echo "cap $INFCAP/$MAXINF (merges 3h: ${m3:-?}) | ready $supply | running $running | queued $qn | stale-approvals 24h: merge-only clean $_c, overlap $_o, changed $_x, unknown $_u" > $W/review-pump-status.txt.tmp; mv $W/review-pump-status.txt.tmp $W/review-pump-status.txt; fi
while IFS= read -r line; do
  front=${line%%|*}; bad=${line##*|}; read -r pr sha ms dr files <<<"$front"
  [[ "$held" == *" $pr "* ]] && continue
  grep -Eq "^$pr( |$)" $P/NEVER-APPROVE.txt 2>/dev/null && continue
  [ "$dr" = true ] && continue
  waitsA $pr && continue
  grep -q "^$pr $sha" $W/READY-LIST.txt && continue
  # ---- A0. READY-RESTORE-1 (2026-11-07): a PR that was closed and then REOPENED loses its READY-LIST row (ready-feeder drops rows of closed PRs) although
  # the current head still has our APPROVE; it then waited for a second DEEP on Opus (#N: closed 19:59Z by an unknown closer, reopened later, "no DEEP").
  # Restores once per (PR, head), only when ALL hold: this pump already put exactly this head on READY-LIST (log line), the PR has a "reopened" event newer
  # than the head commit, and it is not in the merge queue now (a row consumed by a normal enqueue must not come back). Off: watchdog/READY-RESTORE-OFF.
  if [ ! -f $W/READY-RESTORE-OFF ] && ! grep -qxF "$pr $sha" $W/ready-restored.txt 2>/dev/null && grep -qF "review-pump: READY +#$pr ${sha[1,9]} " $LOG 2>/dev/null; then
    rt=$(gh api repos/$R/issues/$pr/events -q '[.[]|select(.event=="reopened")]|last|.created_at' 2>/dev/null </dev/null)
    ct=$(gh api repos/$R/commits/$sha -q .commit.committer.date 2>/dev/null </dev/null)
    if [ -n "$rt" ] && [ "$rt" != null ] && [ -n "$ct" ] && [[ "$rt" > "$ct" ]]; then
      inq=$(gh api graphql -f query="{repository(owner:\"keyorixhq\",name:\"keyorix\"){pullRequest(number:$pr){mergeQueueEntry{state}}}}" -q '.data.repository.pullRequest.mergeQueueEntry.state' 2>/dev/null </dev/null)
      if [ -z "$inq" ] || [ "$inq" = null ]; then
        [ -n "$REVIEW_DRY" ] || echo "$pr $sha" >> $W/ready-restored.txt
        ready_add $pr $sha "RESTORED-REOPEN"
        continue
      fi
    fi
  fi
  # ---- A1. REVIEW-STATE-1 (2026-11-08): an independent review APPROVEd this exact head, but the PR is not on READY-LIST, not approved, not in the queue and has no real
  # decline (the row was consumed by an enqueue that never happened, or lost). Before this, the pump "healed" such a PR by starting ANOTHER review; now it restores the row once
  # per (PR, head). Off: watchdog/READY-RESTORE-OFF.
  if [ ! -f $W/READY-RESTORE-OFF ] && [ "$ms" = CLEAN ] && ! grep -qxF "$pr $sha" $W/ready-restored.txt 2>/dev/null && rs_cleared $pr $sha \
     && ! grep -qE "^$pr $sha" $P/approved.txt 2>/dev/null; then
    _d=$(grep "^$pr $sha" $W/declined-heads.txt 2>/dev/null | tail -1); decline_pending_review "$_d" && _d=""
    if [ -z "$_d" ]; then
      inq=$(gh api graphql -f query="{repository(owner:\"keyorixhq\",name:\"keyorix\"){pullRequest(number:$pr){mergeQueueEntry{state}}}}" -q '.data.repository.pullRequest.mergeQueueEntry.state' 2>/dev/null </dev/null)
      if [ -z "$inq" ] || [ "$inq" = null ]; then
        [ -n "$REVIEW_DRY" ] || echo "$pr $sha" >> $W/ready-restored.txt
        ready_add $pr $sha "RESTORED-APPROVE"
        continue
      fi
    fi
  fi
  # ---- B. low-risk docs-only
  if [ "$ms" = CLEAN ] && ! grep -q "^$pr $sha" $W/declined-heads.txt 2>/dev/null; then
    only=1; for f in ${(s:,:)files}; do
      case "$f" in docs/adr*|docs/design*|docs/security-closures*|docs/*.tsv|*.tsv|.github/*|scripts/ci*) only=0 ;; docs/*.md|changelog.d/*.md) ;; *) only=0 ;; esac
    done
    [ $only = 1 ] && [ -n "$files" ] && [ "$(gh pr view $pr -R $R --json statusCheckRollup -q '[.statusCheckRollup[]|select(.conclusion!="SUCCESS" and .conclusion!="SKIPPED" and .conclusion!="NEUTRAL")]|length' 2>/dev/null </dev/null)" = 0 ] && { ready_add $pr $sha LOWRISK-DOCS; continue; }
  fi
done <<<"$pj"
# ---- C0. EARLY REVIEW (2026-10-25, item 2): an owner-approved READY-LIST entry with files outside the owner's gates (docs/, changelog.d/,
# .github/, scripts/ci/) needs a deep review before the feeder may queue it. Start it NOW, not when the queue is empty
# (#N waited 16:24-17:01Z in an empty queue for exactly this review). mk-reviews-batch skips a head that already has a brief.
while read -r pr sha tag rest; do
  [[ "$tag" == OWNER-* || "$tag" == ADMIN-* ]] || continue
  grep -l "head $sha" $P/sessions/SESSION-REVIEW-$pr-DEEP-*.md /dev/null 2>/dev/null </dev/null | grep -q . && continue
  other=$(gh pr view $pr -R $R --json files -q '[.files[].path|select(test("^(docs/|changelog\\.d/|\\.github/|scripts/ci/)")|not)]|length' 2>/dev/null </dev/null)
  [ -n "$other" ] && [ "$other" != 0 ] || continue
  say "early review #$pr ${sha[1,9]}: owner-approved, $other code file(s) need a deep review before queueing"
  # 2026-11-01 (the owner asked for fixer sessions only, which also blocked re-reviews): NO-NEW-REVIEWS must only
  # stop a PR that has NEVER had a DEEP review (true new/product work), not re-review after a fixer round -- that
  # re-review is how fixed work gets back to mergeable, i.e. it drains the queue rather than refilling it with new work.
  if [ -f $W/NO-NEW-REVIEWS ]; then
    # 2026-11-02: mk-reviews-batch.sh pre-creates an EMPTY reports/SESSION-REVIEW-$pr-DEEP-N.md right as it starts,
    # so an existence-only check saw that stub and wrongly read it as "already reviewed" -- #N (a genuinely new
    # PR) got its first-ever review dispatched this way. Require a NON-EMPTY (actually completed) report instead.
    [ -z "$(find $P/reports -maxdepth 1 -name "SESSION-REVIEW-$pr-DEEP-*.md" -size +0c -print -quit 2>/dev/null)" ] && { say "skip new review #$pr: NO-NEW-REVIEWS, never reviewed before (owner, 2026-11-01: fixer-only until queue drains)"; continue; }
  fi
  [ -n "$REVIEW_DRY" ] || zsh $P/bin/mk-reviews-batch.sh $pr >/dev/null 2>&1
done < $W/READY-LIST.txt
# ---- C. review / D. fix
# 2026-10-25 READY BUFFER (item 1): normally at most 4 in flight (ready + queued + running review/fix sessions). When fewer than 2 PRs
# are queued or ready, keep starting reviews/fixers up to 4 RUNNING sessions, so the queue has its next PR before it empties.
buf=$(( supply + qn ))
[ -n "$REVIEW_DRY" ] && say "buffer: queued+ready=$buf running=$running inflight=$inflight"
while IFS= read -r line; do
  thr=""; [ $running -ge $MAXINF ] && thr="running sessions $running >= cap $MAXINF"
  [ -z "$thr" ] && [ $inflight -ge $INFCAP ] && [ $buf -ge 2 ] && thr="in flight $inflight >= demand cap $INFCAP (max $MAXINF) with $buf ready/queued"
  front=${line%%|*}; read -r pr sha ms dr files <<<"$front"
  # 2026-11-23 HELD-REVIEW-1 (STUCK-PR-DOCTOR-1 finding; #N held 24 h by queue-failures while its owed deep review could never start): a held PR is still REVIEWED
  # (read-only) when its head is CLEAN; the hold keeps blocking enqueue and fixers (the fixer branch below is skipped for it, queue-failures owns that path).
  # Off: touch watchdog/HELD-REVIEW-OFF (old behaviour: skip everything).
  HELDPR=""
  if [[ "$held" == *" $pr "* ]]; then
    [ -f $W/HELD-REVIEW-OFF ] && { skipnote $pr $sha held "on HOLD"; continue; }
    [ "$ms" = CLEAN ] || { skipnote $pr $sha held "on HOLD (mergeState $ms: no review while held)"; continue; }
    HELDPR=1
  fi
  grep -Eq "^$pr( |$)" $P/NEVER-APPROVE.txt 2>/dev/null && { skipnote $pr $sha never "NEVER-APPROVE"; continue; }
  [ "$dr" = true ] && { skipnote $pr $sha draft "draft"; continue; }
  # 2026-11-05 (fixed live during the hourly queue check): mergeStateStatus=CLEAN used to gate this whole
  # loop, including fixer dispatch -- so a PR already given a CHANGES/DEFECT verdict whose own failing
  # required check IS the reviewed defect (#N: "adr-numbers" fails because of the exact dangling-ledger-
  # row the review found) sat BLOCKED with no fixer ever dispatched. Let BLOCKED through here too; the
  # "start review" branch below still requires CLEAN on its own, so a brand-new review is never started on a
  # non-CLEAN head -- only a head with an already-declined DEFECT verdict can reach the fixer branch while
  # BLOCKED. DIRTY/UNSTABLE/BEHIND/UNKNOWN stay gated out here -- those need a rebase or queue-guard's own
  # MERGE-FIX-AUTO path, not this fixer.
  # 2026-11-18 UNKNOWN-RETRY-1: mergeStateStatus UNKNOWN is GitHub still computing it (92 PRs were skipped on it in ~11 h, 131 skip lines); a single-PR read nudges the computation and
  # usually answers within seconds. Up to 3 reads x 3 s for at most 4 PRs per pump run, then the old skip. Result logged to rounds-opt.log (UNKNOWN-RETRY). Off: touch watchdog/UNKNOWN-RETRY-OFF.
  # 2026-11-18: per-PR+head stamp, at most one retry per 15 min (it was re-reading the same 4 PRs every minute: UNKNOWN that outlasts 3 reads is not computed by GitHub in the next minute either).
  _unk_st=$W/.unk-retry.$pr.${sha[1,9]}
  if [ "$ms" = UNKNOWN ] && [ ! -f $W/UNKNOWN-RETRY-OFF ] && (( ${_unk_n:-0} < 4 )) && [ $(( $(date +%s) - $(stat -f %m $_unk_st 2>/dev/null || echo 0) )) -ge 900 ]; then
    touch $_unk_st
    _unk_n=$(( ${_unk_n:-0} + 1 ))
    for _i in 1 2 3; do sleep 3; _m2=$(gh pr view $pr -R $R --json mergeStateStatus -q .mergeStateStatus 2>/dev/null </dev/null); [ -n "$_m2" ] && [ "$_m2" != UNKNOWN ] && { ms=$_m2; break; }; done
    echo "$(date -u +%FT%TZ) UNKNOWN-RETRY #$pr ${sha[1,9]} -> $ms" >> $W/rounds-opt.log
  fi
  # 2026-11-24 REVIEW-EARLY-1 (SHADOW ONLY; the delay from push to review start is the pre-queue delay): a new review starts only on CLEAN, i.e. after the non-required
  # fuzz shards finish (~40 min). The review is read-only, so it could start while checks are merely RUNNING. Here: log (once per PR+head) when an UNSTABLE
  # head has no failed/cancelled check, only pending ones. No behaviour change. Mode file watchdog/REVIEW-EARLY-MODE = shadow; off: remove the file.
  if [ "$ms" = UNSTABLE ] && [ -f $W/REVIEW-EARLY-MODE ] && ! grep -q "^$pr ${sha[1,9]} " $W/review-early-shadow.log 2>/dev/null; then
    _ew=$(unstable_why $pr $sha 2>/dev/null)
    if [[ -n "$_ew" && "$_ew" != *"check list unavailable"* && "$_ew" != *"no non-passing"* && ! "$_ew" =~ "(FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE|STALE)" ]] \
       && [ -z "$(grep "^$pr $sha" $W/declined-heads.txt 2>/dev/null | tail -1)" ]; then
      echo "${sha[1,9]}" >/dev/null; echo "$pr ${sha[1,9]} $(date +%s) $(date -u +%FT%TZ) would-start-early: $_ew" >> $W/review-early-shadow.log
    fi
  fi
  case "$ms" in CLEAN|BLOCKED) ;; *) skipnote $pr $sha "ms-$ms" "mergeState $ms (needs rebase / CI / queue-guard, not a review)"; continue ;; esac
  waitsA $pr && { skipnote $pr $sha waitsadmin "waits on admin"; continue; }
  grep -q "^$pr $sha" $W/READY-LIST.txt && continue
  # FIXALL-CIDATAGATE-1 (2026-10-28, the gate was narrowed to exempt pure data files): this used to skip EVERY PR touching
  # anything under scripts/ci*, including scripts/ci/guard-inputs.tsv -- a pure coverage-mapping data row, not CI logic, the
  # exact same shape as docs/review-coverage.d/*.tsv (already exempt below). #N and #N each got a one-line guard-inputs.tsv
  # row from a mechanical queue-guard fix and then sat un-reviewed for HOURS with zero log line, because this case silently
  # `continue`d every tick. guard-inputs.tsv is (checked via `gh api .../contents/scripts/ci`) the ONLY .tsv at scripts/ci's top
  # level, so exempting it by exact path, not a scripts/ci/*.tsv glob, can't let an actual CI-logic file slip through unreviewed.
  # The exemption only lets review-pump DISPATCH the normal deep review automatically -- the review itself is unchanged.
  # 2026-11-16 (the gate OK is asked AFTER the review APPROVEs): the review is read-only, so a gated head is reviewed first; enqueueing a gated head still needs
  # the owner's OK recorded for this head (ready-feeder / ci_gate_blocks elsewhere). Before this #N/#N/#N had no review and no ask: nobody moved them.
  if ci_gate_blocks $pr $sha "$files"; then say "gated head #$pr ${sha[1,9]} ($CI_GATE_WHY): reviewing before the gate OK"; fi   # CI changes wait on admin until owner's OK is recorded for this head (lib-dispatch.sh, tested by bin/test-ci-gate.sh)
  # 2026-10-25 (item 2): ADR/design-doc PRs ARE reviewed now (code part), so the review is done when owner approves; queueing still needs the owner's approval
  # approved at this exact head already (kwd approve) -> nothing to review
  # 2026-10-25: no skip for "already approved at this head": #N was approved at its fixer's new head with no review (caller unknown), so approval alone proves nothing; the brief check below prevents duplicate reviews
  # a review brief for this exact head already exists -> in flight or harvested
  dec=$(grep "^$pr $sha" $W/declined-heads.txt | tail -1)
  # 2026-10-29 (only one PR merged during a whole night): MERGE-MASTER's own
  # "risk-critical, new head after <sha> approval; waits on independent REVIEW-DEEP" note (written when a
  # risk-critical PR gets a non-review-session approval, e.g. the coordinator's) is a REMINDER that a review
  # hasn't happened yet, not an actual verdict -- but it matches this exact grep, so `dec` was never empty for
  # that head and the "start review" branch below never ran. The one thing meant to trigger the independent
  # review silenced the mechanism that would dispatch it: #N sat all night with no review and no fixer
  # (decline_class on this prose isn't DEFECT either, so section D's fixer path also skipped it). Strip that
  # placeholder back out here so the head is treated as un-reviewed, same as having no declined-heads entry.
  # 2026-10-29: moved to the shared decline_pending_review() in lib-dispatch.sh (single source of truth after
  # the 9-site sweep) instead of re-typing the string here.
  decline_pending_review "$dec" && dec=""
  # 2026-11-21 WAITS-ADMIN-1: also match "waits on admin" (the 11-07 rename left this exemption on the old spelling: #N sat 55+ min with no review and no log line, I2 breach).
  # 2026-11-16 (the gate OK is asked AFTER the review): a MERGE-MASTER "waits on owner" note about a gated file is not a verdict. With no review verdict on this head it used to set dec, class WAITS-ON-ADMIN, and section C then `continue`d: #N #N never got a review.
  if [ -n "$dec" ] && [[ "$dec" == *"[by:MERGE-MASTER]"* && ( "$dec" == *"waits on owner"* || "$dec" == *"waits on admin"* ) && "$dec" != *(CHANGES|BLOCK|[Dd]efect|[Rr]eviewed)* ]] && [ "$(rs_verdict $pr $sha)" = NONE ]; then dec=""; fi
  # 2026-10-25: this check used to run BEFORE the fixer branch, so a head that had been reviewed (brief exists) and declined with CHANGES never got a fixer: #N, #N, #N sat idle for hours and the queue ran dry. It now only suppresses a duplicate REVIEW.
  [ -z "$dec" ] && ! rs_should_review $pr $sha && continue   # REVIEW-STATE-1: the ledger already has a verdict / a review in flight for this exact head
  [ -z "$dec" ] && grep -l "head $sha" $P/sessions/SESSION-REVIEW-$pr-DEEP-*.md /dev/null 2>/dev/null </dev/null | grep -q . && continue   # /dev/null: with no matching brief grep would read the loop's stdin and end the loop
  if [ -z "$dec" ]; then
    # 2026-11-05: BLOCKED is now let past the top gate (above) so an already-declined DEFECT verdict can get
    # a fixer; a brand-new review must still only start on a CLEAN head, so re-assert that here --
    # EXCEPT (2026-11-06, one PR hit this twice in one night): a head with real
    # failing required checks and NO decline yet (no review has run on THIS exact head) used to be a dead
    # end here when BLOCKED: it can't start a brand-new review (by design, below) and can't reach the fixer
    # branch either (decline_class needs a prior DEFECT verdict, and there isn't one yet for this head).
    # Allow a RE-review (never a brand-new one -- the NO-NEW-REVIEWS check right below is unchanged and
    # still gates that) to start on a BLOCKED head too, same as the fixer branch already can: the review
    # session reads the real CI failure and classifies it DEFECT itself, and the existing, unmodified fixer
    # branch picks it up next tick exactly like any other CHANGES verdict. review-pump still never parses
    # check names itself -- it only stops refusing to ask when there is reason to (prior review history).
    reviewed_before=""
    [ -n "$(find $P/reports -maxdepth 1 -name "SESSION-REVIEW-$pr-DEEP-*.md" -size +0c -print -quit 2>/dev/null)" ] && reviewed_before=1
    if [ "$ms" != CLEAN ]; then
      { [ "$ms" = BLOCKED ] && [ -n "$reviewed_before" ]; } || continue
      # a fixer is actively working this exact PR (dispatch lock held by a live session, e.g. just-dispatched
      # REVFIX-N) -- don't re-review out from under it; its own next head will get its own fresh chance here.
      [ -d $DL_DIR/$pr.lock ] && _dl_held $DL_DIR/$pr.lock && continue
    fi
    if [ -f $W/NO-NEW-REVIEWS ] && [ -z "$reviewed_before" ]; then
      say "skip new review #$pr: NO-NEW-REVIEWS, never reviewed before (owner, 2026-11-01: fixer-only until queue drains)"; continue
    fi
    [ -n "$thr" ] && { skipnote $pr $sha throttle "throttled: $thr"; continue; }
    # REFUSED-DISPATCH-1 (2026-11-21): the batch script's answer used to go to /dev/null, so a refusal ("head already
    # declined", "review state ...") looked like a started review: #N and #N logged "start review" every minute for 40 min / 508 times with no session, and each
    # phantom start also counted against the in-flight cap. Now the answer is read: only "made ..." counts as a start; a refusal is logged once with its reason, and the
    # 5th refusal of the same PR+head inside 30 min raises ONE alarm in FOR-ADMIN.md (STUCK-DISPATCH). Off: touch watchdog/REFUSED-DISPATCH-OFF (old behaviour).
    if [ -f $W/REFUSED-DISPATCH-OFF ] || [ -n "$REVIEW_DRY" ]; then
      say "start review #$pr ${sha[1,9]}${ms:+ (}${ms}${ms:+)}"; [ -n "$REVIEW_DRY" ] || zsh $P/bin/mk-reviews-batch.sh $pr >/dev/null 2>&1; inflight=$((inflight+1)); running=$((running+1)); continue
    fi
    _bo=$(zsh $P/bin/mk-reviews-batch.sh $pr 2>&1 </dev/null | tail -3)
    if [[ "$_bo" == made\ * || "$_bo" == *$'\n'made\ * ]]; then
      say "start review #$pr ${sha[1,9]}${ms:+ (}${ms}${ms:+)}"; inflight=$((inflight+1)); running=$((running+1))
    elif [[ "$_bo" == carried\ * || "$_bo" == *$'\n'carried\ * ]]; then
      say "carried CHANGES verdict #$pr ${sha[1,9]} (CARRY-1: own patch identical to the last CHANGES review, no session)"   # not a refusal, not a start
    else
      _why=${${(f)_bo}[-1]}; skipnote $pr $sha "refused:${_why[1,40]}" "start refused by mk-reviews-batch: ${_why[1,160]:-no output}"
      echo "$pr ${sha[1,9]} $(date +%s)" >> $W/review-refused.txt
      _nref=$(awk -v p=$pr -v h=${sha[1,9]} -v t=$(( $(date +%s) - 1800 )) '$1==p && $2==h && $3>=t' $W/review-refused.txt | wc -l | tr -d ' ')
      if (( _nref >= 5 )) && ! grep -qxF "$pr ${sha[1,9]}" $W/review-refused.alarmed 2>/dev/null; then
        echo "$pr ${sha[1,9]}" >> $W/review-refused.alarmed
        echo "- $(date -u +%FT%TZ) STUCK-DISPATCH: review-pump wants to review #$pr (head ${sha[1,9]}) but mk-reviews-batch refused $_nref times in 30 min: ${_why[1,200]:-no output}. No review session exists, so the PR cannot reach READY-LIST. Look at its declined-heads.txt row." >> $W/FOR-ADMIN.md
      fi
    fi
    continue
  fi
  # FSM-FIXALL-1 (D11): structured class (watchdog/decline-class.txt) instead of matching "owner|author|adr|.github" in the prose.
  # DEFECT-NEEDS-GOAHEAD (#N #N #N #N) waits for "PR" in watchdog/FIX-GOAHEAD.txt; hold-orphan-watch's digest lists them.
  [ -n "$HELDPR" ] && continue   # HELD-REVIEW-1: a held PR gets a review only, never a fixer from this loop
  [ "$(decline_class $pr $sha)" = DEFECT ] || continue
  src=$(decline_source $pr $sha); src=${src:-NOSRC}   # FSM-FIXALL-2: dedup by (PR,SHA,verdict-source), not (PR,SHA) alone -- see decline_source's comment in lib-dispatch.sh
  grep -qx "$pr $sha $src" $W/fix-started.txt && continue
  adrnote=""
  case ",$files," in *,docs/adr*|*,docs/design*)
    # 2026-10-27 (owner decision: keep the exclusion PR-wide, instruct fixers): #N sat CHANGES/DEFECT for ~20h because
    # this exclusion silently dropped it -- no fixer (then-policy) AND no notice to owner (bug, fixed same day).
    # Updated same evening: the exclusion scope itself stays PR-wide (any file touching docs/adr*/docs/design*
    # still lands here), but a fixer now runs for the code-side defect -- it is just told never to touch the
    # ADR/design file itself. Escalation to FOR-ADMIN kept for visibility, not as a block anymore.
    if ! grep -q "^$pr $sha\$" $W/adr-notified.txt 2>/dev/null; then
      [ -n "$REVIEW_DRY" ] || { echo "- $(date -u +%FT%TZ) ADR/DESIGN-DEFECT: #$pr ${sha[1,9]} needs changes (DEFECT-classified); dispatching a fixer with docs/adr*/docs/design* kept out of scope. ${dec[1,160]}" >> $W/FOR-ADMIN.md; echo "$pr $sha" >> $W/adr-notified.txt; }
      say "fixer #$pr ${sha[1,9]}: ADR/design DEFECT, dispatching with docs/adr*/docs/design* out of scope"
    fi
    adrnote="docs/adr* and docs/design* files, even though they are part of this PR's diff -- ADR/architecture-decision and design docs are never edited by an automated fixer (policy since 2026-10-25, precedent #N); fix only the code-side defect and leave those files exactly as they are" ;;
  esac   # 2026-10-27: PR-wide exclusion kept; fixers now run but must not touch the ADR/design file itself
  [ -n "$thr" ] && { skipnote $pr $sha throttlefix "fixer throttled: $thr"; continue; }
  # 2026-11-21 FIXSKIP-1: "start fixer" was logged BEFORE the dispatch and every minute, while fix_round_ok/fixer-precheck refused silently ("nothing to fix"):
  # #N #N #N looked busy in the log for hours while nothing ran. Now: the line means a fixer was really made; a refusal is logged ONCE per (PR, head)
  # with the precheck's own reason.
  if [ -n "$REVIEW_DRY" ]; then say "start fixer #$pr ${sha[1,9]}: ${dec[1,100]}"
  else
    fix_dispatch $pr $sha "${dec#$pr $sha }" "$adrnote" "$src" || { skipnote $pr $sha fixskip "fixer not dispatched (round cap / lock / precheck): $(grep -F "#$pr ${sha[1,9]}" $W/rounds-opt.log 2>/dev/null | tail -1 | cut -c1-200)"; continue; }
    say "start fixer #$pr ${sha[1,9]}: ${dec[1,100]}"
  fi
  inflight=$((inflight+1)); running=$((running+1))
done <<<"$pj"

# ---- E. STUCK-HELD FIX (2026-10-25, item 3: review-pump also fixes small CHANGES on held PRs). A PR can land on HOLD with
# no fixer ever dispatched for it (queue-failures.sh crashed mid-run, or a hold was set by hand for a CI reason) and then just
# sits there, since every other automated path in this file skips anything on HOLD. This catches that gap specifically: a HELD
# PR, CI-caused (not an explicit owner park: it touches no .github/scripts/ci and is not NEVER-APPROVE), with NO fixer tag
# already tracked for it (reapproval-watch.py's job) and none currently running. It gets exactly one bounded fixer, same as
# section D. owner-gated PRs (ADR/design docs, .github, scripts/ci) are never touched here.
if [ $inflight -lt $MAXINF ]; then
  for pr in ${=held}; do
    [ $inflight -ge $MAXINF ] && break
    grep -Eq "^$pr( |$)" $P/NEVER-APPROVE.txt 2>/dev/null && continue
    tracked=$(grep -oE "LOOP-BREAKER: #$pr -> new session \S+|LOOP-BREAKER: #$pr handed to running \S+" $LOG 2>/dev/null | tail -1)
    # FSM-FIXALL-1 (D9): "tracked" only counts when that tag's brief really names this PR. MERGE-FIX-AUTO-<minute-stamp> was minted for
    # #N and #N in the same minute, the second brief overwrote the first, and #N stayed HELD with no fixer, "tracked".
    if [ -n "$tracked" ]; then
      tt=${tracked##* }; tb=$P/sessions/SESSION-$tt.md; [ -f $tb ] || tb=$(ls $P/archive/*/SESSION-$tt.md $P/archive/*/sessions/SESSION-$tt.md 2>/dev/null | head -1)
      if [ -n "$tb" ] && grep -qE "#$pr([^0-9]|\$)" $tb; then continue; fi   # a fixer IS tracked for this hold; reapproval-watch/fixer-liveness own it from here
      say "#$pr: tracked tag $tt has no brief naming #$pr (tag collision or lost brief), treating as untracked"
    fi
    info=$(gh pr view $pr -R $R --json state,headRefOid,isDraft,files -q '"\(.state) \(.headRefOid) \(.isDraft) \([.files[].path]|join(","))"' 2>/dev/null </dev/null)
    read -r prst prsha isdr filelist <<<"$info"
    [ "$prst" = OPEN ] || continue
    [ "$isdr" = true ] && continue   # a draft is mid-work by its own author, not a fixer's job
    gate=0; case ",$filelist," in *,.github/*,*|*,scripts/ci*,*) gate=1 ;; esac
    case ",$filelist," in *,docs/adr*,*|*,docs/design*,*) gate=1 ;; esac   # policy/ADR docs: owner's call, same exclusion as section C/D
    [ "$gate" = 0 ] || continue
    dec=$(grep "^$pr $prsha" $W/declined-heads.txt | tail -1)
    [ -n "$dec" ] && [ "$(decline_class $pr $prsha)" != DEFECT ] && continue   # FSM-FIXALL-1 (D11): a human decision / go-ahead was asked for, not a bug fix
    src=$(decline_source $pr $prsha); src=${src:-NOSRC}   # FSM-FIXALL-2: dedup by (PR,SHA,verdict-source), not (PR,SHA) alone -- see decline_source's comment in lib-dispatch.sh
    grep -qx "$pr $prsha $src" $W/fix-started.txt && continue
    why=$(grep -h "queue-failure #$pr " $W/queue-failures.log $LOG 2>/dev/null | tail -1 | cut -c1-200)
    why=${why:-"on HOLD with no CI failure recorded for it; check the merge-queue run history and fix whatever is blocking it"}
    say "stuck-held fixer #$pr ${prsha[1,9]}: no fixer ever tracked for this hold"
    [ -n "$REVIEW_DRY" ] || fix_dispatch $pr $prsha "$why. The PR is on HOLD: when it is fixed, end the report with the line: READY FOR RE-APPROVAL: #$pr (head <new head sha>)" "" "$src" || continue
    # FSM-FIXALL-1: log it in the LOOP-BREAKER form every tracker reads (this section, reapproval-watch, fixer-liveness, hold-orphan-watch).
    # Before, an E fixer was invisible to them: after it pushed a new head, E saw "no fixer tracked" again and the hold was never lifted.
    [ -n "$REVIEW_DRY" ] || echo "$(ts) LOOP-BREAKER: #$pr -> new session $(awk -v n=$pr '$1==n {t=$3} END{print t}' $W/fix-rounds.txt) (review-pump E, stuck-held)" >> $LOG
    inflight=$((inflight+1)); running=$((running+1))
  done
fi
