import Foundation

/// Capture-format constants shared by the capture graph and providers.
public enum AudioConstants {
    /// Local engines (SpeechAnalyzer, Parakeet) consume 16 kHz mono Int16.
    public static let localSampleRate = 16_000
    /// The Meta provider branch resamples to 24 kHz.
    public static let metaSampleRate = 24_000
    /// Mac captures are 2-channel CAF: L = near (you), R = far (them).
    public static let captureChannels = 2
    /// Near (you) is the left CAF channel.
    public static let nearChannelIndex = 0
    /// Far (them) is the right CAF channel.
    public static let farChannelIndex = 1
    /// Linear PCM bit depth written into the capture CAF.
    public static let captureBitDepth = 16
    /// Ring-buffer length so a late-starting engine loses no audio.
    public static let ringBufferSeconds: TimeInterval = 30
    /// Mic-running poll interval used by the Mac detector.
    public static let detectorPollInterval: TimeInterval = 0.5
    /// Both detector signals must stay true this long before auto-record starts.
    public static let startDebounceSeconds: TimeInterval = 5
    /// Calendar arm (EventKit) shortens the start debounce.
    public static let armedStartDebounceSeconds: TimeInterval = 1
    /// Either detector signal false this long stops auto-record.
    public static let stopDebounceSeconds: TimeInterval = 5
    /// Capture harness: near/far timestamps must agree within this window.
    public static let alignmentTolerance: TimeInterval = 0.050
    /// RMS below this Int16 amplitude is treated as a silent channel.
    public static let silenceRMSThreshold: Float = 200
}
