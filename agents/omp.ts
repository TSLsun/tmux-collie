// collie extension for oh-my-pi: report agent state and session id.
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
  const session = (e: unknown, ctx: unknown) => {
    const event = e && typeof e === "object" ? e : {};
    const context = ctx && typeof ctx === "object" ? ctx : {};
    const agent = "agent" in context ? context.agent : undefined;
    if (agent && typeof agent === "object" && "kind" in agent && agent.kind === "sub") return;
    const manager = "sessionManager" in context ? context.sessionManager : undefined;
    const eventId = "sessionId" in event ? event.sessionId : undefined;
    const session = "session" in context ? context.session : undefined;
    const contextId = session && typeof session === "object" && "id" in session ? session.id : undefined;
    const sessionId = manager && typeof manager === "object" && "getSessionId" in manager &&
      typeof manager.getSessionId === "function" ? manager.getSessionId() : undefined;
    const id = eventId ?? contextId ?? sessionId;
    if (typeof id !== "string" || !/^[A-Za-z0-9_-]+$/.test(id)) return;
    try {
      execFileSync(bin, ["_session"], {
        input: JSON.stringify({ session_id: id }),
        stdio: ["pipe", "ignore", "ignore"],
      });
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
  pi.on("session_start", session);
  pi.on("session_switch", session);
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
