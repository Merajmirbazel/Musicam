import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Draws a QR code for a piece of text, sharp at any size.
enum QRCode {
    static func image(for text: String, side: CGFloat = 640) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (side / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

/// The pairing QR code, on a white tile so every camera can read it in dark mode too.
struct PairingQRView: View {
    let text: String

    var body: some View {
        if let image = QRCode.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 12))
                .frame(maxWidth: 240)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Pairing QR code")
        }
    }
}
