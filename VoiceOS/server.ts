/** EagleGaze — a VoiceOS integration server (standard MCP over stdio). */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createHash } from "node:crypto";
import { createConnection } from "node:net";
import { z } from "zod";

const STATUS_PROTOCOL_VERSION = 1;
const TOOL_PROTOCOL_VERSION = 2;
const DEFAULT_BRIDGE_PORT = 47_474;
const MAX_RESPONSE_HEADER_BYTES = 65_536;
const MAX_IMAGE_BODY_BYTES = 4 * 1024 * 1024;
// One request can include a 30-second Eagle-owned approval window followed by
// a 30-second optional provider call, plus bounded capture/encoding overhead.
const TOOL_TIMEOUT_MS = 70_000;
const COMPANION_BUNDLE_ID = "com.aviary.EagleGazeMac";
const COMPANION_DOWNLOAD_URL = "https://github.com/DigiBugCat/EagleGaze/releases/latest";

function bridgePort(): number {
  const raw = process.env.EAGLEGAZE_BRIDGE_PORT;
  if (raw === undefined) return DEFAULT_BRIDGE_PORT;
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65_535) {
    throw new Error("EAGLEGAZE_BRIDGE_PORT must be an integer from 1 to 65535.");
  }
  return parsed;
}

type BridgeCommand = "status" | "start_calibration" | "reset_calibration" | "start_evaluation";
type BridgeToolName = "recalibrate_eagleeye" | "start_gaze_evaluation" | "capture_gaze";

const SourceKindSchema = z.enum(["phone", "vendor", "unknown"]);
const ConnectionStateSchema = z.enum(["connected", "stale", "offline", "unavailable"]);
const CalibrationStateSchema = z.enum(["setup", "calibrating", "calibrated", "failed"]);
const EvaluationStateSchema = z.enum(["idle", "evaluating", "complete"]);

const BridgeSnapshotSchema = z.object({
  sourceKind: SourceKindSchema.optional(),
  connectionState: ConnectionStateSchema.optional(),
  calibrationState: CalibrationStateSchema.optional(),
  evaluationState: EvaluationStateSchema.optional(),
  phase: z.enum(["setup", "calibrating", "calibrated", "evaluating", "complete", "failed", "calibration_failed"]),
  phaseTitle: z.string().trim().min(1).max(120),
  progress: z.string().trim().min(1).max(120),
  phoneConnected: z.boolean(),
  calibrationStep: z.number().int().nonnegative().max(10_000),
  calibrationPointCount: z.number().int().nonnegative().max(10_000),
  calibrationSampleCount: z.number().int().nonnegative().max(1_000_000),
  evaluationTrial: z.number().int().nonnegative().max(1_000_000),
  evaluationTrialCount: z.number().int().nonnegative().max(1_000_000),
  evaluationHits: z.number().int().nonnegative().max(1_000_000),
  overlayVisible: z.boolean(),
}).strict().superRefine((value, context) => {
  if (value.calibrationStep > value.calibrationPointCount) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Calibration step exceeds point count." });
  }
  if (value.evaluationTrial > value.evaluationTrialCount) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Evaluation trial exceeds trial count." });
  }
  if (value.evaluationHits > value.evaluationTrial) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Evaluation hits exceed completed trials." });
  }
}).transform((value) => ({
  ...value,
  sourceKind: value.sourceKind ?? "phone",
  connectionState: value.connectionState ?? (value.phoneConnected ? "connected" : "offline"),
  calibrationState: value.calibrationState ?? (
    value.phase === "calibration_failed" || value.phase === "failed" ? "failed" :
      value.phase === "calibrating" ? "calibrating" :
        value.phase === "calibrated" ? "calibrated" : "setup"
  ),
  evaluationState: value.evaluationState ?? (
    value.phase === "evaluating" ? "evaluating" : value.phase === "complete" ? "complete" : "idle"
  ),
}));

const BridgeResponseSchema = z.object({
  version: z.number().int(),
  requestID: z.string().uuid().nullable(),
  ok: z.boolean(),
  snapshot: BridgeSnapshotSchema.optional(),
  error: z.object({
    code: z.string().trim().min(1).max(80),
    message: z.string().trim().min(1).max(500),
  }).strict().optional(),
}).strict().superRefine((value, context) => {
  if (value.ok && !value.snapshot) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Successful bridge responses require a snapshot." });
  }
  if (!value.ok && !value.error) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Failed bridge responses require an error." });
  }
});

const BridgeV2ErrorSchema = z.object({
  code: z.string().trim().min(1).max(80),
  message: z.string().trim().min(1).max(500),
  retryable: z.boolean(),
}).strict();

const GazeCoordinatesSchema = z.object({
  x: z.number().finite().nonnegative(),
  y: z.number().finite().nonnegative(),
  normalizedX: z.number().finite().min(0).max(1),
  normalizedY: z.number().finite().min(0).max(1),
  uncertaintyRadius: z.number().finite().nonnegative(),
}).strict();

const CaptureRegionSchema = z.object({
  kind: z.enum(["text", "control", "controlGroup", "image", "chart", "tableCell", "tableRow", "table", "dialog", "panel", "window", "unknown"]),
  resolvedBy: z.enum(["explicitApplicationRegion", "accessibility", "segmentation", "fixedContextFallback", "userAdjusted"]),
  confidence: z.number().finite().min(0).max(1),
  fallbackUsed: z.boolean(),
  topmostAtGaze: z.boolean().optional(),
  includedRelationships: z.array(z.enum(["title", "header", "label", "linkedElement"])).max(4),
}).strict();

const CaptureEnrichmentSchema = z.object({
  provenance: z.literal("external_provider"),
  trust: z.literal("untrusted_advisory"),
  provider: z.literal("cerebras"),
  model: z.literal("gemma-4-31b"),
  contentType: z.string().max(500),
  regionSummary: z.string().max(4_000),
  focusedSubject: z.string().max(2_000),
  focusedText: z.string().max(4_000),
  contextSufficient: z.boolean(),
  labels: z.array(z.string().max(200)).max(50),
  confidence: z.number().finite().min(0).max(1),
  warnings: z.array(z.string().max(500)).max(20),
}).strict();

const CaptureResultSchema = z.object({
  kind: z.literal("image"),
  mimeType: z.literal("image/jpeg"),
  width: z.number().int().positive().max(2_048),
  height: z.number().int().positive().max(2_048),
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
  target: z.literal("calibrated_display"),
  scope: z.literal("context_region"),
  marker: z.enum(["circle", "square"]),
  capturedAt: z.string().datetime({ offset: true }),
  gaze: GazeCoordinatesSchema,
  region: CaptureRegionSchema.optional(),
  enrichment: CaptureEnrichmentSchema.optional(),
  enrichmentWarning: z.string().max(500).optional(),
}).strict().superRefine((value, context) => {
  if (value.gaze.x >= value.width || value.gaze.y >= value.height) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Gaze point falls outside the returned image." });
  }
});

const ActionResultSchema = z.object({ snapshot: BridgeSnapshotSchema }).strict();

const BridgeV2HeaderSchema = z.object({
  version: z.number().int(),
  requestID: z.string().uuid().nullable(),
  ok: z.boolean(),
  bodyLength: z.number().int().nonnegative().max(MAX_IMAGE_BODY_BYTES),
  result: z.unknown().optional(),
  error: BridgeV2ErrorSchema.optional(),
}).strict().superRefine((value, context) => {
  if (value.ok && value.result === undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Successful v2 responses require a result." });
  }
  if (!value.ok && !value.error) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Failed v2 responses require an error." });
  }
  if (!value.ok && value.bodyLength !== 0) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Failed v2 responses cannot include a body." });
  }
});

type BridgeSnapshot = z.output<typeof BridgeSnapshotSchema>;

type BridgeResponse = {
  version: number;
  requestID: string | null;
  ok: boolean;
  snapshot?: BridgeSnapshot;
  error?: { code: string; message: string };
};

class CompanionUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CompanionUnavailableError";
  }
}

class BridgeToolError extends Error {
  readonly code: string;
  readonly retryable: boolean;

  constructor(code: string, message: string, retryable: boolean) {
    super(message);
    this.name = "BridgeToolError";
    this.code = code;
    this.retryable = retryable;
  }
}

class BridgeProtocolError extends Error {
  readonly code: "invalid_bridge_response" | "capture_integrity_failed";

  constructor(message: string, code: "invalid_bridge_response" | "capture_integrity_failed" = "invalid_bridge_response") {
    super(message);
    this.name = "BridgeProtocolError";
    this.code = code;
  }
}

const SOF_MARKERS = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
const MOCK_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAADAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==";

/** Reads only the bounded JPEG marker header; entropy-coded image data is never decoded here. */
function jpegDimensions(image: Buffer): { width: number; height: number } {
  const invalid = (reason: string): never => {
    throw new BridgeProtocolError(`EagleGaze returned a malformed JPEG: ${reason}`, "capture_integrity_failed");
  };
  if (image.length < 12 || image[0] !== 0xff || image[1] !== 0xd8 || image.at(-2) !== 0xff || image.at(-1) !== 0xd9) {
    return invalid("missing the required SOI/EOI structure.");
  }

  let offset = 2;
  while (offset < image.length - 2) {
    if (image[offset] !== 0xff) return invalid("invalid marker prefix.");
    while (offset < image.length && image[offset] === 0xff) offset += 1;
    if (offset >= image.length) return invalid("truncated marker.");
    const marker = image[offset]!;
    offset += 1;

    if (marker === 0xd9) return invalid("ended before a start-of-frame marker.");
    if (marker === 0xda) return invalid("started scan data before declaring dimensions.");
    if (marker === 0x00) return invalid("unexpected stuffed byte in the marker header.");
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > image.length - 2) return invalid("truncated segment length.");

    const segmentLength = image.readUInt16BE(offset);
    if (segmentLength < 2) return invalid("invalid segment length.");
    const segmentEnd = offset + segmentLength;
    if (segmentEnd > image.length - 2) return invalid("segment extends beyond the image body.");

    if (SOF_MARKERS.has(marker)) {
      if (segmentLength < 11) return invalid("start-of-frame segment is too short.");
      const height = image.readUInt16BE(offset + 3);
      const width = image.readUInt16BE(offset + 5);
      const components = image[offset + 7]!;
      if (components < 1 || segmentLength !== 8 + 3 * components) {
        return invalid("start-of-frame component table is inconsistent.");
      }
      if (width < 1 || height < 1 || width > 2_048 || height > 2_048) {
        throw new BridgeProtocolError(
          "EagleGaze returned JPEG dimensions outside the supported 1...2048 pixel range.",
          "capture_integrity_failed",
        );
      }
      return { width, height };
    }
    offset = segmentEnd;
  }
  return invalid("no start-of-frame marker was found.");
}

async function requestFromCompanion(command: BridgeCommand): Promise<BridgeSnapshot> {
  if (process.env.EAGLEGAZE_BRIDGE_MOCK === "1") return mockSnapshot(command);

  const requestID = crypto.randomUUID();
  const request = JSON.stringify({ version: STATUS_PROTOCOL_VERSION, requestID, command });

  return await new Promise<BridgeSnapshot>((resolve, reject) => {
    const port = bridgePort();
    const socket = createConnection({ host: "127.0.0.1", port });
    let responseBuffer = "";
    let settled = false;

    const finish = (error?: Error, snapshot?: BridgeSnapshot) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else if (snapshot) resolve(snapshot);
      else reject(new CompanionUnavailableError("EagleGaze returned no status snapshot."));
    };

    const timer = setTimeout(
      () => finish(new CompanionUnavailableError("EagleGaze did not answer within 2 seconds.")),
      2_000,
    );

    socket.setNoDelay(true);
    socket.once("connect", () => socket.write(`${request}\n`));
    socket.on("data", (chunk) => {
      responseBuffer += chunk.toString("utf8");
      if (responseBuffer.length > 65_536) {
        finish(new CompanionUnavailableError("EagleGaze returned an oversized response."));
        return;
      }
      const newline = responseBuffer.indexOf("\n");
      if (newline < 0) return;

      try {
        const parsedJSON: unknown = JSON.parse(responseBuffer.slice(0, newline));
        const parsedResult = BridgeResponseSchema.safeParse(parsedJSON);
        if (!parsedResult.success) {
          finish(new CompanionUnavailableError("EagleGaze returned a bridge response outside the v1 schema."));
          return;
        }
        const parsed = parsedResult.data;
        if (parsed.version !== STATUS_PROTOCOL_VERSION || parsed.requestID !== requestID) {
          finish(new CompanionUnavailableError("The installed EagleGaze app uses an incompatible bridge protocol."));
        } else if (!parsed.ok) {
          finish(new Error(parsed.error?.message ?? "EagleGaze rejected the bridge request."));
        } else if (!parsed.snapshot) {
          finish(new CompanionUnavailableError("EagleGaze returned no status snapshot."));
        } else {
          finish(undefined, parsed.snapshot);
        }
      } catch {
        finish(new CompanionUnavailableError("EagleGaze returned invalid bridge JSON."));
      }
    });
    socket.once("error", (error) => {
      finish(new CompanionUnavailableError(
        `Could not reach EagleGaze on 127.0.0.1:${port}. (${error.message})`,
      ));
    });
    socket.once("end", () => {
      if (!settled) finish(new CompanionUnavailableError("EagleGaze closed the bridge before responding."));
    });
  });
}

type CaptureResult = z.output<typeof CaptureResultSchema>;
type CaptureResponse = { metadata: CaptureResult; image: Buffer };

async function callCompanionTool(
  name: "recalibrate_eagleeye" | "start_gaze_evaluation",
  args: Record<string, never>,
): Promise<BridgeSnapshot>;
async function callCompanionTool(
  name: "capture_gaze",
  args: { marker: "circle" | "square" },
): Promise<CaptureResponse>;
async function callCompanionTool(
  name: BridgeToolName,
  args: Record<string, never> | { marker: "circle" | "square" },
): Promise<BridgeSnapshot | CaptureResponse> {
  if (process.env.EAGLEGAZE_BRIDGE_MOCK === "1") {
    if (name === "capture_gaze") {
      const image = Buffer.from(MOCK_JPEG_BASE64, "base64");
      return {
        image,
        metadata: CaptureResultSchema.parse({
          kind: "image",
          mimeType: "image/jpeg",
          width: 2,
          height: 3,
          sha256: createHash("sha256").update(image).digest("hex"),
          target: "calibrated_display",
          scope: "context_region",
          marker: "marker" in args ? args.marker : "circle",
          capturedAt: new Date().toISOString(),
          gaze: { x: 1, y: 1.5, normalizedX: 0.5, normalizedY: 0.5, uncertaintyRadius: 0.25 },
        }),
      };
    }
    return mockSnapshot(name === "recalibrate_eagleeye" ? "start_calibration" : "start_evaluation");
  }

  const requestID = crypto.randomUUID();
  const request = JSON.stringify({
    version: TOOL_PROTOCOL_VERSION,
    requestID,
    method: "tools/call",
    params: { name, arguments: args },
  });

  return await new Promise<BridgeSnapshot | CaptureResponse>((resolve, reject) => {
    const port = bridgePort();
    const socket = createConnection({ host: "127.0.0.1", port });
    const chunks: Buffer[] = [];
    let receivedBytes = 0;
    let expectedBytes: number | undefined;
    let settled = false;

    const finish = (error?: Error, value?: BridgeSnapshot | CaptureResponse) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else if (value) resolve(value);
      else reject(new CompanionUnavailableError("EagleGaze returned no tool result."));
    };

    const timer = setTimeout(
      () => finish(new CompanionUnavailableError("EagleGaze did not answer the tool call within 70 seconds.")),
      TOOL_TIMEOUT_MS,
    );

    socket.setNoDelay(true);
    socket.once("connect", () => socket.write(`${request}\n`));
    socket.on("data", (chunk: Buffer) => {
      receivedBytes += chunk.length;
      if (receivedBytes > MAX_RESPONSE_HEADER_BYTES + MAX_IMAGE_BODY_BYTES) {
        finish(new BridgeProtocolError("EagleGaze returned an oversized v2 response."));
        return;
      }
      chunks.push(chunk);
      if (expectedBytes === undefined) {
        const combined = Buffer.concat(chunks);
        const newline = combined.indexOf(0x0a);
        if (newline < 0) {
          if (combined.length > MAX_RESPONSE_HEADER_BYTES) {
            finish(new BridgeProtocolError("EagleGaze returned an oversized v2 response header."));
          }
          return;
        }
        if (newline > MAX_RESPONSE_HEADER_BYTES) {
          finish(new BridgeProtocolError("EagleGaze returned an oversized v2 response header."));
          return;
        }
        try {
          const rawHeader: unknown = JSON.parse(combined.subarray(0, newline).toString("utf8"));
          const headerResult = BridgeV2HeaderSchema.safeParse(rawHeader);
          if (!headerResult.success) {
            finish(new BridgeProtocolError("EagleGaze returned a bridge response outside the v2 schema."));
            return;
          }
          expectedBytes = newline + 1 + headerResult.data.bodyLength;
          if (receivedBytes > expectedBytes) {
            finish(new BridgeProtocolError("EagleGaze returned extra bytes after the v2 body."));
          }
        } catch {
          finish(new BridgeProtocolError("EagleGaze returned invalid v2 bridge JSON."));
        }
      } else if (receivedBytes > expectedBytes) {
        finish(new BridgeProtocolError("EagleGaze returned extra bytes after the v2 body."));
      }
    });
    socket.once("error", (error) => {
      finish(new CompanionUnavailableError(
        `Could not reach EagleGaze on 127.0.0.1:${port}. (${error.message})`,
      ));
    });
    socket.once("end", () => {
      if (settled) return;
      const response = Buffer.concat(chunks);
      const newline = response.indexOf(0x0a);
      if (newline < 0 || newline > MAX_RESPONSE_HEADER_BYTES) {
        finish(new BridgeProtocolError("EagleGaze closed the bridge before returning a complete v2 header."));
        return;
      }
      try {
        const parsedJSON: unknown = JSON.parse(response.subarray(0, newline).toString("utf8"));
        const parsedResult = BridgeV2HeaderSchema.safeParse(parsedJSON);
        if (!parsedResult.success) {
          finish(new BridgeProtocolError("EagleGaze returned a bridge response outside the v2 schema."));
          return;
        }
        const header = parsedResult.data;
        if (header.version !== TOOL_PROTOCOL_VERSION || header.requestID !== requestID) {
          finish(new BridgeProtocolError("EagleGaze returned a mismatched v2 bridge response."));
          return;
        }
        const body = response.subarray(newline + 1);
        if (body.length !== header.bodyLength) {
          finish(new BridgeProtocolError("EagleGaze returned a truncated or oversized v2 body."));
          return;
        }
        if (!header.ok) {
          const bridgeError = header.error!;
          finish(new BridgeToolError(bridgeError.code, bridgeError.message, bridgeError.retryable));
          return;
        }
        if (name === "capture_gaze") {
          const metadataResult = CaptureResultSchema.safeParse(header.result);
          if (!metadataResult.success || header.bodyLength === 0) {
            finish(new BridgeProtocolError("EagleGaze returned an invalid capture result."));
            return;
          }
          let actualDimensions: { width: number; height: number };
          try {
            actualDimensions = jpegDimensions(body);
          } catch (error: unknown) {
            finish(error instanceof Error ? error : new BridgeProtocolError("EagleGaze returned an invalid JPEG."));
            return;
          }
          if (
            actualDimensions.width !== metadataResult.data.width ||
            actualDimensions.height !== metadataResult.data.height
          ) {
            finish(new BridgeProtocolError(
              "EagleGaze returned JPEG dimensions that do not match its capture metadata.",
              "capture_integrity_failed",
            ));
            return;
          }
          const digest = createHash("sha256").update(body).digest("hex");
          if (digest !== metadataResult.data.sha256) {
            finish(new BridgeProtocolError(
              "EagleGaze returned a capture with a mismatched SHA-256 digest.",
              "capture_integrity_failed",
            ));
            return;
          }
          finish(undefined, { metadata: metadataResult.data, image: body });
        } else {
          if (header.bodyLength !== 0) {
            finish(new BridgeProtocolError("EagleGaze returned an unexpected body for a control tool."));
            return;
          }
          const actionResult = ActionResultSchema.safeParse(header.result);
          if (!actionResult.success) {
            finish(new BridgeProtocolError("EagleGaze returned an invalid control-tool result."));
            return;
          }
          finish(undefined, actionResult.data.snapshot);
        }
      } catch {
        finish(new BridgeProtocolError("EagleGaze returned invalid v2 bridge JSON."));
      }
    });
  });
}

let mockPhase = "setup";

function mockSnapshot(command: BridgeCommand): BridgeSnapshot {
  if (command === "start_calibration") mockPhase = "calibrating";
  if (command === "reset_calibration") mockPhase = "setup";
  const calibrating = mockPhase === "calibrating";
  return BridgeSnapshotSchema.parse({
    sourceKind: "phone",
    connectionState: "connected",
    calibrationState: calibrating ? "calibrating" : "setup",
    evaluationState: "idle",
    phase: mockPhase,
    phaseTitle: calibrating ? "Calibrating" : "Ready to calibrate",
    progress: calibrating ? "Point 1 of 9" : "No calibration",
    phoneConnected: true,
    calibrationStep: 0,
    calibrationPointCount: 9,
    calibrationSampleCount: calibrating ? 12 : 0,
    evaluationTrial: 0,
    evaluationTrialCount: 18,
    evaluationHits: 0,
    overlayVisible: true,
  });
}

type GlanceBlock = Record<string, unknown> & { type: string };

function glanceResult(blocks: GlanceBlock[]) {
  if (blocks.length === 0 || blocks.length > 3) throw new Error("glanceResult: pass 1-3 blocks");
  return { _voiceos_glance: { blocks } };
}

function jsonResult(payload: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(payload) }] };
}

function publicStatus(snapshot: BridgeSnapshot) {
  return {
    sourceKind: snapshot.sourceKind,
    connectionState: snapshot.connectionState,
    calibrationState: snapshot.calibrationState,
    evaluationState: snapshot.evaluationState,
    phase: snapshot.phase,
    phaseTitle: snapshot.phaseTitle,
    progress: snapshot.progress,
    phoneConnected: snapshot.phoneConnected,
    discovery: snapshot.phoneConnected
      ? "An iPhone is actively streaming through EagleGaze Bonjour discovery."
      : "No recent iPhone stream was discovered. Open EagleGazePhone on the same local network.",
    overlayVisible: snapshot.overlayVisible,
    evaluation: snapshot.evaluationTrial > 0
      ? { hits: snapshot.evaluationHits, trials: snapshot.evaluationTrial }
      : null,
    privacyBoundary: "Status never includes gaze coordinates. capture_gaze returns only coordinates relative to its approved image.",
  };
}

function statusCard(snapshot: BridgeSnapshot) {
  return glanceResult([
    {
      type: "header",
      title: "EagleGaze",
      icon: "sparkle",
      trailing: snapshot.phoneConnected ? "Phone connected" : "Phone offline",
    },
    {
      type: "keyValue",
      pairs: [
        ["Calibration", snapshot.phaseTitle],
        ["Progress", snapshot.progress],
        ["Gaze overlay", snapshot.overlayVisible ? "Visible" : "Hidden"],
      ],
    },
  ]);
}

function companionSetupWidget() {
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
:root{color-scheme:light dark;--ink:#17181a;--muted:#656970;--line:rgba(0,0,0,.10);--fill:rgba(0,0,0,.045);--accent:#1473e6}
@media(prefers-color-scheme:dark){:root{--ink:#f5f5f7;--muted:#a8abb2;--line:rgba(255,255,255,.12);--fill:rgba(255,255,255,.07);--accent:#64a8ff}}
*{box-sizing:border-box}body{margin:0;background:transparent;color:var(--ink);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
.card{height:184px;padding:16px;border:1px solid var(--line);border-radius:18px;overflow:hidden}.eyebrow{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
h1{margin:7px 0 4px;font-size:22px;line-height:27px;letter-spacing:-.02em}.copy{color:var(--muted);max-width:440px}.steps{display:flex;gap:8px;margin-top:14px}.step{flex:1;padding:8px 10px;border-radius:10px;background:var(--fill);font-size:12px}.n{font-weight:750;color:var(--accent);margin-right:5px}
a{display:inline-block;margin-top:12px;color:var(--accent);font-weight:650;text-decoration:none}a:focus{outline:2px solid var(--accent);outline-offset:3px;border-radius:3px}
</style></head><body><div class="card"><div class="eyebrow">One-time Mac setup</div><h1>Install or open EagleGaze</h1><div class="copy">The VoiceOS adapter is ready. Its signed Mac companion provides the calibration window and receives gaze data from your iPhone.</div><div class="steps"><div class="step"><span class="n">1</span>Install the Mac app</div><div class="step"><span class="n">2</span>Open it once</div></div><a href="${COMPANION_DOWNLOAD_URL}">Get EagleGaze for Mac →</a></div><script>
var send=function(m){try{parent.postMessage(m,'*')}catch(e){}};
document.addEventListener('click',function(e){var el=e.target;while(el&&el!==document.body){if(el.tagName==='A'){e.preventDefault();var url=el.getAttribute('href')||'';if(/^https:\/\//i.test(url))send({type:'voiceos:openUrl',url:url});return}el=el.parentNode}});
send({type:'voiceos:resize',height:184});
</script></body></html>`;
  return { type: "widget", html, height: 184 };
}

function companionSetupResult(error: CompanionUnavailableError) {
  return jsonResult({
    ready: false,
    setupRequired: true,
    companion: {
      status: "unavailable",
      bundleIdentifier: COMPANION_BUNDLE_ID,
      downloadURL: COMPANION_DOWNLOAD_URL,
      nextSteps: [
        "Install the signed EagleGaze Mac companion from the release page.",
        "Open EagleGazeMac once, then ask VoiceOS to check EagleGaze again.",
      ],
    },
    diagnostic: error.message,
    privacyBoundary: "The download opens only after the user selects the HTTPS link. The adapter does not download or execute software itself.",
    _voiceos_glance: { blocks: [companionSetupWidget()] },
  });
}

async function run(command: BridgeCommand) {
  try {
    const snapshot = await requestFromCompanion(command);
    return jsonResult({ ...publicStatus(snapshot), ...statusCard(snapshot) });
  } catch (error: unknown) {
    if (error instanceof CompanionUnavailableError) return companionSetupResult(error);
    throw error;
  }
}

function toolErrorResult(error: BridgeToolError) {
  return {
    isError: true,
    content: [{
      type: "text" as const,
      text: JSON.stringify({ code: error.code, message: error.message, retryable: error.retryable }),
    }],
  };
}

function protocolErrorResult(error: BridgeProtocolError) {
  return toolErrorResult(new BridgeToolError(error.code, error.message, false));
}

async function runControlTool(name: "recalibrate_eagleeye" | "start_gaze_evaluation") {
  try {
    const snapshot = await callCompanionTool(name, {});
    return jsonResult({ ...publicStatus(snapshot), ...statusCard(snapshot) });
  } catch (error: unknown) {
    if (error instanceof CompanionUnavailableError) return companionSetupResult(error);
    if (error instanceof BridgeToolError) return toolErrorResult(error);
    if (error instanceof BridgeProtocolError) return protocolErrorResult(error);
    throw error;
  }
}

async function runCapture(marker: "circle" | "square") {
  try {
    const capture = await callCompanionTool("capture_gaze", { marker });
    const metadata = capture.metadata;
    return {
      content: [
        { type: "image" as const, mimeType: metadata.mimeType, data: capture.image.toString("base64") },
        {
          type: "text" as const,
          text: JSON.stringify({
            coordinateSpace: "image_pixels",
            image: { width: metadata.width, height: metadata.height },
            gaze: metadata.gaze,
            marker: metadata.marker,
            scope: metadata.scope,
            capturedAt: metadata.capturedAt,
            region: metadata.region,
            enrichment: metadata.enrichment,
            enrichmentWarning: metadata.enrichmentWarning,
          }),
        },
      ],
    };
  } catch (error: unknown) {
    if (error instanceof CompanionUnavailableError) return companionSetupResult(error);
    if (error instanceof BridgeToolError) return toolErrorResult(error);
    if (error instanceof BridgeProtocolError) return protocolErrorResult(error);
    throw error;
  }
}

const server = new McpServer({ name: "eaglegaze", version: "0.2.0" });

server.registerTool(
  "get_gaze_status",
  {
    title: "Gaze status",
    description:
      "Check the local EagleGaze phone connection, Mac companion, and calibration state. Use when the user asks whether eye tracking is installed, connected, calibrated, ready, or currently evaluating. If the Mac companion is unavailable, return the first-run install card.",
    inputSchema: {},
  },
  async () => await run("status"),
);

server.registerTool(
  "recalibrate_eagleeye",
  {
    title: "Recalibrate EagleEye",
    description:
      "Replace the current EagleEye calibration by starting EagleGaze's full-screen nine-point calibration on this Mac. Use when the user asks to calibrate or recalibrate eye tracking.",
    inputSchema: {},
  },
  async () => await runControlTool("recalibrate_eagleeye"),
);

server.registerTool(
  "start_gaze_evaluation",
  {
    title: "Start gaze evaluation",
    description:
      "Start EagleGaze's bounded accuracy evaluation using the current calibration. Use when the user asks to test or score eye-tracking accuracy.",
    inputSchema: {},
  },
  async () => process.env.EAGLEGAZE_ENABLE_EVALUATION === "1"
    ? await runControlTool("start_gaze_evaluation")
    : toolErrorResult(new BridgeToolError(
      "feature_disabled",
      "Gaze evaluation is installed but disabled. Set EAGLEGAZE_ENABLE_EVALUATION=1 when launching the VoiceOS adapter to enable it.",
      false,
    )),
);

server.registerTool(
  "capture_gaze",
  {
    title: "Capture gaze",
    description:
      "ROUTING REQUIREMENT: Call this tool whenever the user asks what they are looking at, where their gaze is, what is under/near their gaze, to capture/show gaze context, or to inspect the screen specifically through EagleGaze. Do not substitute a generic screenshot, screen-capture, computer-use, or vision tool: those tools do not provide EagleGaze's calibrated gaze location, image-relative coordinates, semantic crop, or app-owned approval. This tool captures one approved screen region containing the estimated gaze, marks it, and returns the image, coordinates, bounded region metadata, and optional untrusted provider enrichment. Use a generic screen tool only when the user explicitly requests a non-gaze/full-screen capture, or after this tool returns a structured unavailable, permission, connection, or calibration error.",
    inputSchema: {
      marker: z.enum(["circle", "square"]).optional().default("circle")
        .describe("Shape drawn around the estimated gaze location."),
    },
  },
  async ({ marker }) => await runCapture(marker),
);

await server.connect(new StdioServerTransport());
