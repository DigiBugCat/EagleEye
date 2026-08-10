import { afterEach, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { createHash } from "node:crypto";
import { createServer, type Server } from "node:net";
import { fileURLToPath } from "node:url";
import { BridgeSnapshotSchema, EagleGazeBridgeClient } from "./bridge.ts";

let server: Server | undefined;
let adapterClient: Client | undefined;
const VALID_JPEG = Buffer.from("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAADAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==", "base64");

afterEach(async () => {
  await adapterClient?.close();
  adapterClient = undefined;
  server?.close();
  server = undefined;
});

async function connectAdapter(port: number) {
  const environment = Object.fromEntries(
    Object.entries({
      ...process.env,
      EAGLEGAZE_BRIDGE_MOCK: "0",
      EAGLEGAZE_BRIDGE_PORT: String(port),
      EAGLEGAZE_ENABLE_EVALUATION: "0",
    }).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL("server.ts", import.meta.url))],
    env: environment,
  });
  adapterClient = new Client({ name: "eaglegaze-protocol-test", version: "0.1.0" });
  await adapterClient.connect(transport);
  return adapterClient;
}

describe("EagleGazeBridgeClient", () => {
  test("normalizes a protocol-v1 legacy snapshot to coarse states", () => {
    const snapshot = BridgeSnapshotSchema.parse({
      phase: "calibrated",
      phaseTitle: "Calibration complete",
      progress: "9 points fitted",
      phoneConnected: true,
      calibrationStep: 9,
      calibrationPointCount: 9,
      calibrationSampleCount: 12,
      evaluationTrial: 0,
      evaluationTrialCount: 18,
      evaluationHits: 0,
      overlayVisible: true,
    });
    expect(snapshot.sourceKind).toBe("phone");
    expect(snapshot.connectionState).toBe("connected");
    expect(snapshot.calibrationState).toBe("calibrated");
    expect(snapshot.evaluationState).toBe("idle");
  });

  test("rejects fields outside the coarse boundary", () => {
    const result = BridgeSnapshotSchema.safeParse({
      phase: "setup",
      phaseTitle: "Ready to calibrate",
      progress: "No calibration",
      phoneConnected: false,
      calibrationStep: 0,
      calibrationPointCount: 9,
      calibrationSampleCount: 0,
      evaluationTrial: 0,
      evaluationTrialCount: 18,
      evaluationHits: 0,
      overlayVisible: false,
      mappedGaze: { x: 0.5, y: 0.5 },
    });
    expect(result.success).toBe(false);
  });

  test("rejects impossible coarse counts", () => {
    const result = BridgeSnapshotSchema.safeParse({
      phase: "evaluating",
      phaseTitle: "Evaluating",
      progress: "4 / 3 hits",
      phoneConnected: true,
      calibrationStep: 9,
      calibrationPointCount: 9,
      calibrationSampleCount: 12,
      evaluationTrial: 3,
      evaluationTrialCount: 3,
      evaluationHits: 4,
      overlayVisible: true,
    });
    expect(result.success).toBe(false);
  });

  test("correlates a newline-delimited loopback response", async () => {
    server = createServer((socket) => {
      let input = "";
      socket.on("data", (chunk) => {
        input += chunk.toString("utf8");
        const newline = input.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(input.slice(0, newline));
        expect(request).toMatchObject({ version: 1, command: "status" });
        socket.write(`${JSON.stringify({
          version: 1,
          requestID: request.requestID,
          ok: true,
          snapshot: {
            phase: "calibrated",
            phaseTitle: "Calibration complete",
            progress: "9 points fitted",
            phoneConnected: true,
            calibrationStep: 9,
            calibrationPointCount: 9,
            calibrationSampleCount: 12,
            evaluationTrial: 0,
            evaluationTrialCount: 18,
            evaluationHits: 0,
            overlayVisible: true,
          },
        })}\n`);
      });
    });
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test server has no TCP port");

    const snapshot = await new EagleGazeBridgeClient({ port: address.port }).request("status");
    expect(snapshot.phase).toBe("calibrated");
    expect(snapshot.phoneConnected).toBe(true);
  });

  test("surfaces bridge command errors", async () => {
    server = createServer((socket) => {
      socket.once("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        socket.end(`${JSON.stringify({
          version: 1,
          requestID: request.requestID,
          ok: false,
          error: { code: "phone_not_connected", message: "Connect the iPhone first." },
        })}\n`);
      });
    });
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test server has no TCP port");

    await expect(
      new EagleGazeBridgeClient({ port: address.port }).request("status"),
    ).rejects.toThrow("Connect the iPhone first");
  });

  test("translates a validated v2 JPEG and image-relative coordinates into MCP content", async () => {
    const jpeg = VALID_JPEG;
    const sha256 = createHash("sha256").update(jpeg).digest("hex");
    server = createServer((socket) => {
      let input = "";
      socket.on("data", (chunk) => {
        input += chunk.toString("utf8");
        const newline = input.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(input.slice(0, newline));
        expect(request).toMatchObject({
          version: 2,
          method: "tools/call",
          params: { name: "capture_gaze", arguments: { marker: "square" } },
        });
        const header = {
          version: 2,
          requestID: request.requestID,
          ok: true,
          bodyLength: jpeg.length,
          result: {
            kind: "image",
            mimeType: "image/jpeg",
            width: 2,
            height: 3,
            sha256,
            target: "calibrated_display",
            scope: "context_region",
            marker: "square",
            capturedAt: "2026-08-09T12:00:00Z",
            gaze: { x: 1, y: 1.5, normalizedX: 0.5, normalizedY: 0.5, uncertaintyRadius: 0.5 },
            region: { kind: "text", resolvedBy: "accessibility", confidence: 0.85, fallbackUsed: false, topmostAtGaze: true, includedRelationships: ["header"] },
            enrichment: {
              provenance: "external_provider", trust: "untrusted_advisory",
              provider: "cerebras", model: "gemma-4-31b", contentType: "settings panel",
              regionSummary: "A capture settings panel.", focusedSubject: "Smart crop toggle",
              focusedText: "Smart crop", contextSufficient: true,
              labels: ["settings", "toggle"], confidence: 0.91, warnings: [],
            },
          },
        };
        socket.end(Buffer.concat([Buffer.from(`${JSON.stringify(header)}\n`), jpeg]));
      });
    });
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test server has no TCP port");

    const client = await connectAdapter(address.port);
    const result = await client.callTool({ name: "capture_gaze", arguments: { marker: "square" } });
    const content = result.content as Array<{ type: string; data?: string; mimeType?: string; text?: string }>;
    expect(content[0]).toMatchObject({ type: "image", mimeType: "image/jpeg", data: jpeg.toString("base64") });
    const metadata = JSON.parse(content[1]!.text!);
    expect(metadata).toMatchObject({
      coordinateSpace: "image_pixels",
      image: { width: 2, height: 3 },
      gaze: { x: 1, y: 1.5, normalizedX: 0.5, normalizedY: 0.5, uncertaintyRadius: 0.5 },
      marker: "square",
      region: { kind: "text", resolvedBy: "accessibility", fallbackUsed: false, topmostAtGaze: true, includedRelationships: ["header"] },
      enrichment: {
        provenance: "external_provider", trust: "untrusted_advisory",
        provider: "cerebras", model: "gemma-4-31b", focusedText: "Smart crop",
      },
    });
  });

  test("rejects a v2 capture whose bytes do not match the declared digest", async () => {
    const jpeg = VALID_JPEG;
    server = createServer((socket) => {
      socket.once("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        const header = {
          version: 2,
          requestID: request.requestID,
          ok: true,
          bodyLength: jpeg.length,
          result: {
            kind: "image",
            mimeType: "image/jpeg",
            width: 2,
            height: 3,
            sha256: "0".repeat(64),
            target: "calibrated_display",
            scope: "context_region",
            marker: "circle",
            capturedAt: "2026-08-09T12:00:00Z",
            gaze: { x: 1, y: 1.5, normalizedX: 0.5, normalizedY: 0.5, uncertaintyRadius: 0.25 },
          },
        };
        socket.end(Buffer.concat([Buffer.from(`${JSON.stringify(header)}\n`), jpeg]));
      });
    });
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test server has no TCP port");

    const client = await connectAdapter(address.port);
    const result = await client.callTool({ name: "capture_gaze", arguments: {} });
    const text = (result.content as Array<{ type: string; text?: string }>).find((item) => item.type === "text")?.text;
    expect(result.isError).toBe(true);
    expect(JSON.parse(text!)).toMatchObject({ code: "capture_integrity_failed", retryable: false });
    expect(text).toContain("mismatched SHA-256 digest");
  });

  test("rejects SOI/EOI bytes without a valid JPEG frame as an integrity error", async () => {
    const malformed = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
    const sha256 = createHash("sha256").update(malformed).digest("hex");
    server = createServer((socket) => {
      socket.once("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        const header = {
          version: 2,
          requestID: request.requestID,
          ok: true,
          bodyLength: malformed.length,
          result: {
            kind: "image", mimeType: "image/jpeg", width: 1, height: 1, sha256,
            target: "calibrated_display", scope: "context_region", marker: "circle",
            capturedAt: "2026-08-09T12:00:00Z",
            gaze: { x: 0.5, y: 0.5, normalizedX: 0.5, normalizedY: 0.5, uncertaintyRadius: 0.25 },
          },
        };
        socket.end(Buffer.concat([Buffer.from(`${JSON.stringify(header)}\n`), malformed]));
      });
    });
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test server has no TCP port");

    const client = await connectAdapter(address.port);
    const result = await client.callTool({ name: "capture_gaze", arguments: {} });
    const text = (result.content as Array<{ type: string; text?: string }>).find((item) => item.type === "text")?.text;
    expect(result.isError).toBe(true);
    expect(JSON.parse(text!)).toMatchObject({ code: "capture_integrity_failed", retryable: false });
    expect(text).not.toContain("setupRequired");
  });

  test("rejects JPEG dimensions that disagree with capture metadata", async () => {
    const sha256 = createHash("sha256").update(VALID_JPEG).digest("hex");
    server = createServer((socket) => {
      socket.once("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        const header = {
          version: 2,
          requestID: request.requestID,
          ok: true,
          bodyLength: VALID_JPEG.length,
          result: {
            kind: "image", mimeType: "image/jpeg", width: 3, height: 2, sha256,
            target: "calibrated_display", scope: "context_region", marker: "circle",
            capturedAt: "2026-08-09T12:00:00Z",
            gaze: { x: 1, y: 1, normalizedX: 0.5, normalizedY: 0.5, uncertaintyRadius: 0.25 },
          },
        };
        socket.end(Buffer.concat([Buffer.from(`${JSON.stringify(header)}\n`), VALID_JPEG]));
      });
    });
    await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test server has no TCP port");

    const client = await connectAdapter(address.port);
    const result = await client.callTool({ name: "capture_gaze", arguments: {} });
    const text = (result.content as Array<{ type: string; text?: string }>).find((item) => item.type === "text")?.text;
    expect(result.isError).toBe(true);
    expect(JSON.parse(text!)).toMatchObject({ code: "capture_integrity_failed", retryable: false });
    expect(text).toContain("do not match");
  });
});
