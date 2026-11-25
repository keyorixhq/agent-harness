#!/bin/zsh
# review-state.test.zsh -- REVIEW-STATE-1 regression tests (offline, fixture dirs only; touches nothing real).
#   zsh tests/review-state.test.zsh      -> prints PASS/FAIL per case, exit 1 on any FAIL
# Needs bin/lib-review-state.sh (included).
SELF=${${(%):-%x}:A}; REPO=${SELF:h:h}
T=$(mktemp -d); trap 'rm -rf $T' EXIT
export P=$T W=$T/watchdog
mkdir -p $W $T/sessions $T/archive/2026-11 $T/status $T/reports $T/bin
cp $REPO/bin/lib-review-state.sh $T/bin/
. $T/bin/lib-review-state.sh
fails=0
ok()   { print "PASS  $1"; }
bad()  { print "FAIL  $1  (got: $2)"; fails=$((fails+1)); }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2"; }
tab()  { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> $W/review-outcomes.tsv; }
# synthetic heads: the ledger keys on the first 9 characters
H1=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111; H2=bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222; H3=1111111112222222333333334444444455555555
HD=cccc3333cccc3333cccc3333cccc3333cccc3333; HC=dddd4444dddd4444dddd4444dddd4444dddd4444

# 1. the incident: DONE/APPROVE in the ledger, the brief already archived -> APPROVE, no new review
tab REVIEW-100-DEEP-3 2026-11-08T04:23:39Z aaaa1111a DONE APPROVE 2026-11-08T04:33:39Z 10
echo "[REVIEW-100-DEEP-3] ... head $H1 ..." > $T/archive/2026-11/SESSION-REVIEW-100-DEEP-3.md
eq "archived brief + DONE/APPROVE row = APPROVE" "$(rs_verdict 100 $H1)" APPROVE
rs_should_review 100 $H1 && bad "no duplicate review of an APPROVEd head" start || ok "no duplicate review of an APPROVEd head"
rs_cleared 100 $H1 && ok "rs_cleared true on APPROVE" || bad "rs_cleared true on APPROVE" no

# 2. a DIED dispatch does not count as a review
tab REVIEW-100-DEEP-1 2026-11-07T22:40:46Z cccc3333c DIED "" 2026-11-07T23:11:55Z 31
eq "DIED row only = DIED" "$(rs_verdict 100 $HD)" DIED
rs_should_review 100 $HD && ok "a DIED head may be reviewed again" || bad "a DIED head may be reviewed again" refused

# 3. CHANGES verdict blocks a duplicate review of the same head, a new head is NONE
tab REVIEW-101-DEEP-1 2026-11-08T08:00:00Z dddd4444d DONE CHANGES 2026-11-08T08:20:00Z 20
eq "CHANGES row = CHANGES" "$(rs_verdict 101 $HC)" CHANGES
eq "new head after CHANGES = NONE" "$(rs_verdict 101 $H3)" NONE
rs_should_review 101 $H3 && ok "a new head is reviewed" || bad "a new head is reviewed" refused

# 4. in-flight brief (no ledger row yet) blocks a duplicate; a stale one (> RS_INFLIGHT_MIN) does not
echo "[REVIEW-102-DEEP-1] ... head $H3 ..." > $T/sessions/SESSION-REVIEW-102-DEEP-1.md
eq "live brief, no row = INFLIGHT" "$(rs_verdict 102 $H3)" INFLIGHT
touch -t 202611010000 $T/sessions/SESSION-REVIEW-102-DEEP-1.md
eq "brief older than 6 h with no row = NONE" "$(rs_verdict 102 $H3)" NONE

# 5. legacy archived brief (before the ledger) counts as reviewed
echo "[REVIEW-103-DEEP-1] ... head $H2 ..." > $T/archive/2026-11/SESSION-REVIEW-103-DEEP-1.md
eq "legacy archived brief = LEGACY" "$(rs_verdict 103 $H2)" LEGACY
rs_should_review 103 $H2 && bad "legacy review is not repeated" start || ok "legacy review is not repeated"

# 6. tag numbering never reuses a number from the archive, the ledger or status/
touch $T/status/REVIEW-100-DEEP-5.json
eq "next tag skips archived/ledger/status numbers" "$(rs_next_tag 100)" 6
eq "next tag for an unseen PR is 1" "$(rs_next_tag 999)" 1

# 7. previous head for REVIEW-DELTA-1 is found in the archive
eq "prev head from archived brief" "$(rs_prev_head 100)" $H1

# 8. off switch
touch $W/REVIEW-STATE-OFF
rs_should_review 100 $H1 && ok "REVIEW-STATE-OFF lets reviews start" || bad "REVIEW-STATE-OFF lets reviews start" refused
rm $W/REVIEW-STATE-OFF

# 9. short / empty input never throws
eq "empty sha = NONE" "$(rs_verdict 100 '')" NONE

# 10. decline_pending_review: MERGE-MASTER notes about a review are advisory once the head is APPROVEd; real declines never are
cp $REPO/bin/lib-dispatch.sh $T/bin/; . $T/bin/lib-dispatch.sh
dp() { decline_pending_review "$2" && r=ADVISORY || r=REAL; eq "$1" "$r" "$3"; }
dp "N-letter wording on an APPROVEd head"  "100 $H1 risk-critical: needs independent REVIEW-N-DEEP on this head; MM advice only [by:MERGE-MASTER]" ADVISORY
dp "brand-new wording on an APPROVEd head"  "100 $H1 held until a second pair of eyes did a REVIEW [by:MERGE-MASTER]" ADVISORY
dp "same wording on a head WITHOUT a verdict" "100 $H3 held until a second pair of eyes did a REVIEW [by:MERGE-MASTER]" REAL
dp "numbered placeholder (old rule still works)" "100 $H3 waits on independent REVIEW-5-DEEP [by:MERGE-MASTER]" ADVISORY
dp "review-pump CHANGES line is never advisory" "101 $HC ## Verdict: CHANGES  [by:review-pump]" REAL
dp "MM note that is not about a review" "100 $H1 conflicts with #N, rebase first [by:MERGE-MASTER]" REAL
dp "empty line" "" REAL

(( fails )) && { print "\n$fails FAILED"; exit 1; } || print "\nall passed"

# CLEAN-MERGE-1: a verified clean merge of main on an APPROVEd head inherits the APPROVE (no delta review); CHANGES is never inherited
HM=eeee5555eeee5555eeee5555eeee5555eeee5555; HX=7777777778888888999999990000000011111111
echo "100 $HM CLEAN-MERGE from aaaa1111 [by:clean-merge-reapprove]" >> $W/approval-provenance.txt
eq "clean merge of an APPROVEd head inherits APPROVE" "$(rs_verdict 100 $HM)" APPROVE
rs_should_review 100 $HM && bad "no delta review of a clean merge" start || ok "no delta review of a clean merge"
tab REVIEW-101-DEEP-9 2026-11-08T10:00:00Z 123456789 DONE CHANGES 2026-11-08T10:10:00Z 10
echo "101 $HX CLEAN-MERGE from 12345678 [by:clean-merge-reapprove]" >> $W/approval-provenance.txt
eq "a parent with CHANGES is not inherited" "$(rs_verdict 101 $HX)" NONE
eq "no provenance row = no inheritance" "$(rs_verdict 100 2222222223333333444444445555555566666666)" NONE
(( fails )) && { print "$fails FAILED"; exit 1; } || print "all passed (incl. clean-merge)"
