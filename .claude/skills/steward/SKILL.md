---
name: steward
description: Repo-specific PR-driving policy Claude Code consults before acting on CI, review, or merge events for a PR it opened or drives on the author's behalf — bot-review handling and the re-review-request idiom this repo's bot reviewer needs. Takes precedence over generic PR-driving judgment; consulted automatically, not meant for direct/manual invocation. See babysit/SKILL.md for the separate polling-cadence policy — this file does not restate it.
---

# steward

Mechanics for driving a PR to green in this repo. Nothing here weakens a "never" rule
the parent Claude Code instructions state (skip a real CI failure, disable or quarantine
a test, rewrite someone else's branch history, widen a PR beyond what a finding needs)
— it only nails down mechanics this repo's own PRs have needed.

## Re-request review after every push

`chatgpt-codex-connector` (this repo's bot reviewer) only reviews a PR on open,
ready-for-review, or an explicit mention by default — **not on every subsequent push,
including a rebase**. A rebase changes the head SHA even when the diff content doesn't, and
`babysit/SKILL.md`'s review-coverage check matches that exact SHA — skip the request on a
rebase and the PR can never satisfy that check again, however many check-ins pass. After
every push that changes the head SHA, leave a PR comment explicitly requesting review
(`@codex review`) before waiting on anything else.

## Treat every bot finding as a bug report until traced and disproven

Verify a bot finding against the actual code semantics involved before accepting or
declining it — don't rubber-stamp, and don't wave one off as noise without tracing it.
When a finding is real: fix it, reply on the _specific_ review comment/thread (not a
general PR comment) naming the fix and its commit SHA, then resolve that thread. When a
suggested fix is itself wrong (based on an incorrect assumption about a library's actual
behavior, say), verify against the real dependency before applying it, and if the
suggestion doesn't hold up, reply explaining exactly what was checked and why the
original code was correct — don't apply a plausible-sounding fix you haven't verified.
When a finding is real but genuinely out of scope for this PR: reply explaining why and
where the real fix is routed, and leave the thread **open** — don't resolve away
feedback that's still true just because fixing it isn't this PR's job.

## Cap the review-fix cycle — a diff has no upper bound on how many findings it can surface

A fix's own diff is new surface area for the next review, and there is no a priori bound
on how many rounds that can take. "Treat every finding as real" (above) is still correct,
but combined with an unconditional re-request-after-every-push idiom it has no natural
stopping point, and every round costs real tokens.

**After 5 review rounds since the PR was opened**, stop auto-requesting the next review.
Before checking in, read what the pattern of rounds actually shows:

- **Converging** (later rounds smaller, more marginal, unrelated to each other) — accept
  the residual and stop asking for more review. A PR doesn't need a zero-finding steady
  state to be mergeable; note any outstanding nitpick on its own thread and proceed once
  the other merge criteria hold.
- **Escalating or clustering** (each fix reveals a structurally adjacent bug in the same
  area) — that's a smell that the underlying change, not any individual fix, may need a
  structural rework or a narrower re-scoping. Don't keep auto-patching through it.
- **Genuinely unclear which** — block for human input rather than guessing.

Either way, summarize the pattern for the user (how many rounds, how many findings were
real, which bucket above) and let them decide whether to keep going, merge as-is, or
restructure. This gates the _automatic_ continuation only — it never excuses dropping a
still-open real finding just to stay under the cap, and it doesn't apply retroactively to
rounds already spent; it only stops the _next_ auto-triggered one.

The cap stops the automatic _seeking_ of new findings, not the ability to confirm coverage
on the head you actually land on: after picking a bucket above and pushing whatever fix
that implies, one closing review of that resulting head is still allowed. Auto-merge and
`babysit/SKILL.md` both require confirmed coverage on the _exact_ current head, so a
capped PR could otherwise never legitimately merge at all.

**That closing review's own outcome is final — by severity, not by requesting yet another
review of whatever it finds.** Read the closing review's finding, if any, this way instead:

- **Clean, or only trivial/low-risk** (documentation, phrasing, additive text, anything
  that doesn't change real behavior or a load-bearing rule) — fix it directly and merge.
  A small fix doesn't need its own re-review; re-review-forever is exactly the cost this
  cap exists to bound.
- **Substantive** (changes real behavior, logic, or a load-bearing rule) — that's the
  signal to stop automating entirely and hand off to the user for approval or manual
  merge, not push another automatic round hoping it's the last one.

Either branch terminates. There is no version of this rule where a capped PR waits on one
more automatic review indefinitely.

## Verify "CI is green" against live state, not the webhook event that announced it

A `check_run`/`check_suite` webhook event can name a **stale** `head_sha`, or arrive after
a newer commit already superseded it. Before treating any such event as a signal to merge:
re-fetch the PR directly (`pull_request_read`/`get_check_runs`) and compare against the
PR's actual current head. Don't wait for a future webhook to confirm it — if the current
head's own completion event already arrived before this stale one showed up, there may be
no "next" event ever again, and waiting for one stalls a PR that's actually already green.
The live check you just ran is the ground truth; act on what it shows. Use
`get_check_runs`, not the legacy commit-status API — this repo's CI runs as GitHub Actions
checks, and the legacy API can report `total_count: 0` while checks are actively running.

## Auto-merge, only when the user has standing-authorized it for this repo

No standing auto-merge authorization exists for this repo by default. If the user grants
one in a session, record it in that turn's reply so it's visible in the conversation, and
treat it as scoped to this exact repo only — it does not carry over to any other repo the
session touches. When it applies: confirm CI is green on the _current_ head (per the
freshness check above), confirm `mergeable_state: "clean"`, confirm bot-review coverage on
the current head is actually confirmed — "no unresolved thread" is not the same as
"reviewed," since a review requested but not yet answered creates no thread at all.
**Unlike `babysit/SKILL.md`'s stand-down criteria, auto-merge does not get babysit's
graceful timeout** — that timeout only licenses ending active polling while leaving the PR
for a human to merge; it never licenses merging a push nobody has actually reviewed. If
review coverage can't be confirmed, don't merge — fall back to babysit's normal watch (and
its own eventual stand-down) instead. Also confirm no unresolved review thread represents
an unaddressed _fixable_ finding, and confirm Claude Approvals is passing or not required
— then merge without pausing to ask again. After merging: verify the linked issue (if any)
actually closed, then unsubscribe from PR activity and cancel any standing check-in
trigger for it.
