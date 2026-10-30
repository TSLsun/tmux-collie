Task {{TASK}}, flow {{FLOW}}, step {{STEP}}: ship.

The review passed. Ship the task now, following these rules:

{{SHIP}}

The pull request body must include the flow summary in {{PACKET}}/SUMMARY.md
verbatim (who did what, review findings, what was fixed or declined and why).
Put the pull request URL and the CI result in {{TASK_DIR}}/REPORT.md.

When this step is complete, run `collie flow done` as your last action (or
create the file {{PACKET}}/DONE), then stop.
