# Repository instructions for agents

## Plans and task artifacts

- Do not commit agent implementation plans, progress ledgers, reports, or scratch files.
- Keep them in `.collie/` when a task provides it; otherwise use `.agent-work/` (ignored by Git).
- This applies to skill-generated plans too, including `docs/superpowers/plans/`. Repository instructions take precedence over a skill's default plan location.
- Commit durable user documentation in `README.md` and `docs/`, not agent execution notes.

## Documentation

- Keep README command examples and introductions concise; put detailed workflows, diagrams, and action tables in `docs/USAGE.md` and link them from the README.
- When adding or changing a command, update the relevant usage text, completions, README example, and `docs/USAGE.md` entries in place. Do not reorder shared lists.
