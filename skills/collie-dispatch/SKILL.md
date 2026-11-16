---
name: collie-dispatch
description: Open tmux-collie tasks and hand them off instead of implementing them yourself. Write each task's TASK.md contract, create the task, start its agent with collie run, report where it runs, and stop. Use when asked to open, create, file, spawn or dispatch a collie task (or several), or to hand work off to a new collie task.
---

# collie-dispatch

**You open tasks; you do not implement them.** Never cd into, edit, build in
or commit to a worktree of a task you created. The one file you may touch
there is its `.collie/TASK.md`. Implementation belongs to the agent that
`collie run` starts in the task's own tmux session.

Needs tmux-collie with `new -m/--after` and `run --agent` (`collie help new`).

## Per task

1. **Pick** a short kebab-case id, a type (`feat`, `fix`, `docs`,
   `refactor`, ...) and a title.
2. **Create** without starting an agent; it prints the primary worktree path:

   ```sh
   collie new <id> -t <type> --title '<title>' -m '<objective>'
   ```

   Add `-r repo` per repo, `--after <ids>` for ordering, `--ship` when the
   agent should push and open the PR. No `--run`: the contract is not done.
3. **Write the contract** into `<path>/.collie/TASK.md`: Context, your
   additions to Constraints, Acceptance Criteria and a `## Verify` sh block.
   If you cannot state the Objective or the Verify commands, ask the human
   before going on.
4. **Start** the task agent:

   ```sh
   collie run <id> [--agent claude|codex|omp]
   ```

   The default prompt points it at `.collie/TASK.md`.
5. **Report** the id, the worktree path and the run window (tmux session
   `<id>`, window named after the agent; `collie show <id>` lists the run).
   Then stop.

Some collie versions print a handoff note on stderr after `collie new`; it
says the same: open, hand off, stop.

## A good TASK.md

- **Objective**: one outcome, one or two sentences. Not a list of steps.
- **Context**: why it is wanted, the user's words if any, pointers to the
  code (`file:line`, functions, related tasks or PRs). What you learned while
  scoping goes here, so the task agent does not re-derive it.
- **Constraints**: what it must not touch, files shared with parallel tasks.
- **Acceptance Criteria**: checkable statements about the result, each one
  something a reviewer can confirm by running or reading.
- **Verify**: runnable commands that exit non-zero on failure:

  ````md
  ## Verify
  ```sh
  make test
  ```
  ````

## Several tasks

- Split by files touched, so parallel tasks do not conflict.
- Order dependent work with `--after <id>` (or `collie set <id> after=...`).
- Name every shared file (lists, usage text, docs sections) in each
  affected task's Constraints, with the rule "edit in place, don't reorder".
- Create and start them one by one; report all of them at the end.

## Afterwards

Asked to "also do it" or "fix that too" for a dispatched task: do not do
the work here. Send it to the task agent, or point the human at its window:

```sh
collie send <id> 'also handle X; see TASK.md Context'
collie go <id>
```

Implement in this session only if the human explicitly says to do it here.
If they want this agent to drive the task through implement, review, fix and
PR, use the `collie-lead` skill instead.
