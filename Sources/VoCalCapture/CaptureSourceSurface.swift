import Foundation

/// Where a capture was made. Serein's shortcut intent and share extension were not ported
/// (foreground capture is the protected P0 scope), so only the recorder and the self-test
/// remain; the label is written into the outbox row, never decoded back into this type.
public enum CaptureSourceSurface: String, Sendable {
    case nativeRecorder = "native_recorder"
    case selfTest = "self_test"
}
