import SwiftUI

/// Presentation renders only canonical status and saved-pairing state. It
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
                } else {
                    PhoneStatusView(model: model)
                }
            }
            .navigationTitle("EagleGaze")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(EaglePhoneStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if !model.pairedReceivers.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isNearbyPairingPresented = true
                        model.refreshNearbyMacs()
                    } label: {
                        Image(systemName: "desktopcomputer.and.arrow.down")
                    }
                    .accessibilityLabel("Pair another Mac")
                    }
                }
            }
        }
        .tint(EaglePhoneStyle.accent)
        .sheet(isPresented: $model.isNearbyPairingPresented) {
            NearbyMacPairingSheet(model: model)
        }
    }
}

private struct PairMacView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        EaglePhoneScrollSurface {
            VStack(spacing: 22) {
                Spacer(minLength: 42)

                EagleHeroIcon(systemName: "desktopcomputer.and.arrow.down")

                VStack(spacing: 8) {
                    Text("Pair your Mac")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("Choose an EagleGaze Mac on the nearby network, confirm the matching code, and approve it on the Mac.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                EagleCard {
                    VStack(spacing: 0) {
                        PrivacyRow(
                            icon: "iphone.gen3",
                            title: "On-device eye tracking",
                            detail: "Face and eye signals are processed on this iPhone."
                        )
                        EagleDivider()
                        PrivacyRow(
                            icon: "lock.shield.fill",
                            title: "Destination scoped",
                            detail: "You choose exactly which paired Mac can receive gaze."
                        )
                    }
                }

                NearbyMacDiscoveryView(model: model)

                Text("Both devices must be on the same Wi-Fi or within peer-to-peer range.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 20)
            }
        }
        .task {
            if model.nearbyMacs.isEmpty { model.refreshNearbyMacs() }
        }
    }
}

private struct PairedMacPickerView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        EaglePhoneScrollSurface {
            VStack(alignment: .leading, spacing: 18) {
                EagleScreenHeader(
                    eyebrow: "RECEIVER",
                    title: "Choose your Mac",
                    detail: "Select one destination for this session. EagleGaze never switches receivers implicitly."
                )

                VStack(spacing: 10) {
                    ForEach(model.pairedReceivers) { receiver in
                        EagleCard(padding: 0) {
                            HStack(spacing: 12) {
                                Button {
                                    model.select(receiver: receiver)
                                } label: {
                                    HStack(spacing: 13) {
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 19, weight: .semibold))
                                            .foregroundStyle(EaglePhoneStyle.accent)
                                            .frame(width: 38, height: 38)
                                            .background(EaglePhoneStyle.accentSoft, in: Circle())

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(receiver.displayName)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text(receiver.receiverFingerprint)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 6)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.bold())
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button("Revoke this Mac", role: .destructive) {
                                        model.revoke(receiver: receiver)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 34, height: 44)
                                }
                                .accessibilityLabel("Actions for \(receiver.displayName)")
                            }
                            .padding(14)
                        }
                    }
                }

                if !model.pairingStatus.isEmpty {
                    StatusBanner(text: model.pairingStatus)
                }

                Button {
                    model.isNearbyPairingPresented = true
                    model.refreshNearbyMacs()
                } label: {
                    Label("Pair another Mac", systemImage: "desktopcomputer.and.arrow.down")
                }
                .buttonStyle(EagleSecondaryButtonStyle())
            }
        }
    }
}

private struct PhoneStatusView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        EaglePhoneScrollSurface {
            VStack(spacing: 16) {
                TrackingStatusHero(
                    isRunning: model.isRunning,
                    isTracking: model.faceTracking.isTracking,
                    isSynced: model.sender.isConnected,
                    title: model.faceTracking.isTracking ? "Face and eyes tracking" : model.faceTracking.status,
                    detail: model.streamStatus
                )

                if model.authenticationNeedsRepair {
                    EagleCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Mac authentication needs attention", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.headline)
                                .foregroundStyle(EaglePhoneStyle.accent)
                            Button("Retry authentication") {
                                model.retryAuthentication()
                            }
                            .buttonStyle(EaglePrimaryButtonStyle())
                            Button("Repair saved connection") {
                                model.beginPairingRepair()
                            }
                            .buttonStyle(EagleSecondaryButtonStyle())
                            Text("Retry for a temporary outage. Repair after the Mac app was rebuilt, reinstalled, or changed identity.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                        }
                    }
                }

                if let receiver = model.selectedReceiver {
                    EagleCard(padding: 0) {
                        VStack(spacing: 0) {
                            DetailRow(label: "Receiver", value: receiver.displayName)
                            EagleDivider()
                            DetailRow(label: "Transport", value: "Authenticated local network")
                            EagleDivider()
                            DetailRow(label: "Fingerprint", value: receiver.receiverFingerprint, monospaced: true)
                        }
                    }
                }

                if model.pairedReceivers.count > 1 {
                    EagleCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SWITCH MAC")
                                .font(.caption2.weight(.semibold))
                                .tracking(1)
                                .foregroundStyle(.tertiary)

                            ForEach(model.pairedReceivers) { receiver in
                                Button {
                                    model.select(receiver: receiver)
                                } label: {
                                    HStack {
                                        Image(systemName: "desktopcomputer")
                                            .foregroundStyle(EaglePhoneStyle.accent)
                                        Text(receiver.displayName)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if receiver.pairID == model.selectedReceiver?.pairID {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(EaglePhoneStyle.accent)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                EagleCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Secure saved connection", systemImage: "lock.shield.fill")
                            .font(.headline)
                            .foregroundStyle(EaglePhoneStyle.accent)
                        Text("This Mac is saved as a trusted receiver. EagleGaze automatically creates a fresh encrypted session whenever both apps are available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                }

                VStack(spacing: 10) {
                    if let receiver = model.selectedReceiver {
                        Button("Revoke \(receiver.displayName)", role: .destructive) {
                            model.revoke(receiver: receiver)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                    }
                }

                Text("Pull down to refresh paired Macs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .refreshable { model.refreshCatalog() }
    }
}

private struct NearbyMacPairingSheet: View {
    @ObservedObject var model: PhoneAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EaglePhoneScrollSurface {
                VStack(alignment: .leading, spacing: 18) {
                    EagleScreenHeader(
                        eyebrow: "NEARBY",
                        title: model.isRepairingConnection ? "Repair Mac connection" : "Pair another Mac",
                        detail: model.isRepairingConnection
                            ? "Choose the same Mac again. The old saved connection is replaced only after the new pairing is approved."
                            : "Choose an EagleGaze Mac, compare the six-digit code, then approve on the Mac."
                    )
                    NearbyMacDiscoveryView(model: model)
                }
            }
            .navigationTitle("Nearby Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.cancelNearbyPairing()
                        dismiss()
                    }
                }
            }
            .task {
                if model.nearbyMacs.isEmpty { model.refreshNearbyMacs() }
            }
        }
        .tint(EaglePhoneStyle.accent)
    }
}

private struct NearbyMacDiscoveryView: View {
    @ObservedObject var model: PhoneAppModel

    var body: some View {
        VStack(spacing: 12) {
            if let code = model.pairingVerificationCode {
                EagleCard {
                    VStack(spacing: 8) {
                        Label("Confirm on your Mac", systemImage: "checkmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(EaglePhoneStyle.accent)
                        Text(formatted(code))
                            .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                            .tracking(3)
                        Text("Approve only if the Mac shows this same code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if model.isDiscoveringNearbyMacs {
                EagleCard {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for EagleGaze Macs…")
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(model.nearbyMacs) { candidate in
                    EagleCard(padding: 0) {
                        Button {
                            model.pair(with: candidate)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(EaglePhoneStyle.accent)
                                    .frame(width: 40, height: 40)
                                    .background(EaglePhoneStyle.accentSoft, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("Nearby EagleGaze Mac")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.isPairingNearbyMac {
                                    ProgressView()
                                } else {
                                    Text("Pair")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(EaglePhoneStyle.accent)
                                }
                            }
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isPairingNearbyMac)
                    }
                }
            }

            if !model.pairingStatus.isEmpty {
                StatusBanner(text: model.pairingStatus)
            }

            Button {
                model.refreshNearbyMacs()
            } label: {
                Label("Refresh nearby Macs", systemImage: "arrow.clockwise")
            }
            .buttonStyle(EagleSecondaryButtonStyle())
            .disabled(model.isDiscoveringNearbyMacs || model.isPairingNearbyMac)
        }
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

// MARK: - EagleGaze phone design language

private enum EaglePhoneStyle {
    static let accent = Color.blue
    static let accentSoft = Color.blue.opacity(0.11)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color.primary.opacity(0.07)
}

private struct EaglePhoneScrollSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 28)
        }
        .background(EaglePhoneStyle.background.ignoresSafeArea())
    }
}

private struct EagleCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 15, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EaglePhoneStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(EaglePhoneStyle.border, lineWidth: 1)
            }
    }
}

private struct EagleScreenHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(EaglePhoneStyle.accent)
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EagleHeroIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 36, weight: .semibold))
            .foregroundStyle(EaglePhoneStyle.accent)
            .frame(width: 76, height: 76)
            .background(EaglePhoneStyle.accentSoft, in: Circle())
            .overlay {
                Circle().stroke(Color.blue.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private struct PrivacyRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(EaglePhoneStyle.accent)
                .frame(width: 28, height: 28)
                .background(EaglePhoneStyle.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

private struct MountStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        EagleCard {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(EaglePhoneStyle.accent)
                    .frame(width: 26, height: 26)
                    .background(EaglePhoneStyle.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                }
            }
        }
    }
}

private struct TrackingStatusHero: View {
    let isRunning: Bool
    let isTracking: Bool
    let isSynced: Bool
    let title: String
    let detail: String

    private var statusColor: Color {
        isRunning && isTracking ? .green : (isRunning ? EaglePhoneStyle.accent : .secondary)
    }

    var body: some View {
        VStack(spacing: 11) {
            TimelineView(.animation(minimumInterval: 0.10, paused: !isRunning)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let pulse = (sin(phase * .pi * 2) + 1) / 2
                ZStack {
                    Circle()
                        .trim(from: isSynced ? 0.08 : 0, to: isSynced ? 0.82 : 1)
                        .stroke(
                            isSynced ? EaglePhoneStyle.accent : statusColor.opacity(0.18),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(isSynced ? phase * 360 : 0))
                        .frame(width: 82, height: 82)
                    Circle()
                        .stroke(statusColor.opacity(0.72 + pulse * 0.28), lineWidth: 4)
                        .frame(width: 68, height: 68)
                        .scaleEffect(isTracking ? 0.97 + pulse * 0.05 : 1)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 18, height: 18)
                        .scaleEffect(isTracking ? 0.88 + pulse * 0.22 : 1)
                        .shadow(color: statusColor.opacity(0.35 + pulse * 0.25), radius: 8)
                }
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 12) {
                Label(isTracking ? "Eyes locked" : "Finding eyes", systemImage: isTracking ? "eye.fill" : "eye.slash")
                Label(isSynced ? "Mac synced" : "Mac waiting", systemImage: isSynced ? "arrow.triangle.2.circlepath" : "pause.circle")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }
}

private struct StatusBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.footnote)
            .foregroundStyle(EaglePhoneStyle.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(EaglePhoneStyle.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct WarningBanner: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(Color(red: 0.52, green: 0.34, blue: 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct EagleDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

private struct EaglePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(EaglePhoneStyle.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct EagleSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(EaglePhoneStyle.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(EaglePhoneStyle.accentSoft.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct EagleDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
