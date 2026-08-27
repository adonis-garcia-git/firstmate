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
An interruption there leaves an issue visibly stuck with no task, which the poll reports.
Doing it the other way round leaves an issue still labeled `fm:dispatched` that the next poll builds a second time.
Never reorder these, and never hand-edit the labels to "clean up" a half-finished pickup.

## Picking one up

1. Read the poll's line: it names each repository and issue number waiting, then any repository that could not be read, then a per-repository count of the issues marked building with no task behind them.
   A repository that could not be read is not a repository with nothing waiting; treat it as a forge or credential problem, not as silence.
2. Read the spec: `gh-axi issue view <n> -R <owner>/<repo> --full`.
   The issue body is the captain's spec and is treated exactly as a spec pasted into chat: resolve the project, classify ship or scout, and resolve the delivery mode and merge posture at intake under `AGENTS.md` section 7.
3. Choose the task id, then `claim` it.
   A refusal here is the idempotency guard doing its job: another task already holds that issue, the issue is not waiting to be picked up, or the id is already in use.
   Investigate the refusal; never work around it.
   The one refusal that is a setup problem rather than a guard is a missing label, which names the label and the repository: create it there, then claim again.
4. Write the brief and spawn the worker exactly as for any other task.
5. `bind` the spawned task to the issue.
   This is what makes a later poll, a restart, or a crash-and-retry refuse to build it again.
   `bind` only records: it writes nothing to the issue, so it is safe to re-run.
6. Record the work in the backlog as usual, with the issue URL in the task note so the local record points at the durable one.

## An issue marked building with no task

An `fm:building` issue with no task record here is an ANOMALY, not a pickup.
The poll reports it because nothing else will: the poll only offers `fm:dispatched` issues, so a half-finished claim never comes back on its own.
It reports them per repository as a count and a few named examples, because they all end at the same place, so the count is the news and a summary naming two of nine is not a truncated list.
List them yourself with `gh-axi issue list -R <owner>/<repo> --label fm:building` when you need the rest.

**Never spawn against it.**
The poll cannot tell this machine's half-finished claim from a build another machine is running right now, and it deliberately does not try, so spawning from this state is how one spec gets built twice.
Report it to firstmate with the issue URL and what was found, and let a person decide.

There is exactly one case that resolves itself here, and it is the one where a worker already exists.

- The worker already exists here but was never bound: `bind` it now, and nothing else.
  From then on it is an ordinary bound task, so `report --built` or `report --blocked` works on it as usual.
- Anything else: report it to firstmate with the issue URL and stop.
  That covers a build another machine is running, which is the common case whenever both machines poll one repository, and it covers work that is no longer wanted or cannot proceed.
  Do not spawn, do not `bind` a task that is not already building this issue, and do not hand-edit the labels.
  `report` needs a task record carrying `issue=<url>` and refuses without one, so with no worker there is no supported way to mark the issue from here, and inventing one is what a person is being asked to decide about.
  Expect the poll to keep counting the issue until it closes; that repetition is a known and accepted cost of never going quiet about a genuinely stuck issue.

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
