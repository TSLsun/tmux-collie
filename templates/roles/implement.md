Task {{TASK}}, flow {{FLOW}}, step {{STEP}}: implement.

Your task contract is {{TASK_DIR}}/TASK.md. Read it first; it is authoritative.
Implement it in the task worktree(s) and commit in reviewable steps.
Do not push or open a pull request: a reviewer checks your work first, and
the flow ships it in a later step.

Write a short report to {{TASK_DIR}}/REPORT.md: what you changed, how you
verified it, what is left or uncertain.

If you need a decision from the human, ask and wait; do not signal done.
When this step is complete, run `collie flow done` as your last action (or,
if collie is not on your PATH, create the file {{PACKET}}/DONE), then stop.
