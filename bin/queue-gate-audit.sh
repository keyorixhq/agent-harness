#!/bin/zsh
# queue-gate-audit.sh -- ENQ-GATE-1 safety net (2026-11-24, after #N was enqueued twice by two automatic paths without owner's OK and during its DEEP review).
# kwd enqueue refuses these cases; this catches any path that enqueues some other way (a new script, a direct GraphQL call, jump-<pr>.sh, a session).
# Every run: for each merge-queue entry, DEQUEUE it when (a) its head touches a gated path with no row in github-approved.txt (ci_gate_blocks), or
# (b) its DEEP review session is still running. One FOR-ADMIN line per PR+head. Off: touch watchdog/ENQ-AUDIT-OFF. Test hook: QGA_DRY=1 (log only).
P=$HOME/proj/prompts; W=$P/watchdog; R=keyorixhq/keyorix; export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin; unset GH_TOKEN GITHUB_TOKEN
[ -f $W/ENQ-AUDIT-OFF ] && exit 0
. $P/bin/lib-dispatch.sh; . $P/bin/lib-log.sh; KLOG_NAME=queue-gate-audit
mkdir /tmp/kx-qga.lock 2>/dev/null || exit 0; trap 'rmdir /tmp/kx-qga.lock 2>/dev/null' EXIT
rows=$(gh api graphql -f query='{repository(owner:"keyorixhq",name:"keyorix"){mergeQueue(branch:"main"){entries(first:20){nodes{pullRequest{number id headRefOid}}}}}}' \
  -q '.data.repository.mergeQueue.entries.nodes[].pullRequest|"\(.number) \(.id) \(.headRefOid)"' 2>/dev/null) || exit 0
while read -r pr id sha; do
  [ -z "$pr" ] && continue
  why=""
  f=$(gh pr view $pr -R $R --json files -q '[.files[].path]|join(",")' 2>/dev/null)
  ci_gate_blocks $pr $sha "$f" && why="$CI_GATE_WHY, no OK in github-approved.txt for ${sha:0:9}"
  [ -z "$why" ] && pgrep -f "SESSION-REVIEW-$pr-DEEP-[0-9]+\\.md" >/dev/null 2>&1 && why="DEEP review session still running"
  [ -z "$why" ] && continue
  if [ -n "$QGA_DRY" ]; then klog "DRY would dequeue #$pr ${sha:0:9}: $why"; continue; fi
  gh api graphql -f query="mutation{dequeuePullRequest(input:{id:\"$id\"}){mergeQueueEntry{id}}}" >/dev/null 2>&1
  klog_act "dequeued (queued against the gate)" "#$pr ${sha:0:9}: $why"
  grep -qs "QGA #$pr ${sha:0:9}" $W/.qga-alerted || { echo "QGA #$pr ${sha:0:9}" >> $W/.qga-alerted; echo "$(date -u +%FT%TZ) QUEUE-GATE-AUDIT dequeued #$pr ${sha:0:9}: $why" >> $W/FOR-ADMIN.md; }
done <<<"$rows"
