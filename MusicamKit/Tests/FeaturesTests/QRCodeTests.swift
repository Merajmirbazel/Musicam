import Testing
import Foundation
import CoreImage
import Peering
@testable import Features

@Suite struct QRCodeTests {
    @Test func theQRCodeReadsBackAsTheSamePairingLink() throws {
        let key = PairingKey.generate()
        let image = try #require(QRCode.image(for: key.pairingLink))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [key.pairingLink])
        #expect(PairingKey(scanned: try #require(found.first)) == key)
    }
}
