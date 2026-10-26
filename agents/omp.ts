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
  const state = (s: string) => () => set(s);
  pi.on("agent_start", state("working"));
  // the ask tool waits for the user's answer, like an approval prompt
  pi.on("tool_execution_start", (e: any) => {
    if (e?.toolName === "ask") set("waiting");
  });
  pi.on("tool_execution_end", state("working"));
  pi.on("tool_approval_requested", state("waiting"));
  pi.on("tool_approval_resolved", state("working"));
  // willContinue: omp goes on by itself (queued follow-up), not idle yet
  pi.on("agent_end", (e: any) => {
    if (!e?.willContinue) set("idle");
  });
  pi.on("session_shutdown", state("exited"));
}
