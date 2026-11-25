#!/bin/zsh
# dco-heal.sh [--apply]  -- DCO-2 (2026-11-16, owner): find open PRs whose dco-check is RED and repair them BEFORE anybody
# reviews them or a session loops on them. Commits can reach GitHub unsigned from places the sandbox hook never sees (sessions
# on other hosts, scripts working in the product clone, rebase picks). It heals any red-DCO head whose re-signed tree is
# IDENTICAL to the remote head; an approved, reviewed or queued head is healed too: its review and approval rows are carried to
# the new SHA (a queued PR is dequeued first). Default is a dry run (prints what it would do).
# Apply path: temp worktree -> dco-prepush signs -> kpush <branch> --force-with-lease (lint/guards skipped: tree identical).
# Log: watchdog/dco-heal.log. Off: touch ~/proj/prompts/DCO-HEAL-OFF.
emulate -L zsh
P=$HOME/proj/prompts; LOG=$P/watchdog/dco-heal.log; REPO=keyorixhq/keyorix; SRC=$HOME/proj/keyorix
apply=0; [[ ${1:-} == --apply ]] && apply=1
[[ -f $P/DCO-HEAL-OFF ]] && exit 0
say() { print -r -- "dco-heal: $*"; }
logit() { print -r -- "$(date -u +%FT%TZ) $*" >> $LOG; }
gh pr list -R $REPO --state open --limit 100 --json number,headRefName,headRefOid,isCrossRepository \
  -q '.[]|select(.isCrossRepository==false)|"\(.number) \(.headRefName) \(.headRefOid)"' 2>/dev/null | while read -r pr br oid; do
  # 2026-11-22 (owner, #N): a head can reach GitHub with NO dco-check run at all (applied by hand, pushed outside the sandbox hook), so
  # "dco-check red" never fired and the unsigned commit only failed in the merge queue (4 dequeues, churn guard). Also heal when the check is
  # missing and a non-merge commit of the PR has no Signed-off-by whose email equals the commit's author email (the rule dco.yml enforces).
  if ! gh pr checks $pr -R $REPO 2>/dev/null | grep -q -E '^dco-check[[:space:]]+fail'; then
    gh pr checks $pr -R $REPO 2>/dev/null | grep -q -E '^dco-check[[:space:]]' && continue
    gh api "repos/$REPO/pulls/$pr/commits?per_page=100" 2>/dev/null | python3 -c 'import sys,json,re
bad=0
for c in json.load(sys.stdin):
    if len(c.get("parents",[]))>1: continue
    em=(c["commit"]["author"]["email"] or "").lower(); m=c["commit"]["message"]
    if not any(x.lower()==em for x in re.findall(r"(?mi)^Signed-off-by:.*<([^>]+)>\s*$", m)): bad=1
sys.exit(0 if bad else 1)' || continue
  fi
  why=""
  # 2026-11-17 (owner, #N): an APPROVED head no longer blocks the heal. Signing changes only commit messages, so the tree is
  # identical (checked below); the approval is carried to the new SHA afterwards. A reviewed-but-not-approved head still skips.
  appr_old=0; grep -q -E "^${pr} ${oid}( |\$)" $P/approved.txt 2>/dev/null && appr_old=1
  # 2026-11-17 (owner asked for these skips to be fixed automatically): a head in the merge queue or one that was already reviewed no longer
  # blocks the heal either. Signing changes only messages (tree identical, checked below), so the review verdict and the approval are
  # carried to the new SHA. A PR in the queue is dequeued first; merge-tick enqueues it again once the approval is carried.
  inq=0; [[ $(gh api graphql -f query="{repository(owner:\"${REPO%%/*}\",name:\"${REPO##*/}\"){pullRequest(number:$pr){isInMergeQueue}}}" --jq .data.repository.pullRequest.isInMergeQueue 2>/dev/null) == true ]] && inq=1
  if [[ -n $why ]]; then say "#$pr $br: dco red but NOT healing ($why)"; logit "SKIP #$pr $br $why"; continue; fi
  if (( ! apply )); then say "#$pr $br (${oid[1,9]}): dco red, would heal (dry run)"; continue; fi
  (( inq )) && { $P/sbin/kwd dequeue $pr >/dev/null 2>&1; logit "DEQUEUED #$pr for heal"; sleep 8; }
  W=$(mktemp -d $HOME/proj/work/MERGE-MASTER-dcoheal.XXXXXX) || continue
  ( cd $SRC && git fetch -q origin main "$br" && git worktree add -q -B "dcoheal-$pr" $W "origin/$br" ) || { logit "FAIL #$pr worktree"; rm -rf $W; continue; }
  ( cd $W
    old=$(git rev-parse HEAD)
    if [[ -n $(git rev-list --merges origin/main..HEAD | head -1) ]]; then
      # merge commits in range (main merged into the branch): add the trailer in place with filter-branch, which keeps the graph and trees
      FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter '
        m=$(cat); printf "%s\n" "$m"
        [ $(git rev-list --parents -n1 $GIT_COMMIT | wc -w) -gt 2 ] && exit 0
        case "$GIT_AUTHOR_EMAIL" in *"[bot]@users.noreply.github.com") exit 0;; esac
        printf "%s\n" "$m" | grep -i "^Signed-off-by:.*<$GIT_AUTHOR_EMAIL>" >/dev/null && exit 0
        printf "\nSigned-off-by: %s <%s>\n" "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL"' -- origin/main..HEAD >/dev/null 2>&1 \
        || { logit "FAIL #$pr $br filter-branch"; exit 1; }
    else
      zsh $P/bin/dco-prepush.sh || { logit "FAIL #$pr $br dco-prepush refused (dirty)"; exit 1; }
    fi
    git diff --quiet $old HEAD || { logit "FAIL #$pr $br tree changed"; exit 1; }
    KEYORIX_TAG= $P/sbin/kpush "$br" --force-with-lease || exit 1
    nw=$(git rev-parse HEAD); logit "HEALED #$pr $br old=${old[1,9]} new=${nw[1,9]} approved_before=$appr_old"
    o9=${old[1,9]}; n9=${nw[1,9]}
    awk -F'\t' -v pr="$pr" -v o9=$o9 -v n9=$n9 'BEGIN{OFS="\t"} index($1,"REVIEW-" pr "-DEEP-")==1 && $3==o9 && $4=="DONE"{$3=n9; print}' $P/watchdog/review-outcomes.tsv > $W/.rows
    [[ -s $W/.rows ]] && { cat $W/.rows >> $P/watchdog/review-outcomes.tsv; logit "CARRIED review verdict(s) #$pr $o9 -> $n9 ($(wc -l < $W/.rows | tr -d ' ') row)"; }
    awk -v pr="$pr" -v o="$old" -v n="$nw" '$1==pr && length($2)>=8 && index(o,$2)==1 {$2=n; print}' $P/watchdog/declined-heads.txt > $W/.dec
    [[ -s $W/.dec ]] && { cat $W/.dec >> $P/watchdog/declined-heads.txt; logit "CARRIED declined-heads row #$pr"; }
    if (( appr_old )) && [[ $(git rev-parse $nw^{tree}) == $(git rev-parse $old^{tree}) ]]; then
      sleep 5
      KWD_WHY="TREE-IDENTICAL-RESIGN ${old[1,9]} [by:dco-heal]" $P/sbin/kwd approve $pr $nw >/dev/null 2>&1 \
        && logit "CARRIED approval #$pr ${old[1,9]} -> ${nw[1,9]} (trees identical)" || logit "FAIL carry approval #$pr (re-approve by hand)"
      zsh $P/bin/gh-approve-carry.sh >/dev/null 2>&1
    fi ) \
    || say "#$pr $br: heal failed, see log"
  ( cd $SRC && git worktree remove --force $W 2>/dev/null; git branch -D "dcoheal-$pr" >/dev/null 2>&1 ); rm -rf $W
done

(python3 $HOME/proj/prompts/bin/shared-dep-red.py >/dev/null 2>&1 </dev/null &)   # SHARED-DEPRED-1 2026-11-23 (mode file watchdog/SHARED-DEPRED-MODE: off|shadow|on; default shadow)
(python3 $HOME/proj/prompts/bin/sandbox-patch.py >/dev/null 2>&1 </dev/null &)   # PATCH-ASK-1 2026-11-23: a pending .github patch -> ask owner -> apply and push on approval (off: watchdog/PATCH-ASK-OFF)
(python3 $HOME/proj/prompts/bin/session-startup-watch.py --apply >/dev/null 2>&1 </dev/null &)   # STARTUP-WATCH-1 2026-11-24: a session that never reached its first prompt (trust folder etc.) -> blocking ask + notification (off: watchdog/STARTUP-WATCH-OFF)
(zsh $HOME/proj/prompts/bin/stuck-pr-doctor.sh >> $HOME/proj/prompts/watchdog/stuck-doctor-shadow.log 2>&1 </dev/null &)   # STUCK-DOCTOR-2 2026-11-24 SHADOW (no --apply: reads only, files no ask). Off: watchdog/STUCK-DOCTOR-OFF
(zsh $HOME/proj/prompts/bin/dep-tidy-heal.sh >/dev/null 2>&1 </dev/null &)   # DEP-TIDY-HEAL-1 2026-11-24: Dependabot go PR red only for go mod tidy -> tidy in every module + push to the same branch. Mode file watchdog/DEP-TIDY-HEAL-MODE: off|shadow(default, dry)|on
(zsh $HOME/proj/prompts/bin/queue-gate-audit.sh >/dev/null 2>&1 </dev/null &)   # ENQ-GATE-1 2026-11-24: dequeue a PR queued against the gate (scripts/ci/.github without OK, or its DEEP review still running). Off: watchdog/ENQ-AUDIT-OFF
