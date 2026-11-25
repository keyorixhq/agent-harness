#!/bin/zsh
# lib-review-state.sh -- REVIEW-STATE-1 (2026-11).
#
# ONE place that answers "what is the review state of (PR, exact head)?", read from the review-outcomes ledger
# (watchdog/review-outcomes.tsv: tag, started, sha9, status, verdict, ended, mins) -- not from brief files and not from
# the wording of MERGE-MASTER's notes in declined-heads.txt.
#
# Incident (2026-11): a deep review had APPROVEd the head, and two sites still got it wrong:
#   1. dedupe: "a review for this head already exists" was answered by looking for SESSION-REVIEW-<PR>-DEEP-*.md in sessions/.
#      Finished sessions are archived to archive/YYYY-MM/, so the check came back empty and review-pump started another
#      Opus review of an already-approved head (and mk-reviews-batch reused the tag REVIEW-N-DEEP-1).
#   2. gate: MERGE-MASTER's note "needs independent REVIEW-N-DEEP on this head" was matched by wording; a new wording slipped
#      past the matcher and ready-feeder skipped the PR for 10+ ticks, and `kwd approve` found no provenance.
#
#  rs_verdict PR SHA      APPROVE | CHANGES | UNPARSED | DONE (DONE row, no verdict) | INFLIGHT | DIED | LEGACY | NONE
#                           APPROVE/CHANGES/UNPARSED/DONE: the last DONE row for this exact head in the ledger.
#                           INFLIGHT: a brief for this head exists in sessions/, its tag has no ledger row, younger than 6 h.
#                           DIED: only DIED/KILLED rows for this head (a review was dispatched and did not finish).
#                           LEGACY: only an archived brief for this head, no ledger row (reviews before 2026-11-07).
#                           NONE: nothing known for this head.
#  rs_should_review PR SHA   exit 0 only for NONE or DIED: a verdict, an in-flight session or a legacy review on this exact head
#                           means a new review would be a duplicate. Off switch: watchdog/REVIEW-STATE-OFF (always exit 0).
#  rs_next_tag PR         next free N for REVIEW-<PR>-DEEP-N across sessions/, archive/, ledger and status/ (never reuses a number)
#  rs_prev_head PR        full 40-char head of the newest brief (live or archived) for the PR, for REVIEW-DELTA-1
#                           SONNETOK (OPUSFINAL-1): the last review of this head was a Sonnet APPROVE on security-critical paths; an Opus confirmation is owed.
#  rs_cleared PR SHA      exit 0 if rs_verdict is APPROVE (an independent review cleared this exact head)
: ${P:=$HOME/proj/prompts}; : ${W:=$P/watchdog}
RS_OUT=${RS_OUT:-$W/review-outcomes.tsv}
RS_INFLIGHT_MIN=${RS_INFLIGHT_MIN:-360}

rs_briefs() { print -l $P/sessions/SESSION-REVIEW-$1-DEEP-*.md(N) $P/archive/*/SESSION-REVIEW-$1-DEEP-*.md(N); }

rs_verdict() {
  local pr=$1 sha=$2 s9=${2[1,9]} v f tag par pv
  [[ -n $pr && ${#sha} -ge 9 ]] || { echo NONE; return; }
  # 1. ledger: the last DONE row for this exact head wins
  v=$(awk -F'\t' -v pre="REVIEW-$pr-DEEP-" -v s9=$s9 'index($1,pre)==1 && $3==s9 && $4=="DONE" {last=($5==""?"DONE":$5); n=1} END{if(n) print last}' $RS_OUT 2>/dev/null)
  # OPUSFINAL-1 (2026-11): a Sonnet APPROVE on security-critical paths (tag in watchdog/sec-sonnet-tags.txt) is not final: SONNETOK until a later review of this
  # head (the Opus confirmation) wrote its own DONE row. Off: touch watchdog/OPUSFINAL-OFF (then the Sonnet APPROVE counts as before).
  if [[ ${(U)v} == APPROVE && ! -f $W/OPUSFINAL-OFF ]]; then
    lt=$(awk -F'\t' -v pre="REVIEW-$pr-DEEP-" -v s9=$s9 'index($1,pre)==1 && $3==s9 && $4=="DONE" {t=$1} END{print t}' $RS_OUT 2>/dev/null)
    [ -n "$lt" ] && grep -qx "$lt" $W/sec-sonnet-tags.txt 2>/dev/null && { echo SONNETOK; return; }
  fi
  if [ -n "$v" ]; then echo ${(U)v}; return; fi
  # 1b. CLEAN-MERGE-1 (2026-11): a head that is a verified clean merge of origin/main into an APPROVEd head
  #     (clean-merge-reapprove wrote "PR NEWSHA CLEAN-MERGE from PARENT8" after recomputing the tree) inherits the APPROVE:
  #     the code under review did not change, so a delta review is pure cost (a later review ran on it and declined 3 LOWs
  #     the earlier APPROVE had already weighed). Only APPROVE is inherited; a parent with CHANGES is not.
  par=$(awk -v n=$pr -v h=$sha '$1==n && $2==h && $3=="CLEAN-MERGE" && $4=="from" {print $5; exit}' $W/approval-provenance.txt 2>/dev/null)
  if [ -n "$par" ]; then
    pv=$(awk -F'\t' -v pre="REVIEW-$pr-DEEP-" -v p8=${par[1,8]} 'index($1,pre)==1 && substr($3,1,8)==p8 && $4=="DONE" {last=($5==""?"DONE":$5); n=1} END{if(n) print last}' $RS_OUT 2>/dev/null)
    if [[ ${(U)pv} == APPROVE ]]; then
      lt=$(awk -F'\t' -v pre="REVIEW-$pr-DEEP-" -v p8=${par[1,8]} 'index($1,pre)==1 && substr($3,1,8)==p8 && $4=="DONE" {t=$1} END{print t}' $RS_OUT 2>/dev/null)
      if [ -n "$lt" ] && [ ! -f $W/OPUSFINAL-OFF ] && grep -qx "$lt" $W/sec-sonnet-tags.txt 2>/dev/null; then echo SONNETOK; else echo APPROVE; fi; return
    fi
  fi
  # 2. in flight: live brief for this head, no ledger row for its tag yet, not older than RS_INFLIGHT_MIN
  for f in $P/sessions/SESSION-REVIEW-$pr-DEEP-*.md(N); do
    grep -q "head $sha" $f 2>/dev/null || continue
    tag=${${f:t}%.md}; tag=${tag#SESSION-}
    awk -F'\t' -v t=$tag '$1==t{f=1} END{exit !f}' $RS_OUT 2>/dev/null && continue
    [ -n "$(find $f -mmin +$RS_INFLIGHT_MIN -print 2>/dev/null)" ] && continue
    echo INFLIGHT; return
  done
  # 3. died: ledger rows for this head, none of them DONE
  if awk -F'\t' -v pre="REVIEW-$pr-DEEP-" -v s9=$s9 'index($1,pre)==1 && $3==s9 {f=1} END{exit !f}' $RS_OUT 2>/dev/null; then echo DIED; return; fi
  # 4. legacy: an archived brief for this head from before the ledger existed
  for f in $P/archive/*/SESSION-REVIEW-$pr-DEEP-*.md(N); do
    grep -q "head $sha" $f 2>/dev/null || continue
    tag=${${f:t}%.md}; tag=${tag#SESSION-}
    awk -F'\t' -v t=$tag '$1==t{f=1} END{exit !f}' $RS_OUT 2>/dev/null && continue
    echo LEGACY; return
  done
  echo NONE
}

rs_should_review() {
  [ -f $W/REVIEW-STATE-OFF ] && return 0
  [ -n "${RS_FORCE:-}" ] && return 0   # a deliberate re-review of the same head
  case "$(rs_verdict $1 $2)" in NONE|DIED) return 0 ;; *) return 1 ;; esac
}

rs_cleared() { [ "$(rs_verdict $1 $2)" = APPROVE ]; }

rs_next_tag() {
  local pr=$1 k m=0 f
  for f in $(rs_briefs $pr) $P/status/REVIEW-$pr-DEEP-*.json(N) $P/reports/SESSION-REVIEW-$pr-DEEP-*.md(N); do
    k=${f##*DEEP-}; k=${k%%[!0-9]*}; [[ $k == <-> ]] && (( k > m )) && m=$k
  done
  for k in $(awk -F'\t' -v pre="REVIEW-$pr-DEEP-" 'index($1,pre)==1{sub(pre,"",$1); print $1}' $RS_OUT 2>/dev/null); do
    [[ $k == <-> ]] && (( k > m )) && m=$k
  done
  echo $((m+1))
}

rs_prev_head() {
  local f
  f=$(ls -t $(rs_briefs $1) 2>/dev/null | head -1)
  [ -n "$f" ] && grep -oE 'head [0-9a-f]{40}' "$f" 2>/dev/null | head -1 | awk '{print $2}'
}
