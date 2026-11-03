// collie extension for oh-my-pi: report agent state to the tmux window.
// Loaded by agents/omp.sh via `omp -e`; COLLIE_BIN points at bin/collie.
import { execFileSync } from "node:child_process";

export default function (pi: any) {
  const bin = process.env.COLLIE_BIN;
  if (!bin) return;
  const set = (s: string) => {
    try {
      execFileSync(bin, ["state", s], { stdio: "ignore" });
    } catch {}
  };
  // Subagents (task tool) load this extension too, in the same pane: their
  // ctx.agent.kind is "sub" (main session: "main"; older omp: no ctx.agent).
  // A subagent's agent_end is not the main turn ending, so only the main
  // session reports state.
  const on = (event: string, f: (e: any) => void) =>
    pi.on(event, (e: any, ctx: any) => {
      if ((ctx?.agent?.kind ?? "main") === "main") f(e);
    });
  const state = (s: string) => () => set(s);
  on("agent_start", state("working"));
  // the ask tool waits for the user's answer, like an approval prompt
  on("tool_execution_start", (e: any) => {
    if (e?.toolName === "ask") set("waiting");
  });
  on("tool_execution_end", state("working"));
  on("tool_approval_requested", state("waiting"));
  on("tool_approval_resolved", state("working"));
  // willContinue: omp goes on by itself (queued follow-up), not idle yet
  on("agent_end", (e: any) => {
    if (!e?.willContinue) set("idle");
  });
  on("session_shutdown", state("exited"));
}
