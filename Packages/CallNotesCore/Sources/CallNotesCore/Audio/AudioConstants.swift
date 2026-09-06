import Foundation

/// Capture-format constants shared by the capture graph and providers.
public enum AudioConstants {
    /// Local engines (SpeechAnalyzer, Parakeet) consume 16 kHz mono Int16.
    public static let localSampleRate = 16_000
    /// The Meta provider branch resamples to 24 kHz.
    public static let metaSampleRate = 24_000
    /// Mac captures are 2-channel CAF: L = near (you), R = far (them).
    public static let captureChannels = 2
    /// Ring-buffer length so a late-starting engine loses no audio.
    public static let ringBufferSeconds: TimeInterval = 30
}
