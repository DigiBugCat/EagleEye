/** EagleGaze — a VoiceOS integration server (standard MCP over stdio). */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createConnection } from "node:net";
import { z } from "zod";

const BRIDGE_PROTOCOL_VERSION = 1;
const DEFAULT_BRIDGE_PORT = 47_474;
const COMPANION_BUNDLE_ID = "com.aviary.EagleGazeMac";
const COMPANION_DOWNLOAD_URL = "https://github.com/DigiBugCat/EagleGaze/releases/latest";

type BridgeCommand = "status" | "start_calibration" | "reset_calibration" | "start_evaluation";

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

async function requestFromCompanion(command: BridgeCommand): Promise<BridgeSnapshot> {
  if (process.env.EAGLEGAZE_BRIDGE_MOCK === "1") return mockSnapshot(command);

  const requestID = crypto.randomUUID();
  const request = JSON.stringify({ version: BRIDGE_PROTOCOL_VERSION, requestID, command });

  return await new Promise<BridgeSnapshot>((resolve, reject) => {
    const socket = createConnection({ host: "127.0.0.1", port: DEFAULT_BRIDGE_PORT });
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
        if (parsed.version !== BRIDGE_PROTOCOL_VERSION || parsed.requestID !== requestID) {
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
        `Could not reach EagleGaze on 127.0.0.1:${DEFAULT_BRIDGE_PORT}. (${error.message})`,
      ));
    });
    socket.once("end", () => {
      if (!settled) finish(new CompanionUnavailableError("EagleGaze closed the bridge before responding."));
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
    privacyBoundary: "Raw ARKit transforms and gaze coordinates are not shared with VoiceOS.",
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
  "start_gaze_calibration",
  {
    title: "Start gaze calibration",
    description:
      "Start EagleGaze's full-screen nine-point calibration on this Mac. Use when the user asks to calibrate, recalibrate, or set up eye tracking.",
    inputSchema: {},
  },
  async () => await run("start_calibration"),
);

server.registerTool(
  "start_gaze_evaluation",
  {
    title: "Start gaze evaluation",
    description:
      "Start EagleGaze's bounded accuracy evaluation using the current calibration. Use when the user asks to test or score eye-tracking accuracy.",
    inputSchema: {},
  },
  async () => await run("start_evaluation"),
);

server.registerTool(
  "reset_gaze_calibration",
  {
    title: "Reset gaze calibration",
    description:
      "Clear EagleGaze's current calibration and return it to setup. Use only when the user explicitly asks to reset or clear eye-tracking calibration.",
    inputSchema: {},
  },
  async () => await run("reset_calibration"),
);

await server.connect(new StdioServerTransport());
