# lib-mode.sh -- scheduler MODE (drain|build|mix|auto) + RESERVE.  Source it; no side effects on load.
# 2026-11-06 (a mode for the session scheduler). ONE source of truth: watchdog/MODE (first word):
#   drain  only review/fix class sessions start (REVIEW-, REVFIX, FIX-, MERGE-, REBASE, REPLACE-, QUEUE-, CI-FIX, PR-FIX, RC-FIX, MAIN-RED, FLAKE, UTC-FIX)
#   build  backlog/build sessions first; ONE slot (cap-1 rule) is always kept for review/fix. `kx mode build strict` = builders only
#   mix    everything starts (legacy value "normal" is the same)
#   auto   mode-auto.sh decides drain|build|mix (watchdog/MODE-AUTO-STATE) from the count of ACTIONABLE open PRs
# RESERVE (watchdog/RESERVE, `kx reserve on|off`) overrides every mode: only review/fix class starts, total cap
#   min(TARGET, watchdog/RESERVE-CAP|2), Opus cap min(CAP-OPUS,1) and Opus only for REVIEW-/REVFIX tags. Leaves the weekly budget for manual work.
# SESSIONS-FROZEN is kept as a compatible indicator: present => effective mode drain. A file containing "managed-by-mode" is written/removed
#   by this system; a manual empty `touch SESSIONS-FROZEN` still freezes (and then SESSIONS-FROZEN-ALLOW exact tags also pass, as before).
# Tests: bin/test-mode.sh. Paths overridable for tests: KX_P, KX_MODE_DIR, KX_FROZEN_FILE, KX_FROZEN_ALLOW.
KXP=${KX_P:-$HOME/proj/prompts}; KXMD=${KX_MODE_DIR:-$KXP/watchdog}
KXFZ=${KX_FROZEN_FILE:-$KXP/SESSIONS-FROZEN}; KXAL=${KX_FROZEN_ALLOW:-$KXP/SESSIONS-FROZEN-ALLOW}
mode_raw() { local m; m=$(head -1 $KXMD/MODE 2>/dev/null | awk '{print tolower($1)}'); case $m in drain|build|mix|auto) echo $m;; *) echo mix;; esac; }   # normal/unknown/missing -> mix
_mode_base() {   # raw mode with auto resolved, ignoring the SESSIONS-FROZEN indicator
  local m=$(mode_raw) s
  if [[ $m == auto ]]; then s=$(awk 'NR==1{print $1}' $KXMD/MODE-AUTO-STATE 2>/dev/null); case $s in drain|build|mix) m=$s;; *) m=mix;; esac; fi
  echo $m
}
mode_effective() { if [[ -f $KXFZ ]]; then echo drain; else _mode_base; fi; }
mode_reserve_on() { [[ -f $KXMD/RESERVE ]]; }
mode_legacy_freeze() { [[ -f $KXFZ ]] && ! grep -q 'managed-by-mode' $KXFZ 2>/dev/null; }
tag_class() { if [[ $1 =~ '^(REVIEW-|REVFIX|FIX-|MERGE-|REBASE|REPLACE-|QUEUE-|CI-FIX|PR-FIX|RC-FIX|MAIN-RED|FLAKE|UTC-FIX)' ]]; then echo reduce; else echo build; fi; }
mode_allows() {   # TAG -> rc 0 allow; rc 1 deny with the reason on stdout
  local T=$1 cls m; cls=$(tag_class "$T"); m=$(mode_effective)
  grep -qx "$T" $KXMD/MODE-ALLOW.txt 2>/dev/null && return 0
  if mode_reserve_on; then
    [[ $cls == reduce ]] && return 0
    echo "RESERVE is on: only review/fix sessions start ($T is a $cls session; kx reserve off to lift)"; return 1
  fi
  case $m in
    drain)
      [[ $cls == reduce ]] && return 0
      mode_legacy_freeze && grep -qx "$T" $KXAL 2>/dev/null && return 0
      echo "mode drain: only review/fix sessions start ($T is a $cls session; kx mode mix|build|auto to change)"; return 1 ;;
    build)
      if [[ $cls == reduce && -f $KXMD/MODE-BUILD-STRICT ]]; then echo "mode build (strict): only build sessions start ($T is a review/fix session)"; return 1; fi
      return 0 ;;
    *) return 0 ;;
  esac
}
mode_cap() {      # CAP -> effective total session cap
  local c=$1 r; if mode_reserve_on; then r=$(cat $KXMD/RESERVE-CAP 2>/dev/null); [[ $r == <-> ]] || r=2; (( c > r )) && c=$r; fi; echo $c
}
mode_cap_opus() { # CAP-OPUS -> effective Opus cap
  local c=$1; if mode_reserve_on && (( c > 1 )); then c=1; fi; echo $c
}
mode_opus_ok() {  # TAG MODEL -> rc 1 when RESERVE forbids an Opus session for this tag
  if mode_reserve_on && [[ $2 == opus && ! $1 =~ '^(REVIEW-|REVFIX)' ]]; then return 1; fi; return 0
}
mode_slot_ok() {  # TAG ALL CAP -> rc 1: in build mode a build session may not take the last slot (kept for review/fix)
  local T=$1 all=$2 cap=$3
  [[ $(tag_class "$T") == build ]] || return 0
  mode_reserve_on && return 0
  [[ $(mode_effective) == build ]] || return 0
  [[ -f $KXMD/MODE-BUILD-STRICT ]] && return 0
  (( all < cap - 1 ))
}
mode_ci_ok() {    # TAG -> rc 1 when TAG is a build session and the merge queue is busy (CI runners are shared with merge-group runs)
  # 2026-11-06 (new PRs compete for CI runner slots with PRs in the merge queue and slow down the drain). Reviewers and
  # fixers are never gated. Off: touch watchdog/MODE-CI-GATE-OFF. Threshold: watchdog/CI-GATE-MAX (default 0 = any queue entry blocks).
  # `kx mode auto` escape (auto-state build after a stuck drain) bypasses it. Fails open when GitHub cannot be asked.
  local T=$1 now n ts mx; [[ $(tag_class "$T") == build ]] || return 0
  [[ -f $KXMD/MODE-CI-GATE-OFF ]] && return 0
  [[ $(mode_raw) == auto && $(_mode_base) == build ]] && return 0
  now=$(date +%s); read -r ts n < $KXMD/CI-QUEUE-N 2>/dev/null
  if ! [[ $ts == <-> && $n == <-> && $(( now - ts )) -lt 60 ]]; then
    n=$(gh api graphql -f query='{repository(owner:"keyorixhq",name:"keyorix"){mergeQueue(branch:"main"){entries(first:30){totalCount}}}}' --jq '.data.repository.mergeQueue.entries.totalCount' 2>/dev/null)
    [[ $n == <-> ]] || return 0
    echo "$now $n" > $KXMD/CI-QUEUE-N.$$ && mv -f $KXMD/CI-QUEUE-N.$$ $KXMD/CI-QUEUE-N
  fi
  mx=$(cat $KXMD/CI-GATE-MAX 2>/dev/null); [[ $mx == <-> ]] || mx=0
  (( n > mx )) && return 1; return 0
}
mode_sync_frozen_file() {   # keep SESSIONS-FROZEN as an indicator of effective drain (only the managed copy is ever removed)
  local b=$(_mode_base)
  if [[ $b == drain ]]; then [[ -f $KXFZ ]] || echo managed-by-mode > $KXFZ
  else [[ -f $KXFZ ]] && grep -q 'managed-by-mode' $KXFZ 2>/dev/null && rm -f $KXFZ; fi
  return 0
}
mode_describe() { echo "mode=$(mode_raw) effective=$(mode_effective) reserve=$(mode_reserve_on && echo on || echo off) build-strict=$([[ -f $KXMD/MODE-BUILD-STRICT ]] && echo yes || echo no) auto-state=$(cat $KXMD/MODE-AUTO-STATE 2>/dev/null || echo none)"; }
