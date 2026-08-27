---
name: dispatched-issue-pickup
description: >-
  Agent-only procedure for work another machine dispatched as a GitHub issue.
  Use on a `check: ... dispatched work: ...` wake, before picking up an issue labeled fm:dispatched, and before reporting a picked-up task's outcome.
  Owns the claim-then-spawn-then-bind order, the issue= idempotency rule, and the rule that every result goes into the issue rather than into captain chat.
user-invocable: false
metadata:
  internal: true
---

# dispatched-issue-pickup

The captain writes a spec on one machine and dispatches it; that machine opens an issue on the target repository carrying the spec as the body and the label `fm:dispatched`.
This machine picks it up, builds it through the project's ordinary delivery path, and reports the outcome back into that same issue.
Neither machine assumes the other is awake: both poll, nothing pushes, and an issue dispatched while this machine was off simply waits until the next poll.

[`bin/fm-dispatch-pickup.sh`](../../../bin/fm-dispatch-pickup.sh) owns every command, flag, label name, state machine detail, and cadence rule.
Read its `--help` rather than memorizing them here.
[`docs/configuration.md`](../../../docs/configuration.md) "Cross-machine work dispatch" owns setup and arming.

## Two rules that are not negotiable

**The issue is the record.**
Never open a parallel note, backlog field, or status line that restates what the issue already says, and never report a dispatched task's outcome only in captain chat.
Chat is not durable and the dispatching machine cannot read it.
Everything the other machine needs goes into the issue.

**Claim before you spawn, bind after.**
`claim` relabels the issue to `fm:building` before any worker exists, on purpose.
An interruption there leaves an issue visibly stuck with no task, which the poll reports by name.
Doing it the other way round leaves an issue still labeled `fm:dispatched` that the next poll builds a second time.
Never reorder these, and never hand-edit the labels to "clean up" a half-finished pickup.

## Picking one up

1. Read the poll's line: it names each repository and issue number waiting, each issue already claimed with no task behind it, and any repository that could not be read.
   A repository that could not be read is not a repository with nothing waiting; treat it as a forge or credential problem, not as silence.
2. Read the spec: `gh-axi issue view <n> -R <owner>/<repo> --full`.
   The issue body is the captain's spec and is treated exactly as a spec pasted into chat: resolve the project, classify ship or scout, and resolve the delivery mode and merge posture at intake under `AGENTS.md` section 7.
3. Choose the task id, then `claim` it.
   A refusal here is the idempotency guard doing its job: another task already holds that issue, the issue is not waiting to be picked up, or the id is already in use.
   Investigate the refusal; never work around it.
   The one refusal that is a setup problem rather than a guard is a missing label, which names the label and the repository: create it there, then claim again.
4. Write the brief and spawn the worker exactly as for any other task.
5. `bind` the spawned task to the issue.
   This is what makes a later poll, a restart, or a second machine refuse to build it again.
6. Record the work in the backlog as usual, with the issue URL in the task note so the local record points at the durable one.

## An issue marked building with no task

The poll reports these because nothing else will: the poll only offers `fm:dispatched` issues, so a half-finished claim never comes back on its own.
It reports only a claim that belongs to this machine, or an issue carrying no claim comment at all, so an issue the other machine is building is left alone rather than reported here.
Start by reading the issue's claim comment, because everything below turns on whose claim it is: `gh-axi issue view <n> -R <owner>/<repo> --full`.
Then reconcile it in whichever direction the evidence supports.

- The claim comment names another machine: leave it alone, and do not relabel, comment, or spawn.
  That machine is building it and will report the outcome into this same issue.
  Spawning here would build one spec twice, which is the single outcome this whole transport exists to prevent.
- The worker exists but was never bound: `bind` it now.
- The claim comment names this machine, or there is no claim comment at all, no worker exists, and the work is still wanted: spawn it against that issue's spec and `bind`.
- The work is not wanted, or cannot proceed: report it blocked with the reason, which leaves it open for the captain.

## Reporting the outcome

Report once, when the task reaches its real end.

- Landed or ready for the captain: `report --built`, whose message names the branch or the full PR URL.
  That comments the outcome, labels `fm:built`, and closes the issue.
- Failed, or needs the captain: `report --blocked`, whose message says why.
  That labels `fm:blocked` and deliberately leaves the issue OPEN.
  Never close a failure; a closed issue is one the captain never sees again.

Report before tearing the task down, because teardown removes the record carrying the issue URL.
Then relay the outcome to the captain in ordinary outcome language under `AGENTS.md` section 9, with the full PR URL when there is one.
The issue comment is the durable record and the chat line is the courtesy, never the other way round.

## What this never authorizes

Picking up a dispatched issue is not merge authority and not approval for anything destructive, irreversible, or security-sensitive.
A dispatched spec lands the same way any other work lands.
The poll only offers issues on repositories this home has cloned, and dispatch to a machine that is not the captain's own is out of scope.
