import Foundation
@preconcurrency import AVFoundation

struct MicDevice: Equatable {
    let uniqueID: String
    let name: String
}

enum MicDevices {
    static func available() -> [MicDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { MicDevice(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    static func systemDefault() -> MicDevice? {
        guard let d = AVCaptureDevice.default(for: .audio) else { return nil }
        return MicDevice(uniqueID: d.uniqueID, name: d.localizedName)
    }
}
