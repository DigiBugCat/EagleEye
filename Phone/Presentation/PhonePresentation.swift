import SwiftUI

/// Presentation renders only canonical status and pairing/consent state.  It
/// never receives a face anchor, matrix, or gaze sample.
struct PhonePresentationRootView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.pairedReceivers.isEmpty {
                    PairMacView(model: model)
                } else if model.selectedReceiver == nil {
                    PairedMacPickerView(model: model)
                } else if !model.hasConsentForSelectedReceiver {
                    PhoneConsentView(model: model)
                } else {
                    PhoneStatusView(model: model)
                }
            }
            .navigationTitle("Eagle Gaze")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.presentPairingScanner()
                    } label: {
                        Label("Pair Mac", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Pair another Mac")
                }
            }
        }
        .sheet(isPresented: $model.isPairingScannerPresented) {
            PairingScannerSheet(model: model)
        }
    }
}

private struct PairMacView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Pair a Mac receiver", systemImage: "desktopcomputer.and.arrow.down")
        } description: {
            Text("Eagle Gaze keeps the camera local until you choose a Mac and grant explicit off-device gaze consent.")
        } actions: {
            Button("Scan Mac QR code") { model.presentPairingScanner() }
                .buttonStyle(.borderedProminent)
            if !model.pairingStatus.isEmpty {
                Text(model.pairingStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }
}

private struct PairedMacPickerView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        List {
            Section {
                Text("Choose one paired Mac for this session. Eagle Gaze never switches receivers implicitly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Paired Macs") {
                ForEach(model.pairedReceivers) { receiver in
                    Button {
                        model.select(receiver: receiver)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(receiver.displayName)
                                    .font(.headline)
                                Text(receiver.receiverFingerprint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            model.revoke(receiver: receiver)
                        } label: {
                            Label("Revoke", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

private struct PhoneConsentView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text("Allow gaze sharing?")
                .font(.title.bold())
            Text("Your iPhone processes face and eye signals on-device. If you continue, Eagle Gaze sends only canonical gaze direction, blink estimate, tracking status, and timing metadata to the selected paired Mac.")
                .font(.body)

            VStack(alignment: .leading, spacing: 10) {
                Label("No camera images or face meshes leave this iPhone.", systemImage: "camera.shutter.button")
                Label("The permission is scoped to this Mac.", systemImage: "lock.shield")
                Label("You can revoke it at any time.", systemImage: "xmark.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let receiver = model.selectedReceiver {
                Text("Selected destination: \(receiver.displayName)")
                    .font(.headline)
            }

            Button("Allow gaze sharing") {
                model.grantConsentForSelectedReceiver()
            }
            .buttonStyle(.borderedProminent)

            if !model.streamStatus.isEmpty {
                Text(model.streamStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(28)
    }
}

private struct PhoneStatusView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: model.faceTracking.isTracking ? "eye.circle.fill" : "eye.slash.circle")
                        .font(.system(size: 42))
                        .foregroundStyle(model.faceTracking.isTracking ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.faceTracking.status)
                            .font(.headline)
                        Text(model.streamStatus)
                            .font(.callout)
                            .foregroundStyle(model.isRunning ? .green : .secondary)
                    }
                }
            }

            if let receiver = model.selectedReceiver {
                Section("Selected Mac") {
                    Label(receiver.displayName, systemImage: "desktopcomputer")
                    Text(receiver.receiverFingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Revoke this Mac", role: .destructive) {
                        model.revoke(receiver: receiver)
                    }
                }
            }

            if model.pairedReceivers.count > 1 {
                Section("Switch Mac") {
                    ForEach(model.pairedReceivers) { receiver in
                        Button {
                            model.select(receiver: receiver)
                        } label: {
                            HStack {
                                Text(receiver.displayName)
                                Spacer()
                                if receiver.pairID == model.selectedReceiver?.pairID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Privacy") {
                Text("Only canonical status crosses the authenticated local-network stream. Raw ARKit data stays inside the phone tracker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Revoke gaze consent", role: .destructive) {
                    model.revokeConsent()
                }
            }

            Section {
                Label("Mount the phone below the center of the Mac display.", systemImage: "iphone.gen3")
                Label("Keep the TrueDepth camera pointed at your face.", systemImage: "faceid")
                Label("Streaming pauses when the app enters the background.", systemImage: "pause.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .refreshable { model.refreshCatalog() }
    }
}

private struct PairingScannerSheet: View {
    @ObservedObject var model: PhoneAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scannerError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Scan the QR code shown by Eagle Gaze on your Mac.")
                    .multilineTextAlignment(.center)
                Text(model.pairingStatus.isEmpty ? "The QR is validated locally; pairing still requires an authenticated Mac handshake." : model.pairingStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let scannerError {
                    Text(scannerError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(28)
            .navigationTitle("Pair Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.stopPairingScanner()
                        dismiss()
                    }
                }
            }
            .task {
                do { try model.startPairingScanner() }
                catch { scannerError = error.localizedDescription }
            }
            .onDisappear {
                model.stopPairingScanner()
            }
        }
    }
}
