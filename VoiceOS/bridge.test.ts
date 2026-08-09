import { afterEach, describe, expect, test } from "bun:test";
import { createServer, type Server } from "node:net";
import { BridgeSnapshotSchema, EagleGazeBridgeClient } from "./bridge.ts";

let server: Server | undefined;

afterEach(() => {
  server?.close();
  server = undefined;
});

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
});
