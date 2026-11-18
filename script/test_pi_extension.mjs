import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripTypeScriptTypes } from "node:module";

const root = await mkdtemp(join(tmpdir(), "codexdone pi 'test-"));
try {
  const helper = join(root, "bridge");
  const output = join(root, "events.jsonl");
  await writeFile(helper, `#!/usr/bin/env node
const fs = require('node:fs');
let input = '';
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => fs.appendFileSync(${JSON.stringify(output)}, JSON.stringify({args: process.argv.slice(2), event: JSON.parse(input)}) + '\\n'));
`, { mode: 0o700 });
  const template = await readFile(new URL("../CodexDone/Resources/pi-extension.ts", import.meta.url), "utf8");
  const code = stripTypeScriptTypes(template.replace("__CODEXDONE_HELPER__", JSON.stringify(helper)));
  const extension = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);
  const handlers = new Map();
  extension.default({ on: (name, handler) => handlers.set(name, handler) });
  const ctx = { cwd: "/tmp/project", sessionManager: { getSessionId: () => "pi-session" }, hasUI: false };
  const events = async () => (await readFile(output, "utf8")).trim().split("\n").map(JSON.parse);

  await handlers.get("before_agent_start")({ messageType: "user", prompt: "Fix the tests" }, ctx);
  await handlers.get("agent_end")({ messages: [{ role: "assistant", content: [{ type: "text", text: "Retrying" }] }] }, ctx);
  assert.equal((await events()).length, 1, "low-level agent_end must not alert during retries");
  await handlers.get("agent_end")({ messages: [{ role: "assistant", content: [{ type: "thinking", thinking: "private" }, { type: "text", text: "Done" }] }] }, ctx);
  await handlers.get("agent_settled")({ aborted: false }, ctx);
  let received = await events();
  assert.equal(received.length, 2);
  assert.deepEqual(received[0].args, ["--source", "pi"]);
  assert.equal(received[0].event.hook_event_name, "UserPromptSubmit");
  assert.equal(received[1].event.hook_event_name, "Stop");
  assert.equal(received[1].event.last_assistant_message, "Done");
  assert.equal(received[0].event.turn_id, received[1].event.turn_id);
  assert.equal(received[1].event.session_id, "pi-session");
  await handlers.get("agent_settled")({ aborted: false }, ctx);
  await handlers.get("before_agent_start")({ messageType: "custom" }, ctx);
  await handlers.get("agent_settled")({ aborted: false }, ctx);
  assert.equal((await events()).length, 2, "duplicate or background events must not alert");
  await handlers.get("before_agent_start")({ messageType: "user", prompt: "Another turn" }, ctx);
  await handlers.get("agent_settled")({ aborted: true }, ctx);
  received = await events();
  assert.equal(received.length, 4);
  assert.notEqual(received[0].event.turn_id, received[2].event.turn_id);
  assert.equal(received[3].event.last_assistant_message, "");
  console.log("Pi extension: prompt, retry, settled, abort, and duplicate lifecycle checks passed.");
} finally {
  await rm(root, { recursive: true, force: true });
}
