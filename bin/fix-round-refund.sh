#!/bin/zsh
# fix-round-refund.sh -- ENV-LINT-1 (2026-11).
# A fixer round is "burned" when the session ends WITHOUT pushing: one PR lost REVFIX-1/-2/-3 to a pre-push refusal
# (environment), not to wrong fixes, and hit the cap 3/3 with the PR no better. A round only counts when it changed the PR.
# For every recent fix-rounds.txt row whose session is finished (status done or died): read the PR head the brief was written
# for (the 40-hex after "head " in the brief); if the PR head on GitHub is still that SHA the session pushed nothing -> refund
# ONE round (fix-round-extra.txt "PR 1 [by:refund] TAG"). Once per tag (watchdog/fix-round-refunded.txt), at most
# RFR_MAX (2) refunds per PR so a PR that keeps failing without a push still reaches the cap and a human.
# Read-only otherwise. RFR_DRY=1 prints only. Off switch: watchdog/FIX-ROUND-REFUND-OFF. Throttle: 10 min.
setopt null_glob
P=${KX_P:-$HOME/proj/prompts}; W=$P/watchdog; DONE=$W/fix-round-refunded.txt; RFR_MAX=${RFR_MAX:-6}
[ -f $W/FIX-ROUND-REFUND-OFF ] && exit 0
ST=$W/.fix-round-refund-last
[ -z "$RFR_DRY" ] && [ -f $ST ] && [ $(( $(date +%s) - $(stat -f %m $ST) )) -lt 600 ] && exit 0
[ -z "$RFR_DRY" ] && touch $ST
touch $DONE
mark() { [ -n "$RFR_DRY" ] || echo "$1" >> $DONE; }
now=$(date +%s)
awk -v t=$(( now - 172800 )) '$2+0 >= t' $W/fix-rounds.txt 2>/dev/null | while read -r pr ts tag rest; do
  [[ $tag == REVFIX* || $tag == FIX-* || $tag == MERGE-FIX* ]] || continue
  grep -qx "$tag" $DONE && continue
  stt=$(python3 -c "import json,sys;print(json.load(open('$P/status/$tag.json')).get('state',''))" 2>/dev/null)
  [[ $stt == done || $stt == died ]] || continue
  # ROUNDS-OPT (A): judge by what reached the PR since the round started, not by a head SHA in the brief (MERGE-FIX-AUTO batch
  # briefs have none, so those rounds were never refunded). Round is refunded when the session pushed nothing, or only merge-of-main commits.
  since=$(date -u -r $ts +%Y-%m-%dT%H:%M:%SZ)
  cm=$(gh api "repos/${KX_REPO:-OWNER/PRODUCT}/pulls/$pr/commits?per_page=100" --paginate --jq '.[]|"\(.commit.committer.date) \(.commit.message|split("\n")[0])"' 2>/dev/null)
  [ -n "$cm" ] || continue                                  # no answer from GitHub (or PR closed): decide next time
  new=$(echo "$cm" | awk -v s="$since" '$1 >= s')
  real=$(echo "$new" | grep -v -E "^[^ ]+ Merge (branch|remote-tracking branch|pull request).*main|^[^ ]+ Merge (origin/)?main|^$" | grep -c .)
  if [ "$real" != 0 ]; then mark "$tag"; continue; fi        # it pushed real work: the round counts
  if [ -z "$new" ]; then why="pushed nothing"; else why="only merge-of-main commits"; fi
  sha=$why
  n=$(grep -c "^$pr 1 \[by:refund\]" $W/fix-round-extra.txt 2>/dev/null)
  if (( n >= RFR_MAX )); then mark "$tag"; [ -n "$RFR_DRY" ] || echo "- $(date -u +%FT%TZ) FIX-ROUND-REFUND: #$pr $tag pushed nothing but the refund limit ($RFR_MAX) is reached; round stays counted" >> $P/watchdog/FOR-ADMIN.md; continue; fi
  if [ -n "$RFR_DRY" ]; then echo "would refund #$pr $tag ($why)"; continue; fi
  echo "$pr 1 [by:refund] $tag head=${sha:0:9} unchanged, session ended $(date -u +%FT%TZ)" >> $W/fix-round-extra.txt
  mark "$tag"
  echo "$(date -u +%FT%TZ) fix-round-refund: #$pr $tag ended: $why; round refunded" >> $P/merge-tick.log; echo "$(date -u +%FT%TZ) A refund #$pr $tag: $why" >> $W/rounds-opt.log
done
exit 0
