import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders the short-lived pairing offer.  The QR is presentation-only; the
/// offer itself is validated and authenticated by PairingService.
struct PairingQRView: View {
    let value: String

    var body: some View {
        Group {
            if let image = makeImage() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .background(.white)
            } else {
                Text(value)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary)
            }
        }
        .frame(width: 180, height: 180)
        .accessibilityLabel("EagleGaze pairing offer")
    }

    private func makeImage() -> NSImage? {
        guard let data = value.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
