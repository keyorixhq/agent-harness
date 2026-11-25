#!/bin/zsh
# start-when-opus.sh TAG: start the session when fewer than 2 Opus sessions and fewer than 6 sessions run.
T=$1; P=~/proj/prompts
. $P/bin/lib-mode.sh   # 2026-11-06 MODE system (drain/build/mix/auto + RESERVE); bin/lib-mode.sh
if ! _why=$(mode_allows "$T"); then echo "$(date -u +%H:%MZ) REFUSED start $T: $_why" >> $P/merge-tick.log; echo "$T $(date +%s) refused" >> $P/watchdog/FROZEN-WAITERS.txt; exit 1; fi   # bin/freeze-resume.sh restarts it once the mode allows it (24 h window)
# 2026-10-22: a restarted session inherits its old report, whose last line "<TAG> DONE" makes reap-done-sessions.sh kill it a few
# minutes in (three sessions died this way mid-work). Append a restart note so the report no longer ends with the DONE line.
rep=$P/reports/SESSION-$T.md
if [ -r "$rep" ] && [[ "$(grep -v '^[[:space:]]*$' "$rep" | tail -1)" == *"$T DONE"* ]]; then
  printf '\n(run restarted %s by the coordinator; the earlier completion line is superseded; add a new completion line when this run ends)\n' "$(date '+%F %H:%M')" >> "$rep"
fi
while true; do
  # 2026-10-24 (owner: session freeze): a waiter created before SESSIONS-FROZEN was touched must not start afterwards.
  if ! _why=$(mode_allows "$T"); then echo "$(date -u +%H:%MZ) waiter $T stopped: $_why (re-run start-when-slot.sh $T after the mode allows it)" >> $P/watchdog/start-when.log; echo "$T $(date +%s) stopped" >> $P/watchdog/FROZEN-WAITERS.txt; exit 0; fi
  # 2026-10-11: one starter at a time (three starters raced at 06:54Z and 7 sessions ran);
  # hold the lock until the new session's process is visible to pgrep.
  # 2026-10-12: a starter killed while holding the lock left it behind for 40 min; break locks older than 5 min.
  [ -d /tmp/kx-start.lock ] && [ $(( $(date +%s) - $(stat -f %m /tmp/kx-start.lock) )) -gt 300 ] && rmdir /tmp/kx-start.lock 2>/dev/null
  if mkdir /tmp/kx-start.lock 2>/dev/null; then
    trap 'rmdir /tmp/kx-start.lock 2>/dev/null; rm -f $idlef' EXIT
    idlef=$(mktemp /tmp/kx-idle.XXXXXX); python3 $P/bin/idle-tags.py > $idlef 2>/dev/null   # 2026-11-12: waiting (idle) sessions do not hold a slot
    all=$(pgrep -fl 'claude.*--settings .*generated/' | grep -oE 'generated/[A-Z0-9-]+' | sed 's#generated/##' | sort -u | grep -vxFf $idlef | wc -l)
    # 2026-10-18 (owner): separate caps per model. watchdog/CAP-OPUS (default 1) and CAP-SONNET (default 5) limit how
    # many sessions of each model run; the total cap (watchdog/TARGET) still applies. Running sessions are not killed
    # when a cap is lowered; new ones of that model just wait. Model of the new session = its "Recommended model:" line.
    mf=$(setopt null_glob; ls $P/sessions/SESSION-$T*.md $P/sessions/$T*.md 2>/dev/null | head -1)   # zsh aborts on an unmatched glob without null_glob
    newm=$(grep -m1 '^Recommended model:' "$mf" 2>/dev/null | sed 's/^Recommended model://' | awk '{print tolower($1)}')
    # 2026-10-26 (coordinator, CONCURRENCY-GUARD-1 -> CONCURRENCY-GUARD-2): a brief with no "Recommended model:" line
    # used to default to opus SILENTLY (the most expensive, most capped model) -- found when two feature sessions
    # both defaulted to opus with nobody noticing. A warning (GUARD-1) is not enough: a check
    # that only logs is a check nobody has to act on. REFUSE instead, immediately, so every session gets an explicit
    # model, never a silent guess at the most expensive one. Audit of existing briefs: 80 of 296 (27%) had no line --
    # all from hand-written briefs (the generator scripts bin/mk-fixer.sh / bin/mk-reviews-batch.sh always write one).
    # This is a correctness gate, not a retry-later gate: loop-waiting for a human to edit a file nobody is told
    # about helps no one, so exit now with a loud, specific error instead of silently starting or silently hanging.
    case "$newm" in opus*) newm=opus ;; sonnet*) newm=sonnet ;; haiku*) newm=haiku ;; *) newm="" ;; esac
    # empty here means either no line at all, or a line whose first word isn't opus/sonnet/haiku (a typo, a
    # different model name) -- bin/start-session has this exact same silent "no Recommended model line,
    # defaulting to opus" fallback independently, so catching both cases HERE is what stops it ever being reached.
    if [[ -z "$newm" ]]; then
      echo "$(date -u +%H:%MZ) REFUSED start $T: brief $mf has no usable 'Recommended model:' line (must start with opus/sonnet/haiku) -- add one (e.g. 'Recommended model: Sonnet - <why>') and re-run start-when-slot.sh $T" >> $P/watchdog/start-when.log
      echo "- $(date -u +%FT%H:%MZ) REFUSED $T: no usable 'Recommended model:' line in $mf; add one and re-dispatch" >> $P/watchdog/FOR-ADMIN.md
      rmdir /tmp/kx-start.lock 2>/dev/null
      exit 1
    fi
    nop=$(pgrep -fl 'run-session.sh' | grep -oE ' (opus|sonnet|haiku) [A-Z0-9-]+ (sandbox|legacy)' | grep ' opus ' | awk '{print $2}' | grep -vxFf $idlef | wc -l | tr -d ' ')
    nso=$(pgrep -fl 'run-session.sh' | grep -oE ' (opus|sonnet|haiku) [A-Z0-9-]+ (sandbox|legacy)' | grep ' sonnet ' | awk '{print $2}' | grep -vxFf $idlef | wc -l | tr -d ' ')
    capop=1; [[ "$(cat $P/watchdog/CAP-OPUS 2>/dev/null)" =~ ^[0-9]$ ]] && capop=$(cat $P/watchdog/CAP-OPUS)
    capop=$(mode_cap_opus $capop)   # RESERVE: Opus cap 1
    capso=5; [[ "$(cat $P/watchdog/CAP-SONNET 2>/dev/null)" =~ ^[0-9]$ ]] && capso=$(cat $P/watchdog/CAP-SONNET)
    modelok=1
    mode_opus_ok "$T" "$newm" || modelok=0   # RESERVE: Opus only for REVIEW-/REVFIX
    mode_ci_ok "$T" || { modelok=0; echo "$(date -u +%H:%MZ) waiting to start $T: merge queue busy (CI-QUEUE-GATE; build sessions wait so PR CI does not compete with merge-group runs; touch watchdog/MODE-CI-GATE-OFF to disable)" >> $P/watchdog/start-when.log; }
    [ "$newm" = opus ] && [ "$nop" -ge "$capop" ] && modelok=0
    [ "$newm" = sonnet ] && [ "$nso" -ge "$capso" ] && modelok=0
    # 2026-10-23 load gate: do not start a session while the 1-minute load average is above watchdog/LOADMAX (default 24 on this
    # machine); at load 40 every running session's shell commands queued for minutes. Off switch: touch $P/LOAD-GATE-OFF.
    if [ ! -f $P/LOAD-GATE-OFF ]; then
      _lm=24; [[ "$(cat $P/watchdog/LOADMAX 2>/dev/null)" =~ ^[0-9]+$ ]] && _lm=$(cat $P/watchdog/LOADMAX)
      _ld=$(sysctl -n vm.loadavg | awk '{printf "%d", $2}')
      # 2026-11-15 load priority: review/fix/digest sessions drain the PR queue, build and fuzz sessions only add to it. Under load the
      # builds wait first: they need load <= LOADMAX-8 (min 12), review/fix/merge-fix/digest keep LOADMAX. Off: touch $P/LOAD-PRIO-OFF.
      if [ ! -f $P/LOAD-PRIO-OFF ] && ! [[ "$T" =~ ^(REVIEW|REVFIX|MERGE-FIX|DIGEST|CI-FIX|PR-FIX|RC-FIX|REPLACE) ]]; then _lm=$(( _lm > 20 ? _lm - 8 : 12 )); fi
      if [ "$_ld" -gt "$_lm" ]; then modelok=0; echo "$(date -u +%H:%MZ) waiting to start $T: load $_ld > $_lm (LOAD-GATE)" >> $P/watchdog/start-when.log; fi
    fi
    # 2026-10-24 RAMDISK gate (SANDBOX-HYGIENE-1): the shared RAM disk for GOTMPDIR hit 97% and tests failed with
    # "no space left on device". Do not start a session while it is above watchdog/RAMDISKMAX percent (default 85).
    # Not applied when the RAM disk is off or not mounted. Off switch: touch $P/RAMDISK-GATE-OFF.
    if [ ! -f $P/RAMDISK-GATE-OFF ] && [ ! -f $P/RAMDISK-OFF ] && [ -d /Volumes/RAMDISK/gotmp ]; then
      _km=85; [[ "$(cat $P/watchdog/RAMDISKMAX 2>/dev/null)" =~ ^[0-9]+$ ]] && _km=$(cat $P/watchdog/RAMDISKMAX)
      _kp=$(df -P /Volumes/RAMDISK 2>/dev/null | awk 'NR==2{sub("%","",$5); print $5}')
      if [[ "$_kp" =~ ^[0-9]+$ ]] && [ "$_kp" -gt "$_km" ]; then modelok=0; echo "$(date -u +%H:%MZ) waiting to start $T: RAMDISK ${_kp}% used > ${_km}% (RAMDISK-GATE; see du -sh /Volumes/RAMDISK/gotmp/*)" >> $P/watchdog/start-when.log; fi
    fi
    # 2026-10-23 WIP gate (code is written faster than it is checked and merged): while more than WIPMAX (default 50, file
    # watchdog/WIPMAX) non-draft PRs are open, only sessions that REDUCE the backlog start (fix/merge/rebase/review/replace/
    # smoke/main-red/planner). Count cached 5 min. Off switch: touch $P/WIP-GATE-OFF.
    if [ ! -f $P/WIP-GATE-OFF ] && ! grep -qx "$T" $P/watchdog/WIP-ALLOW.txt 2>/dev/null && ! [[ "$T" =~ ^(MERGE-|REBASE|FIX-|REVIEW|REPLACE-|QUEUE-|CI-FIX|PR-FIX|RC-FIX|SMOKE-|MAIN-RED|UTC-FIX|SUPERFAN|PLANNER|MUTANT-|FLAKE|TEST-HYGIENE) ]]; then
      _wf=$P/watchdog/wip-count.txt; _wn=$(cat $_wf 2>/dev/null | awk '{print $1}'); _wt=$(cat $_wf 2>/dev/null | awk '{print $2}')
      if [ -z "$_wt" ] || [ $(( $(date +%s) - _wt )) -gt 300 ]; then
        _wn=$(gh pr list -R keyorixhq/keyorix --state open --limit 300 --json isDraft -q '[.[]|select(.isDraft|not)]|length' 2>/dev/null)
        [[ "$_wn" =~ ^[0-9]+$ ]] && echo "$_wn $(date +%s)" > $_wf || _wn=0
      fi
      _wm=50; [[ "$(cat $P/watchdog/WIPMAX 2>/dev/null)" =~ ^[0-9]+$ ]] && _wm=$(cat $P/watchdog/WIPMAX)
      if [ "${_wn:-0}" -gt "$_wm" ]; then modelok=0; echo "$(date -u +%H:%MZ) waiting to start $T: $_wn open PRs > $_wm (WIP-GATE)" >> $P/watchdog/start-when.log; fi
    fi
    (( modelok )) || echo "$(date -u +%H:%MZ) waiting to start $T: $newm cap reached (opus $nop/$capop, sonnet $nso/$capso)" >> $P/watchdog/start-when.log
    # 2026-10-19 hot-file gate: a brief may declare "Hot-files: main.go config routes openapi" (the shared wiring
    # files that caused about half of all PR collisions, see COMMON-RULES.md). Do not start it while a running session declares
    # the same token. Briefs without the line are not gated. Off switch: touch $P/HOT-GATE-OFF.
    hotok=1
    # 2026-10-27 (coordinator): "Hot-files: none" was matched as a real token named 'none', so any two briefs declaring
    # none blocked each other (88 waits logged). Placeholders mean "no hot file".
    newhot=$(grep -m1 '^Hot-files:' "$mf" 2>/dev/null | sed 's/^Hot-files://' | sed -E 's/(^|[[:space:]])(none|None|NONE|-|n\/a)([[:space:]]|$)/ /g')
    if [ -n "${newhot// /}" ] && [ ! -f $P/HOT-GATE-OFF ]; then
      for rt in $(pgrep -fl 'claude.*--settings .*generated/' | grep -oE 'generated/[A-Z0-9-]+' | cut -d/ -f2 | sort -u); do
        [ "$rt" = "$T" ] && continue
        rf=$(setopt null_glob; ls $P/sessions/SESSION-$rt*.md $P/sessions/$rt*.md 2>/dev/null | head -1)
        rh=$(grep -m1 '^Hot-files:' "$rf" 2>/dev/null | sed 's/^Hot-files://' | sed -E 's/(^|[[:space:]])(none|None|NONE|-|n\/a)([[:space:]]|$)/ /g')
        for h in ${=newhot}; do
          [[ " ${rh} " == *" $h "* ]] && { hotok=0; echo "$(date -u +%H:%MZ) waiting to start $T: hot file '$h' is in use by running session $rt" >> $P/watchdog/start-when.log; break 2; }
        done
      done
    fi
    # 2026-10-21 (file-ownership/collision work): a brief may declare "Paths: pkg/core server/handlers web/src" (path
    # prefixes the session edits). Do not start it while a running session declares an overlapping prefix (one is a prefix of
    # the other). Briefs without the line are not gated. Off switch: touch $P/PATH-GATE-OFF.
    newpaths=$(grep -m1 '^Paths:' "$mf" 2>/dev/null | sed 's/^Paths://')
    if [ -n "${newpaths// /}" ] && [ ! -f $P/PATH-GATE-OFF ] && (( hotok )); then
      for rt in $(pgrep -fl 'claude.*--settings .*generated/' | grep -oE 'generated/[A-Z0-9-]+' | cut -d/ -f2 | sort -u); do
        [ "$rt" = "$T" ] && continue
        rf=$(setopt null_glob; ls $P/sessions/SESSION-$rt*.md $P/sessions/$rt*.md 2>/dev/null | head -1)
        rp=$(grep -m1 '^Paths:' "$rf" 2>/dev/null | sed 's/^Paths://')
        for a in ${=newpaths}; do for b in ${=rp}; do
          a=${a%/}; b=${b%/}
          if [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]]; then hotok=0; echo "$(date -u +%H:%MZ) waiting to start $T: path '$a' overlaps '$b' of running session $rt" >> $P/watchdog/start-when.log; break 3; fi
        done; done
      done
    fi
    op=0
    # 2026-10-17 (so the Mac stops swapping): memory gate on top of the 6-session cap. Start only when
    # macOS reports >= 40% memory free and swap has not grown by more than 256 MB since the last check.
    memfree=$(sysctl -n kern.memorystatus_level 2>/dev/null || echo 100)
    swapmb=$(sysctl vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/' | cut -d. -f1)
    # 2026-10-27 (coordinator): several waiters write this file at once; a reader that catches it mid-truncate got "",
    # $(( swapmb - lastsw )) became the whole swap size (3446 > 256) and the gate blocked every start forever.
    # Non-numeric -> no growth; write atomically via a temp file.
    SWF=$P/watchdog/swap-last.txt; lastsw=$(cat $SWF 2>/dev/null); [[ "$lastsw" =~ ^[0-9]+$ ]] || lastsw=$swapmb
    [[ "$swapmb" =~ ^[0-9]+$ ]] && { echo $swapmb > $SWF.$$ && mv -f $SWF.$$ $SWF; }
    memok=1; { [ "$memfree" -lt 40 ] || [ $(( swapmb - lastsw )) -gt 256 ]; } && memok=0
    (( memok )) || echo "$(date -u +%H:%MZ) waiting to start $T: memory free ${memfree}%, swap ${lastsw}->${swapmb} MB" >> $P/watchdog/start-when.log
    cap=6; [[ "$(cat $P/watchdog/TARGET 2>/dev/null)" =~ ^[0-9]$ ]] && cap=$(cat $P/watchdog/TARGET)   # kx cap N
    cap=$(mode_cap $cap)   # RESERVE: total cap (default 2)
    if (( modelok )) && (( hotok )) && [ $all -lt $cap ] && (( memok )) && mode_slot_ok "$T" $all $cap; then # 2026-10-17: verify the session really started (a PLANNER session got a window but no claude process);
    # retry once, then report START-FAILED instead of silently losing the slot.
    for try in 1 2; do
      zsh $P/bin/start-session $T >> $P/watchdog/start-when.log 2>&1; echo "$(date -u +%H:%MZ) started $T (try $try)" >> $P/watchdog/start-when.log
      ok=0; for i in {1..12}; do sleep 10; pgrep -f "generated/$T.json" >/dev/null && { ok=1; break; }; done
      (( ok )) && break
    done
    rmdir /tmp/kx-start.lock
    if (( ! ok )); then echo "$(date -u +%H:%MZ) START-FAILED $T: no claude process after 2 tries" >> $P/merge-tick.log; echo "- $(date -u +%FT%H:%MZ) START-FAILED $T (no claude process after 2 tries; see watchdog/start-when.log)" >> $P/watchdog/FOR-ADMIN.md; exit 1; fi
    exit 0; fi
    rmdir /tmp/kx-start.lock
  fi
  sleep 120
done
