#!/bin/zsh
# lib-unstable-why.sh -- UNSTABLE-HEAL-1 (2026-11-22). Sourced by unstable-heal.sh, ready-feeder.sh and review-pump.sh.
#  uh_rollup_rows PR HEAD [TTL]  latest check per (workflow,name) as US-separated rows: name US status US conclusion US time US runid
#                                (ONE `gh pr view --json statusCheckRollup`, cached per PR+head for TTL s, default 60; TTL 0 = always fresh)
#  unstable_why PR HEAD          one line: "family-check CANCELLED(06:18Z), lint CANCELLED(09:12Z)"  (non-passing checks only)
#  stuck_note PR HEAD MS REASON  call every time the feeder skips a READY PR as not CLEAN. After UH_STUCK_SECS (900) of the same reason it
#                                writes ONE line to FOR-ADMIN.md (at most once per PR+head+reason per 6 h) and keeps watchdog/stuck-ready.txt
#                                (read by bin/kx-top) current.   stuck_clear PR  forgets the PR (it is CLEAN again / dropped).
# Needs P, W, R in the caller (ready-feeder / review-pump / unstable-heal set them). Everything here fails open: any error prints a
# placeholder and returns 0, a diagnosis must never break the caller. Env overrides for tests: UH_NOW (epoch seconds).
: ${P:=$HOME/proj/prompts}; : ${W:=$P/watchdog}; : ${R:=keyorixhq/keyorix}
UH_US=$'\x1f'
uh_now() { print -r -- "${UH_NOW:-$(date +%s)}"; }
uh_iso() { date -u -r "$(uh_now)" +%FT%TZ; }

# jq: latest entry per (workflowName,name) -- ordered by startedAt, so a re-queued run beats the cancelled one -- shown with
# completedAt (or startedAt while it runs). StatusContext (legacy status API) rows are mapped onto the same shape.
_UH_JQ='[ .statusCheckRollup[]?
  | if .__typename=="StatusContext"
    then {k:("ctx/"+.context), name:.context, status:(if (.state=="PENDING" or .state=="EXPECTED") then "IN_PROGRESS" else "COMPLETED" end), concl:.state, ord:(.startedAt//""), at:(.startedAt//""), url:(.targetUrl//"")}
    else {k:((.workflowName//"")+"/"+.name), name:.name, status:(.status//""), concl:(.conclusion//""), ord:(.startedAt//""),
          at:(if (.status=="COMPLETED" and (.completedAt//"")!="" ) then .completedAt else (.startedAt//"") end), url:(.detailsUrl//"")} end ]
  | group_by(.k) | map(sort_by(.ord) | last) | .[]
  | [.name,.status,.concl,.at,((.url|capture("/actions/runs/(?<r>[0-9]+)")|.r)? // "")] | join("\u001f")'

uh_rollup_rows() {   # PR HEAD [TTL]  -> rows on stdout; returns 1 when the API call failed (nothing printed)
  local pr=$1 hd=$2 ttl=${3:-60} cdir=$W/unstable-why.cache json c age
  c=$cdir/$pr.${hd[1,9]}.json
  if (( ttl > 0 )) && [ -s $c ]; then
    age=$(( $(uh_now) - $(stat -f %m $c 2>/dev/null || echo 0) ))
    (( age >= 0 && age < ttl )) && { jq -r "$_UH_JQ" < $c 2>/dev/null; return 0; }
  fi
  json=$(gh pr view $pr -R $R --json statusCheckRollup 2>/dev/null </dev/null) || return 1
  [ -n "$json" ] || return 1
  print -r -- "$json" | jq -e . >/dev/null 2>&1 || return 1
  mkdir -p $cdir 2>/dev/null; print -r -- "$json" > $c.tmp.$$ 2>/dev/null && mv $c.tmp.$$ $c 2>/dev/null
  print -r -- "$json" | jq -r "$_UH_JQ"
}

unstable_why() {   # PR HEAD  -> "name STATE(HH:MMZ), ..."  (cached 60 s per PR+head)
  local rows name st cc at rid out="" n=0
  rows=$(uh_rollup_rows $1 $2 ${UH_WHY_TTL:-60}) || { print -r -- "check list unavailable (gh error)"; return 0; }
  while IFS=$UH_US read -r name st cc at rid; do
    [ -z "$name" ] && continue
    if [ "$st" != COMPLETED ]; then cc=${st:l}; cc=${(U)cc}; [ "$cc" = "" ] && cc=PENDING
    else case "$cc" in SUCCESS|SKIPPED|NEUTRAL) continue ;; esac; fi
    out+="${out:+, }$name ${cc:-UNKNOWN}${at:+(${at[12,16]}Z)}"; n=$((n+1))
  done <<<"$rows"
  [ $n -gt 0 ] && print -r -- "$out" || print -r -- "no non-passing check at the latest run (GitHub still computing, or a status outside the check list)"
  return 0
}

# ---- stuck alarm ------------------------------------------------------------------------------------------------------------------
# state $W/stuck-skip.state, rows "first<TAB>PR<TAB>head9<TAB>reasonkey<TAB>alarmed_at(0=never)<TAB>last_seen" (epoch seconds).
# The timer ("same reason for 15 min") restarts when the reason changes or the PR was not evaluated for UH_STUCK_GAP (1200 s);
# the alarm memory of a row survives that, so a flapping PR still alarms at most once per PR+head+reason per 6 h.
stuck_note() {   # PR HEAD MS REASONTEXT
  local pr=$1 hd=$2 ms=$3 why=$4 h9=${2[1,9]} now key st=$W/stuck-skip.state row first alarm last mins sr=$W/stuck-ready.txt
  [ -f $W/UNSTABLE-STUCK-OFF ] && return 0
  now=$(uh_now)
  # the key ignores the times in "(06:18Z)": a rerun that ends CANCELLED again at 09:12Z is still the same reason
  key="$ms ${why//\([0-9][0-9]:[0-9][0-9]Z\)/}"
  touch $st 2>/dev/null || return 0
  first=$now; alarm=0
  row=$(awk -F'\t' -v p="$pr" -v h="$h9" -v k="$key" '$2==p && $3==h && $4==k {print $1 "\t" $5 "\t" $6}' $st | tail -1)
  if [ -n "$row" ]; then
    local -a _f; _f=("${(@ps:\t:)row}"); alarm=${_f[2]:-0}; last=${_f[3]:-0}
    (( now - last <= ${UH_STUCK_GAP:-1200} )) && first=${row%%$'\t'*}
  fi
  mins=$(( (now - first) / 60 ))
  if (( now - first >= ${UH_STUCK_SECS:-900} )) && (( now - alarm >= ${UH_STUCK_DEDUP:-21600} )); then
    alarm=$now
    local hint=""; [ "$ms" = UNSTABLE ] && hint="; unstable-heal reruns only CANCELLED/STALE checks, see watchdog/unstable-heal.log"
    echo "$(uh_iso) READY-FEEDER stuck #$pr $h9 $ms ${mins}m: $why. A READY PR skipped for the same reason${hint}" >> $W/FOR-ADMIN.md
    echo "$(date -u +%H:%MZ) ready-feeder: STUCK alarm #$pr $h9 $ms ${mins}m: $why" >> ${LOG:-$P/merge-tick.log}
  fi
  # rewrite: this PR keeps only rows that carry alarm memory (other reasons/heads) plus the current row; rows unseen for 7 d go
  { awk -F'\t' -v p="$pr" -v h="$h9" -v k="$key" -v n="$now" '!($2==p && $3==h && $4==k) && (n - $6 < 604800) && ($2!=p || $5>0)' $st
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$first" "$pr" "$h9" "$key" "$alarm" "$now"; } > $st.tmp.$$ 2>/dev/null && mv $st.tmp.$$ $st
  # dashboard feed, one row per stuck PR, refreshed each tick: "PR head9 first updated STATE Nm: reason" (bin/kx-top shows rows updated < 5 min ago)
  if (( now - first >= ${UH_STUCK_SECS:-900} )); then
    { awk -v p="$pr" '$1!=p' $sr 2>/dev/null; printf '%s %s %s %s %s %sm: %s\n' "$pr" "$h9" "$first" "$now" "$ms" "$mins" "$why"; } > $sr.tmp.$$ 2>/dev/null && mv $sr.tmp.$$ $sr
  fi
  return 0
}
stuck_clear() {   # PR: it is CLEAN again / dropped. Timer rows go, alarm memory (alarmed_at > 0) stays for the 6 h dedup. Cheap when there is nothing to clear.
  local st=$W/stuck-skip.state sr=$W/stuck-ready.txt
  [ -s $st ] && awk -F'\t' -v p="$1" '$2==p && $5==0 {f=1} END{exit !f}' $st && { awk -F'\t' -v p="$1" '$2!=p || $5>0' $st > $st.tmp.$$ 2>/dev/null && mv $st.tmp.$$ $st; }
  [ -s $sr ] && grep -q "^$1 " $sr 2>/dev/null && { awk -v p="$1" '$1!=p' $sr > $sr.tmp.$$ 2>/dev/null && mv $sr.tmp.$$ $sr; }
  return 0
}
