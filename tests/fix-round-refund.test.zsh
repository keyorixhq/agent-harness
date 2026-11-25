#!/bin/zsh
# Offline test for bin/fix-round-refund.sh (gh stubbed: it answers the PR's commit list). Run: zsh tests/fix-round-refund.test.zsh
setopt null_glob
SRC=$HOME/proj/prompts; T=$(mktemp -d); trap 'rm -rf $T' EXIT
mkdir -p $T/p/watchdog $T/p/status $T/p/sessions $T/p/bin $T/bin
export KX_P=$T/p PATH=$T/bin:$PATH RFR_MAX=2
fails=0; ok() { print "ok   $1"; }; bad() { print "FAIL $1"; fails=$((fails+1)); }
now=$(date +%s); H1=$(printf 'a%.0s' {1..40}); H2=$(printf 'b%.0s' {1..40})
# gh stub: the commit list of PR n ("<committer date> <subject>" per line) is read from $T/commits-<n>
cat > $T/bin/gh <<EOS
#!/bin/zsh
n=\${\${2#*pulls/}%%/*}; cat $T/commits-\$n 2>/dev/null
EOS
chmod +x $T/bin/gh
mkrow() { echo "$1 $now $2 review-pump" >> $T/p/watchdog/fix-rounds.txt; echo "{\"state\":\"$3\"}" > $T/p/status/$2.json
  echo "[$2] Fix PR #$1 (branch x, head \`$4\`)." > $T/p/sessions/SESSION-$2.md; }
run() { zsh $SRC/bin/fix-round-refund.sh; }
extra() { awk -v n=$1 '$1==n && $3=="[by:refund]" {c++} END{print c+0}' $T/p/watchdog/fix-round-extra.txt 2>/dev/null; }
lines() { awk 'END{print NR+0}' $T/p/watchdog/fix-round-extra.txt 2>/dev/null; }
old='2000-01-01T00:00:00Z initial work'; new='2999-01-01T00:00:00Z real fix'; mrg='2999-01-01T00:00:00Z Merge branch main into x'
print $old > $T/commits-100; print "$old\n$new" > $T/commits-101; print $old > $T/commits-102; print "$old\n$mrg" > $T/commits-103
mkrow 100 REVFIX-100-1 done $H1     # ended, pushed nothing -> refund
mkrow 101 REVFIX-101-1 done $H1     # ended, pushed real work -> no refund
mkrow 102 REVFIX-102-1 working $H1  # still running         -> no refund
mkrow 103 REVFIX-103-1 done $H1     # ended, only a merge of main -> refund
run
[ $(extra 100) = 1 ] && ok "no-push round refunded" || bad "no-push round refunded"
[ $(extra 101) = 0 ] && ok "round with real push not refunded" || bad "round with real push not refunded"
[ $(extra 102) = 0 ] && ok "running session not refunded" || bad "running session not refunded"
run; [ $(extra 100) = 1 ] && ok "second run does not refund twice" || bad "second run does not refund twice"
# throttle: new row right away is not looked at, until the stamp is old
mkrow 100 REVFIX-100-2 done $H1; run
[ $(extra 100) = 1 ] && ok "throttled within 10 min" || bad "throttled within 10 min"
touch -t 202001010000 $T/p/watchdog/.fix-round-refund-last; run
[ $(extra 100) = 2 ] && ok "second refund after throttle" || bad "second refund after throttle"
# limit: a third no-push round for the same PR is not refunded
mkrow 100 REVFIX-100-3 done $H1; touch -t 202001010000 $T/p/watchdog/.fix-round-refund-last; run
[ $(extra 100) = 2 ] && ok "refund limit 2 per PR" || bad "refund limit 2 per PR"
grep -q 'refund limit' $T/p/watchdog/FOR-ADMIN.md && ok "limit reported to FOR-ADMIN" || bad "limit reported to FOR-ADMIN"
# dry run writes nothing
mkrow 103 REVFIX-103-2 done $H1; touch -t 202001010000 $T/p/watchdog/.fix-round-refund-last; b=$(lines); RFR_DRY=1 run >/dev/null
[ "$(lines)" = "$b" ] && ok "dry run writes nothing" || bad "dry run writes nothing"
# off switch
touch $T/p/watchdog/FIX-ROUND-REFUND-OFF; touch -t 202001010000 $T/p/watchdog/.fix-round-refund-last; b=$(lines); run
[ "$(lines)" = "$b" ] && ok "off switch" || bad "off switch"
(( fails )) && { print "$fails FAILED"; exit 1; } || print "all passed"
