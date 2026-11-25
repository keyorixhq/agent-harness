#!/bin/zsh
# test-enq-gate.sh -- ENQ-GATE-1: ci_gate_blocks cases + kwd/merge-tick/tick-filler carry the check + the auditor syntax. No GitHub calls.
P=$HOME/proj/prompts; W=$P/watchdog; R=keyorixhq/keyorix; . $P/bin/lib-dispatch.sh
pass=0; fail=0; t() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 (got $1, want $2)"; fi; }
tmp=$(mktemp); echo "77 aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111 [by:kx-gh-approve]" > $tmp; export KX_GHA_FILE=$tmp
ci_gate_blocks 1 sha1 "scripts/ci/mq_slim.py,scripts/ci/mq_slim_test.go"; t $? 0 "scripts/ci blocks"
ci_gate_blocks 1 sha1 ".github/workflows/ci.yml"; t $? 0 ".github blocks"
ci_gate_blocks 1 sha1 "pkg/core/x.go,docs/y.md"; t $? 1 "normal PR passes"
ci_gate_blocks 1 sha1 "scripts/ci/guard-inputs.tsv"; t $? 1 "data-only exempt"
ci_gate_blocks 77 aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111 "scripts/ci/x.py"; t $? 1 "OK row for this head passes"
ci_gate_blocks 77 bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222 "scripts/ci/x.py"; t $? 0 "OK row for another head still blocks"
rm -f $tmp
grep -q 'ENQ-GATE-1' $P/sbin/kwd; t $? 0 "kwd carries ENQ-GATE-1"
grep -q 'CIGATE-FILLER-1' $P/bin/merge-tick.sh; t $? 0 "merge-tick carries the gate"
grep -q 'CIGATE-FILLER-1' $P/bin/tick-filler.sh; t $? 0 "tick-filler carries the gate"
zsh -n $P/bin/queue-gate-audit.sh; t $? 0 "auditor syntax"
grep -q 'queue-gate-audit.sh' $P/bin/dco-heal.sh; t $? 0 "auditor is scheduled"
echo "enq-gate: $pass passed, $fail failed"; [ $fail = 0 ]
