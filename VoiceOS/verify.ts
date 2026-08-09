import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = new URL("./", import.meta.url);
const manifest = await Bun.file(new URL("voiceos.integration.json", root)).json();
const preview = await Bun.file(new URL("voiceos.integration.preview.json", root)).json();
const serverSource = await Bun.file(new URL("server.ts", root)).text();

if (manifest.schemaVersion !== 1 || preview.schemaVersion !== 1) {
  throw new Error("Manifest and preview must use schemaVersion 1.");
}
if (
  manifest.runtime?.kind !== "local-mcp" ||
  manifest.runtime.command !== "/bin/zsh" ||
  manifest.runtime.args?.join() !== "run.sh"
) {
  throw new Error("EagleGaze must use the Studio-compatible local run.sh launcher.");
}
if (manifest.permissions?.length !== 1 || manifest.permissions[0]?.domains?.join() !== "127.0.0.1") {
  throw new Error("EagleGaze must request only the 127.0.0.1 network permission.");
}
if (manifest.auth || manifest.preferences) {
  throw new Error("The local EagleGaze integration must not require setup fields or secrets.");
}
if (/from\s+["']\.\/bridge\.ts["']/.test(serverSource)) {
  throw new Error("Published VoiceOS packages omit bridge.ts; server.ts must remain self-contained.");
}

const childEnvironment = Object.fromEntries(
  Object.entries({ ...process.env, EAGLEGAZE_BRIDGE_MOCK: "1" }).filter(
    (entry): entry is [string, string] => typeof entry[1] === "string",
  ),
);
const transport = new StdioClientTransport({
  command: manifest.runtime.command,
  args: [new URL("run.sh", root).pathname],
  env: childEnvironment,
});
const client = new Client({ name: "eaglegaze-verifier", version: "0.1.0" });

try {
  await client.connect(transport);
  const listed = await client.listTools();
  const manifestNames = manifest.tools.map((tool: { name: string }) => tool.name).sort();
  const serverNames = listed.tools.map((tool) => tool.name).sort();
  if (JSON.stringify(manifestNames) !== JSON.stringify(serverNames)) {
    throw new Error(`Tool drift: manifest=${manifestNames.join(",")} server=${serverNames.join(",")}`);
  }

  for (const tool of manifest.tools) {
    const fixture = preview.tools[tool.name];
    if (!fixture) throw new Error(`Missing preview fixture for ${tool.name}.`);
    const result = await client.callTool({ name: tool.name, arguments: fixture.args });
    const content = (result as { content?: unknown }).content;
    if (!Array.isArray(content)) throw new Error(`${tool.name} returned no MCP content array.`);
    const text = content.find(
      (item: unknown): item is { type: "text"; text: string } =>
        typeof item === "object" && item !== null &&
        (item as { type?: unknown }).type === "text" &&
        typeof (item as { text?: unknown }).text === "string",
    );
    if (!text) throw new Error(`${tool.name} returned no model-facing text.`);
    const payload = JSON.parse(text.text);
    for (const field of ["sourceKind", "connectionState", "calibrationState", "evaluationState"]) {
      if (typeof payload[field] !== "string") {
        throw new Error(`${tool.name} omitted coarse ${field} state.`);
      }
    }
    const blocks = payload._voiceos_glance?.blocks;
    if (!Array.isArray(blocks) || blocks.length !== fixture.expectedGlanceBlocks) {
      throw new Error(`${tool.name} returned the wrong glance block count.`);
    }
    if ("lookAt" in payload || "mappedGaze" in payload || "faceTransform" in payload) {
      throw new Error(`${tool.name} leaked gaze or face-derived fields into VoiceOS.`);
    }
  }
} finally {
  await client.close();
}

console.log(`VoiceOS verification passed for ${manifest.tools.length} EagleGaze tools.`);
