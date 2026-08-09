import { createConnection } from "node:net";
import { z } from "zod";

export const BRIDGE_PROTOCOL_VERSION = 1;
export const DEFAULT_BRIDGE_PORT = 47_474;

export type BridgeCommand = "status" | "start_calibration" | "reset_calibration" | "start_evaluation";

export const SourceKindSchema = z.enum(["phone", "vendor", "unknown"]);
export const ConnectionStateSchema = z.enum(["connected", "stale", "offline", "unavailable"]);
export const CalibrationStateSchema = z.enum(["setup", "calibrating", "calibrated", "failed"]);
export const EvaluationStateSchema = z.enum(["idle", "evaluating", "complete"]);

const SnapshotFields = {
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
} as const;

/** Runtime validation is part of the privacy boundary: unknown fields fail closed. */
export const BridgeSnapshotSchema = z.object(SnapshotFields).strict().superRefine((value, context) => {
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

export type BridgeSnapshot = z.output<typeof BridgeSnapshotSchema>;

export const BridgeErrorSchema = z.object({
  code: z.string().trim().min(1).max(80),
  message: z.string().trim().min(1).max(500),
}).strict();

export const BridgeResponseSchema = z.object({
  version: z.number().int(),
  requestID: z.string().uuid().nullable(),
  ok: z.boolean(),
  snapshot: BridgeSnapshotSchema.optional(),
  error: BridgeErrorSchema.optional(),
}).strict().superRefine((value, context) => {
  if (value.ok && !value.snapshot) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Successful bridge responses require a snapshot." });
  }
  if (!value.ok && !value.error) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Failed bridge responses require an error." });
  }
});

type ParsedBridgeResponse = z.output<typeof BridgeResponseSchema>;

type BridgeClientOptions = { port?: number; timeoutMs?: number };

export class EagleGazeBridgeClient {
  readonly port: number;
  readonly timeoutMs: number;

  constructor(options: BridgeClientOptions) {
    const port = options.port ?? DEFAULT_BRIDGE_PORT;
    if (!Number.isInteger(port) || port < 1 || port > 65_535) {
      throw new Error("The EagleGaze bridge port must be an integer from 1 to 65535.");
    }
    this.port = port;
    this.timeoutMs = options.timeoutMs ?? 2_000;
  }

  async request(command: BridgeCommand): Promise<BridgeSnapshot> {
    const requestID = crypto.randomUUID();
    const request = JSON.stringify({
      version: BRIDGE_PROTOCOL_VERSION,
      requestID,
      command,
    });

    return await new Promise<BridgeSnapshot>((resolve, reject) => {
      const socket = createConnection({ host: "127.0.0.1", port: this.port });
      let responseBuffer = "";
      let settled = false;

      const finish = (error?: Error, snapshot?: BridgeSnapshot) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        if (error) reject(error);
        else if (snapshot) resolve(snapshot);
        else reject(new Error("EagleGaze returned no status snapshot."));
      };

      const timer = setTimeout(
        () => finish(new Error("EagleGaze did not answer the local bridge within 2 seconds.")),
        this.timeoutMs,
      );

      socket.setNoDelay(true);
      socket.once("connect", () => socket.write(`${request}\n`));
      socket.on("data", (chunk) => {
        responseBuffer += chunk.toString("utf8");
        if (responseBuffer.length > 65_536) {
          finish(new Error("EagleGaze returned an oversized bridge response."));
          return;
        }
        const newline = responseBuffer.indexOf("\n");
        if (newline < 0) return;

        try {
          const parsedJSON: unknown = JSON.parse(responseBuffer.slice(0, newline));
          const parsedResult = BridgeResponseSchema.safeParse(parsedJSON);
          if (!parsedResult.success) {
            finish(new Error("EagleGaze returned a bridge response outside the v1 schema."));
            return;
          }
          const parsed: ParsedBridgeResponse = parsedResult.data;
          if (parsed.version !== BRIDGE_PROTOCOL_VERSION || parsed.requestID !== requestID) {
            finish(new Error("EagleGaze returned a mismatched bridge response."));
          } else if (!parsed.ok) {
            finish(new Error(parsed.error?.message ?? "EagleGaze rejected the bridge request."));
          } else if (!parsed.snapshot) {
            finish(new Error("EagleGaze returned no status snapshot."));
          } else {
            finish(undefined, parsed.snapshot);
          }
        } catch {
          finish(new Error("EagleGaze returned invalid bridge JSON."));
        }
      });
      socket.once("error", (error) => {
        finish(new Error(
          `Could not reach EagleGaze on 127.0.0.1:${this.port}. Open the EagleGaze Mac app first. (${error.message})`,
        ));
      });
      socket.once("end", () => {
        if (!settled) finish(new Error("EagleGaze closed the bridge before returning a response."));
      });
    });
  }
}

let mockPhase = "setup";

export async function requestFromEnvironment(command: BridgeCommand): Promise<BridgeSnapshot> {
  if (process.env.EAGLEGAZE_BRIDGE_MOCK === "1") {
    if (command === "start_calibration") mockPhase = "calibrating";
    if (command === "reset_calibration") mockPhase = "setup";
    return mockSnapshot(mockPhase);
  }

  return await new EagleGazeBridgeClient({
    port: DEFAULT_BRIDGE_PORT,
  }).request(command);
}

function mockSnapshot(phase: string): BridgeSnapshot {
  const calibrating = phase === "calibrating";
  return BridgeSnapshotSchema.parse({
    sourceKind: "phone",
    connectionState: "connected",
    calibrationState: calibrating ? "calibrating" : "setup",
    evaluationState: "idle",
    phase,
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
