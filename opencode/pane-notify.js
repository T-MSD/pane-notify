import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const script = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "scripts", "notify.sh");

function send(hook) {
  const child = spawn(script, ["opencode"], { stdio: ["pipe", "ignore", "ignore"] });
  child.on("error", () => {});
  child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify(hook));
}

export const PaneNotify = async ({ client }) => {
  const busy = new Set();

  async function isSubagent(id) {
    try {
      const { data } = await client.session.get({ path: { id } });
      return Boolean(data?.parentID);
    } catch {
      return false;
    }
  }

  return {
    event: async ({ event }) => {
      const props = event.properties ?? {};
      switch (event.type) {
        case "session.status":
          if (props.status?.type !== "idle") busy.add(props.sessionID);
          else if (busy.delete(props.sessionID) && !(await isSubagent(props.sessionID))) {
            send({ hook_event_name: "Stop" });
          }
          break;
        case "permission.asked":
        case "permission.updated":
          send({
            hook_event_name: "PermissionRequest",
            tool_name: props.permission ?? props.type,
            tool_input: { description: props.title ?? props.patterns?.join(", ") },
          });
          break;
        case "question.asked":
          send({ hook_event_name: "Notification", message: props.questions?.[0]?.question });
          break;
      }
    },
    "chat.message": async ({ sessionID }) => {
      isSubagent(sessionID).then((subagent) => subagent || send({ hook_event_name: "UserPromptSubmit" }));
    },
  };
};
