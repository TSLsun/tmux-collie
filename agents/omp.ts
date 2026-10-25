// collie extension for oh-my-pi: report agent state to the tmux window.
// Loaded by agents/omp.sh via `omp -e`; COLLIE_BIN points at bin/collie.
import { execFileSync } from "node:child_process";

export default function (pi: any) {
  const bin = process.env.COLLIE_BIN;
  if (!bin) return;
  const state = (s: string) => () => {
    try {
      execFileSync(bin, ["state", s], { stdio: "ignore" });
    } catch {}
  };
  pi.on("agent_start", state("working"));
  pi.on("tool_execution_end", state("working"));
  pi.on("tool_approval_requested", state("waiting"));
  pi.on("tool_approval_resolved", state("working"));
  pi.on("agent_end", state("idle"));
  pi.on("session_shutdown", state("exited"));
}
