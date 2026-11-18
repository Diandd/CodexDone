// Installed by CodexDone. Requires Pi's agent_settled lifecycle event.
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const helper = __CODEXDONE_HELPER__;

export default function (pi: ExtensionAPI) {
  let turnID: string | undefined;
  let reply = "";

  async function send(ctx: ExtensionContext, payload: Record<string, unknown>) {
    await new Promise<void>((resolve) => {
      const child = execFile(helper, ["--source", "pi"], { timeout: 3000 }, (error) => {
        if (error && ctx.hasUI) ctx.ui.notify("CodexDone: notification delivery failed", "warning");
        resolve();
      });
      child.stdin?.on("error", () => {}); // execFile reports process failure above.
      child.stdin?.end(JSON.stringify({
        session_id: ctx.sessionManager.getSessionId(),
        turn_id: turnID,
        cwd: ctx.cwd,
        ...payload,
      }));
    });
  }

  pi.on("session_start", async () => { turnID = undefined; reply = ""; });
  pi.on("before_agent_start", async (event, ctx) => {
    if (event.messageType !== "user") return;
    turnID = randomUUID();
    reply = "";
    await send(ctx, { hook_event_name: "UserPromptSubmit", prompt: event.prompt });
  });
  pi.on("agent_end", async (event) => {
    const message = [...event.messages].reverse().find((item) => item.role === "assistant");
    if (message?.role === "assistant") {
      reply = message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
    }
  });
  pi.on("agent_settled", async (_event, ctx) => {
    if (!turnID) return;
    await send(ctx, { hook_event_name: "Stop", last_assistant_message: reply });
    turnID = undefined;
    reply = "";
  });
}
