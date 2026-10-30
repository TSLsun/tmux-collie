Task {{TASK}}, flow {{FLOW}}, step {{STEP}} (round {{ROUND}}): fix.

A reviewer asked for changes: read {{PACKET}}/REVIEW.md. For each finding,
fix it, or decline it when it is wrong or out of scope. Commit the fixes in
reviewable steps. Do not push or open a pull request.

Then add to {{TASK_DIR}}/REPORT.md a section `## Review response (round {{ROUND}})`
with one line per finding: `N. fixed: how` or `N. declined: why`.

When this step is complete, run `collie flow done` as your last action (or
create the file {{PACKET}}/DONE), then stop.
