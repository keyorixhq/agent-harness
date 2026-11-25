#!/bin/zsh
# lib-log.sh -- STANDARD LOGGING for every script we write (rule since 2026-11-24: any new script gets logging).
# Source it:   . $HOME/proj/prompts/bin/lib-log.sh ; KLOG_NAME=my-script        (default name = script file name without extension)
#   klog "message"            one line "2026-11-24T08:00:00Z my-script: message" appended to watchdog/<name>.log (fails open, never breaks the caller)
#   klog_act "what" "target"  an ACTION (delete, push, rerun, close, write a mode/ledger file): always log it, with its target
# Rules: (1) log every decision that changes something, with the PR/tag/path it touched; (2) log skips with the REASON, once per state change, not every run;
# (3) log the start/end only for runs longer than ~10 s; (4) no secrets/tokens in a log line; (5) logs live in watchdog/ and are trimmed by prune-logs
# (keep <= 5000 lines). Python scripts: use logging or append the same line format to watchdog/<name>.log. Tests: KLOG_FILE=/dev/null.
: ${P:=$HOME/proj/prompts}
klog() {
  local n=${KLOG_NAME:-${${0:t}%.*}} f=${KLOG_FILE:-$P/watchdog/${KLOG_NAME:-${${0:t}%.*}}.log}
  print -r -- "$(date -u +%FT%TZ) $n: $*" >> $f 2>/dev/null; return 0
}
klog_act() { klog "ACT $1 ${2:+-> $2}"; }
