import AVFoundation
import AppKit
import CoreGraphics

/// Thin helpers around the two TCC surfaces the recorder needs: Screen
/// Recording and Microphone. Screen Recording has no Info.plist key — it is
/// entirely TCC-managed and only sticks across launches for a signed build.
enum Permissions {
    // MARK: Screen Recording

    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt on first call. Returns the current grant.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Microphone

    static func micStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        switch micStatus() {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
