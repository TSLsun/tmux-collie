---
title: Herd coding agents across git worktrees, from tmux
hide:
  - navigation
  - toc
---

<div class="hero" markdown>
<div class="hero-text" markdown>

# tmux-collie

<p class="tagline">Herd coding agents across git worktrees, from tmux.</p>

One task = a branch and worktree per repo, a tmux session, and a `TASK.md`
contract. Start claude, codex, gemini or omp in it, see in your status bar
which agent needs you, review, merge, and clean up.

[Install](#install){ .md-button .md-button--primary }
[Usage guide](USAGE.md){ .md-button }

<p class="status-note">0.x, experimental: interfaces may change without notice.</p>

</div>
<div class="term" aria-label="collie ls in a terminal">
<div class="term-title">~/Repos/shop</div>
<pre><span class="p">$</span> collie new oauth-login -m 'add OAuth login' --run
<span class="p">$</span> collie ls
oauth-login     active  P1      *       <span class="r">waiting</span> shop    <span class="r">answer</span>
fix-retry       review  P2      *       <span class="y">idle</span>    shop    <span class="r">review</span>
rate-limit      todo    P2      *       -       shop    <span class="d">start</span></pre>
<div class="tmux-bar"><span>[oauth-login] 0:shop 1:claude* 2:codex</span><span><b class="r">●1</b> <b class="y">●1</b> <b class="g">●1</b> 10:42</span></div>
</div>
</div>

<div class="cards" markdown>

<div class="card" markdown>
### A task is a unit of work
A slug id, a `TASK.md` contract, one worktree per repo, one tmux session
with a window per repo. Cross-repo tasks and plain folders work too.
</div>

<div class="card" markdown>
### Any agent
claude, codex, gemini and omp get state hooks injected per run, with
nothing installed. Any other command runs too (`--agent aider`).
</div>

<div class="card" markdown>
### Status is derived
`todo` → `active` → `review` from agent runs and `REPORT.md`; you never set
it by hand. `done` and `archived` come from closing the task.
</div>

</div>

## Install

Requires bash 3.2+ (macOS `/bin/bash` is fine), git and tmux 3.2+. Optional:
[fzf](https://github.com/junegunn/fzf) 0.63+ for `dash` and the pickers,
lazygit, and at least one coding agent CLI. With
[tpm](https://github.com/tmux-plugins/tpm), add to `~/.tmux.conf`:

```tmux
set -g @plugin 'TSLsun/tmux-collie'
set -g status-right '#{collie_status} %H:%M'   # ●waiting ●idle ●working counts
```

Then press `prefix` + `I`. The plugin puts `collie` on tmux's `PATH`, so it
is available in every new pane. Check your setup with:

```sh
collie doctor
```

## The everyday loop

<div class="steps">
<a href="#1-new"><b>1</b> new</a>
<a href="#2-run"><b>2</b> run</a>
<a href="#3-watch"><b>3</b> watch</a>
<a href="#4-review"><b>4</b> review</a>
<a href="#5-sync"><b>5</b> sync</a>
<a href="#6-done--gc"><b>6</b> done / gc</a>
</div>

### 1. new

From inside a repo, create a task: a `fix/fix-retry` branch and worktree, a
tmux session, and a `TASK.md` with the objective filled in.

```sh
collie new fix-retry -t fix -m 'retry 5xx on upload'
collie new deploy-v2 -r api -r web     # one task across two repos
collie new login --ship                # the agent commits, opens the PR, waits for CI
```

### 2. run

Start an agent in a new window of the task session. It reads
`.collie/TASK.md` first and writes `.collie/REPORT.md` when finished.

```sh
collie run fix-retry
collie run fix-retry --agent codex -p 'write the tests'
```

### 3. watch

The status bar counts agents that are **waiting** for you, **idle** after a
turn, and **working**. Notifications fire when one waits or goes idle;
`prefix h j` jumps to the last alert. The dashboard sorts tasks by what needs
you. More in [Features](#features).

### 4. review

```sh
collie review fix-retry
```

<div class="term">
<pre>== shop  fix/fix-retry  1 ahead of origin/HEAD
156c502 fix(upload): retry 5xx with backoff
 upload.sh | 1 +
 1 file changed, 1 insertion(+)

== REPORT.md
# fix-retry
Uploads now retry 5xx up to 3 times with backoff.</pre>
</div>

Not there yet? `collie run` again. Ready? Merge the branch yourself or through
its PR.

### 5. sync

When `main` moves on, merge it into the open task branches. `-n` previews,
including conflicts between tasks; on a conflict the task's agent resolves it.

<div class="term">
<pre><span class="p">$</span> collie sync -n
fix-retry shop: would merge 1 commit(s) from origin/main
oauth-login shop: skipped: no commits beyond origin/main
rate-limit shop: skipped: no commits beyond origin/main
between tasks: no conflicts</pre>
</div>

### 6. done / gc

`done` accepts a task: worktrees and session go, branches and the task record
stay. `gc` does it for every task whose branches are merged, squash merges
included, after fetching `origin`.

<div class="term">
<pre><span class="p">$</span> collie gc
done fix-retry</pre>
</div>

`collie archive` abandons a task with the same cleanup; `collie reopen` brings
a closed one back on its kept branches.

## Features

<div class="feature" markdown>
<div markdown>

### Status bar counts and click menu

`#{collie_status}` shows red, yellow and green counts for waiting, idle and
working agents, including ones you started by hand
(`@collie-status-scope tasks` limits it to task sessions).

With `set -g mouse on`, click a count for a menu of the agents behind it:
`session:window`, agent, time in that state, and the task's priority and
title. Pick one to jump to its window (tmux 3.4+).

</div>
<div class="term">
<div class="tmux-menu"><div class="menu-title">waiting</div><pre>oauth-login:1  claude  2m  P1 Add OAuth login    <span class="d">1</span>
api-docs:2     codex   9m  P2 Document the API   <span class="d">2</span></pre></div>
<div class="tmux-bar"><span>[shop] 0:zsh*</span><span><b class="r">●2</b> <b class="y">●1</b> <b class="g">●3</b> 10:42</span></div>
</div>
</div>

<div class="feature" markdown>
<div markdown>

### Dashboard

`collie dash` (or `prefix h h`) is an fzf dashboard of live tasks, most
urgent first: an agent waiting for an answer, a turn to reply to, a report to
review, a stalled task. The preview shows the objective, runs and repos;
keys run, review, edit, finish or sync the selected task.

</div>
<div class="term">
<pre class="dash"><span class="d">── needs you (2) ────────</span>
<span class="r">●</span> oauth-login  answer  P1
<span class="r">●</span> fix-retry    review  P2
<span class="d">── todo (1) ─────────────</span>
<span class="d">○</span> rate-limit   start   P2
<span class="d">enter: go  tab: group by status  /: filter
r: run  u: runs  v: review  e: edit  d: done  s: sync</span></pre>
</div>
</div>

<div class="feature" markdown>
<div markdown>

### Runs view

Press `u` on a task to list its agent runs, newest first, with their state
and handoff or restore links. `enter` goes to a run's window; `h` hands a
claude or codex run off to the other agent.

</div>
<div class="term">
<pre><span class="d">runs of oauth-login</span>
#2  codex   shop  <span class="g">working</span>  now
#1  claude  shop  <span class="r">waiting</span>  now
<span class="d">enter: go  /: filter  h: handoff  esc: back</span></pre>
</div>
</div>

<div class="feature" markdown>
<div markdown>

### Cross-agent handoff

Continue a claude run with codex, or the other way round, in a fresh
conversation. Your note, a `TASK.md` snapshot and `REPORT.md` go into a
read-only packet under the task record; no transcript is passed along, and
the source agent keeps running.

</div>
<div class="term">
<pre><span class="p">$</span> collie handoff oauth-login --from 1 --agent codex --note handoff.md
~/.local/state/collie/tasks/oauth-login/handoffs/from-1-to-codex.9atqX0
<span class="p">$</span> ls ~/.local/state/collie/tasks/oauth-login/handoffs/*/
HANDOFF.md  NOTE.md  TASK.md</pre>
</div>
</div>

<div class="feature" markdown>
<div markdown>

### History

Finished tasks, newest first, with their branches and PR. A pattern searches
their `TASK.md` and `REPORT.md`; on a terminal it is an fzf picker that opens
`collie show`.

</div>
<div class="term">
<pre><span class="p">$</span> collie history -n
2026-10-30  done  fix-retry  fix-retry  fix/fix-retry  -
<span class="p">$</span> collie history -n oauth</pre>
</div>
</div>

<div class="feature" markdown>
<div markdown>

### Ship mode

Off by default. With `collie new --ship` (or `set -g @collie-ship 'on'`),
`TASK.md` tells the agent to finish the delivery loop: Conventional Commits,
push, `gh pr create`, wait for CI, fix a clearly-caused failure once, otherwise
stop and report. It never merges.

</div>
<div class="term">
<pre><span class="d">## Ship</span>
Finish the delivery loop yourself, then stop for the human:
1. Commit as you go in reviewable steps ...
2. ... push the task branch and open a PR
3. Wait for CI
4. If CI fails and the cause is clear, fix it ...
5. Never merge, force-push a shared branch, or
   touch the default branch.</pre>
</div>
</div>

### And more

<div class="cards small" markdown>

<div class="card" markdown>
**Cross-repo tasks** · `-r A -r B`, per-repo branches, named workspaces
(`-w shop`), `collie add` mid-task.
</div>

<div class="card" markdown>
**Folder tasks** · a directory that is not a git repo joins a task in
place, with no branch and no copy.
</div>

<div class="card" markdown>
**Spike** · `collie spike try-cache` moves a dirty worktree's changes into a
new `exp/` task.
</div>

<div class="card" markdown>
**Restore and adopt** · `collie restore` restarts runs lost with the tmux
server; `collie adopt` puts a hand-started agent under collie.
</div>

<div class="card" markdown>
**Notifications** · on waiting and idle; with terminal-notifier, clicking one
jumps to the agent's pane.
</div>

<div class="card" markdown>
**`prefix h` menu** · new task, run, edit, review, shell popup and the
dashboard, without leaving tmux.
</div>

</div>

## Where to next

- [Usage guide](USAGE.md): lifecycle diagrams, task and agent states, and where each action lives.
- [README](https://github.com/TSLsun/tmux-collie#readme): every flag and option.
- [Design](DESIGN.md): goals, data model and roadmap.
- `collie help`, `collie help <command>`, `collie help workflows`.
