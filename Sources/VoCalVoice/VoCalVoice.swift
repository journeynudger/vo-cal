// VoCalVoice — Vo-Cal's voice capture state machine.
//
// Placeholder target: the Serein port (VoiceCaptureModels + CAFRepairer) lands
// here in Phase C task C0. Until then this file exists so the target compiles
// and the app can link against the product.

import VoCalCore

public enum VoCalVoiceInfo {
    /// Bumped when the ported state machine lands (C0).
    public static let portStatus = "placeholder-pre-C0"
}
