
## Ship
Finish the delivery loop yourself, then stop for the human:
1. Commit as you go in reviewable steps: one concern per commit (e.g.
   refactor, feature, tests, docs), Conventional Commits subject, a body that
   says why when it is not obvious. No "wip" or "fix typo" commits: squash
   fixups locally (`git commit --fixup`, `git rebase -i --autosquash` on your
   own unpushed commits) before pushing.
2. When the Acceptance Criteria are met (checked on the real artifact: run
   it, don't infer from tests) and the Verify checks pass locally,
   push the task branch to origin and open a PR (`gh pr create`; with
   several repos, one per repo that has commits): title and
   body summarize the changes and how you verified them, plus the gist of
   REPORT.md. Without `gh`, push and put the branch URL in REPORT.md.
3. Wait for CI (`gh pr checks --watch`, or poll). Green CI alone is not
   proof the task works; step 2's Acceptance Criteria check is.
4. If CI fails and the cause is clear (lint, an obviously broken test, a
   platform difference), fix it, commit, push once and check again. If the
   cause is unclear, flaky or needs secrets/permissions, or the second run
   fails too: stop, write the failure and your analysis into REPORT.md, and
   wait for the human. No blind retries.
   After any rebase, merge or conflict resolution, re-run the Verify checks
   and wait for CI on the new head before calling it ready.
5. Never merge, force-push a shared branch, or touch the default branch.
