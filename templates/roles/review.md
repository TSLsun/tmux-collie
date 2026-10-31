Task {{TASK}}, flow {{FLOW}}, step {{STEP}} (round {{ROUND}}): review.

You are the reviewer. Do not edit files, commit, or run commands that change
the task worktree(s): the flow checks that they are unchanged.

Read the task contract {{TASK_DIR}}/TASK.md, the implementer's report
{{PACKET}}/REPORT.md, and the diff against the base branch in
{{PACKET}}/DIFF.patch (also check `git status` for untracked files). If
{{PACKET}}/PRIOR-REVIEW.md exists, it is the previous round: check that its
findings were fixed or declined with a sound reason (see the
"Review response" section of the report).

Review for correctness against the contract, missing tests, and regressions.
Write {{PACKET}}/REVIEW.md:
- first line exactly `verdict: ok` or `verdict: changes-needed`;
- then numbered findings (`1. path:line: problem. expected fix.`).
Only findings that must change before merge make the verdict changes-needed;
mark optional ones "(optional)".

When REVIEW.md is written, run `collie flow done` as your last action (or
create the file {{PACKET}}/DONE), then stop.
