# Repository instructions for agents

## Pull requests that must remain unmerged

- Prefix the title with `[DO NOT MERGE]` and keep the PR in draft status whenever it is for testing, benchmarking, a temporary dependency, or otherwise must remain unmerged. A warning in the body alone is insufficient.
- Start the PR body with the reason it must remain unmerged and the condition for making it mergeable. If that condition is undecided, say that explicit human authorization is required.
- Preserve the prefix and draft status across updates. Remove them only after the stated condition is satisfied and the user authorizes making the PR mergeable. Passing CI alone is not authorization.

## Plans and task artifacts

- Do not commit agent implementation plans, progress ledgers, reports, or scratch files.
- Keep them in `.collie/` when a task provides it; otherwise use `.agent-work/` (ignored by Git).
- This applies to skill-generated plans too. Repository instructions take precedence over a skill's default plan location.
- Commit durable user documentation in `README.md` and `docs/`, not agent execution notes.

## Documentation

- Keep README command examples and introductions concise; put detailed workflows, diagrams, and action tables in `docs/USAGE.md` and link them from the README.
- When adding or changing a command, update the relevant usage text, completions, README example, and `docs/USAGE.md` entries in place. Do not reorder shared lists.
