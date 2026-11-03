---
name: collie-lead
description: Lead one tmux-collie task instead of implementing it yourself. Start an implementer run, block until it signals done, get an independent review from a different agent, send reproduced findings back into the implementer's own conversation, verify the result yourself and prepare the PR, using only collie commands. Use when asked to lead, coordinate or drive a collie task through implement, review, fix and verify, or to resume such a task.
---

# collie-lead

You lead one collie task. You do not write its code. You start agent runs,
block until they finish, check what they produced, decide, and record every
decision in collie so that a fresh lead can resume where you stopped.

Needs tmux-collie with `run --agent/--model/--effort`, `wait`, `signal done`
and `send`. Uses `collie log` and `collie verify` when they exist (`collie
help log` succeeds); without them, keep the same rows in `.collie/LEAD.md` and
run the TASK.md `## Verify` blocks in the worktree yourself.

**Where you can run.** The lead needs the tmux socket. A claude lead without
a Bash sandbox works. Codex's workspace-write sandbox blocks the socket
(`error connecting to ... (Operation not permitted)`): there `collie wait`
exits 2 and `collie send` says the run "has exited" although it is alive. Do
not lead from codex; agents you start only need `collie signal done`, which
works in both.

## Rules

- **Block, never poll.** After each `run` or `send`, call `collie wait <id>
  --run N --done --timeout 3600` and nothing else until it returns. Set the
  Bash tool timeout above it, or run it in the background and act on its
  exit. No `sleep` loops, no repeated `collie show`.
- **Trust artifacts, not messages.** "Done, tests pass" from a run is not
  evidence. After each wait, check the artifacts yourself (table below). A
  missing artifact means the step did not happen: send the run back once,
  then stop.
- **Findings need proof.** Forward a finding only if it names a command and
  its output, and you re-ran the command and saw the same. Drop the rest and
  log why. "No findings" is not proof either: probe the diff yourself with
  one or two commands of your own before accepting it.
- **Log before you act.** `collie log <phase> <decision> <why> <evidence>
  <result>` for every decision. decisions.tsv plus events.log are the lead's
  only memory.
- **Stop for the human** when the contract is unclear, a decision is hard to
  reverse, two fix rounds did not converge, a reviewer changed the worktree,
  or CI fails for a reason you cannot prove. Write the report and stop;
  `collie brief` shows them what waits.
- Never merge, rebase onto the base branch, force-push or delete branches.

## Commands

| Command | Use |
|---|---|
| `collie show <id>` | fields, runs (number, agent, state), recent events, last decision |
| `collie run <id> --agent A [--model M] [--effort E] -p '<prompt>'` | start a run in a new window |
| `sed -n 's/.*\trun_started\trun=\([0-9]*\) .*/\1/p' .collie/events.log \| tail -1` | the run number you just started |
| `collie wait <id> --run N --done --timeout S` | until run N signalled done and is idle: 0 done, 1 timeout, 2 run gone without signal |
| `collie signal done` | run by the agent as the last step of each turn; put it in every prompt |
| `collie send <id> --run N -f <file>` | type into run N's own conversation: 0 sent, 2 still working, 3 no live run |
| `collie log <phase> <decision> <why> <evidence> <result>` | append a row to `.collie/decisions.tsv` |
| `collie verify <id>` | run TASK.md `## Verify` blocks in the worktree; non-zero on failure |
| `collie review <id>` | commits since the branch started, diff stat, dirty files, REPORT.md |
| `collie handoff <id> --from N --agent claude\|codex --note f` | continue a stuck or gone run with the other agent, fresh conversation |

`send` logs a `sent` event, which clears the run's done signal: after a
`send`, `wait --done` waits for the new turn, never for the previous turn's
signal.

## The loop

Phases for `collie log`: `start`, `implement`, `review`, `fix`, `verify`,
`ship`, `stop`. Default agents: claude implements, codex reviews. Any two
different agents work; the reviewer must not be the implementer's
conversation. Keep paths in prompts short and relative (`.collie/...`): long
absolute paths typed into a TUI can arrive broken.

### 0. Start or resume

```sh
collie show <id>
cat .collie/decisions.tsv 2>/dev/null
```

Empty Objective or no `## Verify` in TASK.md: ask the human, stop. If
decisions.tsv has rows, continue after its last row; reuse live runs from
`collie show` instead of starting new ones.

### 1. Implement

```sh
collie log implement 'start claude run' 'TASK.md complete' TASK.md started
collie run <id> --agent claude -p 'Task <id>. Implement .collie/TASK.md.
Commit your work. Write .collie/REPORT.md (what changed, how you verified
it). Then run `collie signal done` as the last command of this turn, and
again at the end of every later turn.'
N=<run number>
collie wait <id> --run $N --done --timeout 3600
```

- exit 1, early: a first run in a new folder can sit at a trust dialog
  (claude folder trust; codex folder trust, then "Hooks need review"); no
  hook fires there, so the state stays `working`. Tell the human which
  window waits.
- exit 1, later: `collie show`; still working → wait again; waiting on a
  question inside the contract → answer with `collie send`; else stop.
- exit 2: the run is gone; `collie handoff --from $N` or a new run, logged.

### 2. Check the implementation

- `.collie/REPORT.md` was written after the run started.
- `collie review <id>`: new commits, no dirty files.
- `collie verify <id>` passes. A failure is a finding (step 4) with the
  verify log as proof.

### 3. Review

```sh
git -C <worktree> rev-parse HEAD > .collie/pre-review.head
git -C <worktree> status --porcelain > .collie/pre-review.status
collie run <id> --agent codex -p 'Task <id>. You are the reviewer, not the
implementer. Do not edit, commit or stage anything in the worktree. Review
the branch against its base for correctness against .collie/TASK.md. For
every finding write: file:line, the defect, the exact command you ran and
its output that proves it. No proof, no finding. Write the findings to
.collie/REVIEW.md ("no findings" if none). Then run `collie signal done`.'
R=<run number>
collie wait <id> --run $R --done --timeout 3600
```

Check: REVIEW.md is new; HEAD and `status --porcelain` equal the saved
files. Different → the review is void; log it and stop for the human.

### 4. Triage and send back

Re-run each finding's command; keep the ones that reproduce. Add your own
probe's finding if it reproduces. Write them to a file, ending with "Fix,
add a check that fails on the old code, commit, update .collie/REPORT.md,
then run `collie signal done`.", and send it to the implementer:

```sh
collie log fix 'send 1 finding to run N' 'reproduced: <cmd> -> <output>' REVIEW.md sent
collie send <id> --run $N -f findings.md
collie wait <id> --run $N --done --timeout 3600
```

send exit 2 → `collie wait <id> --run $N`, then send again. Exit 3 → the run
is gone: `collie handoff --from $N`.

Back to step 2; also re-run each sent finding's command: it must no longer
reproduce. For the next review, `collie send` the reviewer run ("review
<old HEAD>..HEAD, same rules, overwrite .collie/REVIEW.md, signal done")
instead of starting a new one. Two rounds without convergence: stop.

### 5. Verify and ship

Run `collie verify <id>` yourself on the final HEAD. Then follow TASK.md
`## Ship` if present (push, `gh pr create` with what changed and how it was
verified, watch CI). Without `## Ship`, put the PR title and body in the
report and stop.

### 6. Stop

```sh
collie log stop '<outcome>' '<why>' '<PR url or verify log>' done
```

Append a `## Lead` section to `.collie/REPORT.md` (the implementer owns the
rest): outcome, runs (numbers, agents), findings sent and how each was
resolved, the verify result, the PR, and what the human must decide.

## Checks

| After | Check yourself |
|---|---|
| implementer turn | REPORT.md new, commits in `collie review`, clean tree, `collie verify` passes |
| reviewer turn | REVIEW.md new, each finding has command + output, HEAD and status unchanged |
| a finding | you re-ran its command and saw the defect |
| fix turn | the finding's command no longer shows it, `collie verify` passes |
