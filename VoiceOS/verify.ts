import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";

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
  Object.entries({ ...process.env, EAGLEGAZE_BRIDGE_MOCK: "1", EAGLEGAZE_ENABLE_EVALUATION: "0" }).filter(
    (entry): entry is [string, string] => typeof entry[1] === "string",
  ),
);
const transport = new StdioClientTransport({
  command: manifest.runtime.command,
  // URL.pathname leaves spaces percent-encoded. VoiceOS installs custom MCPs
  // under "Application Support", so always convert to a filesystem path.
  args: [fileURLToPath(new URL("run.sh", root))],
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
  const expectedNames = ["capture_gaze", "get_gaze_status", "recalibrate_eagleeye", "start_gaze_evaluation"];
  if (JSON.stringify(serverNames) !== JSON.stringify(expectedNames)) {
    throw new Error(`Unexpected public API surface: ${serverNames.join(",")}`);
  }
  for (const manifestTool of manifest.tools) {
    const serverTool = listed.tools.find((tool) => tool.name === manifestTool.name);
    if (serverTool?.description !== manifestTool.description) {
      throw new Error(`Tool-description drift for ${manifestTool.name}.`);
    }
  }
  const captureDescription = manifest.tools.find(
    (tool: { name: string; description?: string }) => tool.name === "capture_gaze",
  )?.description ?? "";
  for (const capabilityClause of [
    "one user-approved EagleEye screen region",
    "pixel and normalized gaze coordinates",
    "two-axis uncertainty",
    "untrusted advisory data",
  ]) {
    if (!captureDescription.includes(capabilityClause)) {
      throw new Error(`capture_gaze is missing capability detail: ${capabilityClause}`);
    }
  }
  for (const agentDirective of ["MANDATORY", "MUST call", "Never satisfy", "Do not substitute"]) {
    if (captureDescription.includes(agentDirective)) {
      throw new Error(`capture_gaze contains an agent-routing directive: ${agentDirective}`);
    }
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
    if (fixture.expectedErrorCode) {
      if (!(result as { isError?: unknown }).isError || payload.code !== fixture.expectedErrorCode) {
        throw new Error(`${tool.name} did not return structured ${fixture.expectedErrorCode}.`);
      }
    } else if (fixture.expectedCoordinateSpace) {
      const image = content.find(
        (item: unknown): item is { type: "image"; data: string; mimeType: string } =>
          typeof item === "object" && item !== null &&
          (item as { type?: unknown }).type === "image" &&
          typeof (item as { data?: unknown }).data === "string",
      );
      if (!image || image.mimeType !== "image/jpeg") {
        throw new Error(`${tool.name} returned no JPEG MCP image content.`);
      }
      if (payload.coordinateSpace !== fixture.expectedCoordinateSpace || !payload.gaze) {
        throw new Error(`${tool.name} omitted image-relative gaze coordinates.`);
      }
    } else {
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
  }
} finally {
  await client.close();
}

console.log(`VoiceOS verification passed for ${manifest.tools.length} EagleGaze tools.`);
