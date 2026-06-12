import Foundation

public enum CaptureSourceSurface: String, Sendable {
    case shortcutAppIntent = "shortcut_app_intent"
    case shareExtension = "share_extension"
    case nativeRecorder = "native_recorder"
    case selfTest = "self_test"
}
