import Accelerate
import AVFoundation

extension AVAudioPCMBuffer {
    /// Below this the buffer is silence: about -60 dBFS. A denied
    /// audio-capture permission delivers nothing but silence.
    static let silenceThreshold: Float = 0.001

    /// The loudest sample, from 0 to 1.
    var peakLevel: Float {
        let channels = Int(format.channelCount)
        let samples = Int(frameLength) * (format.isInterleaved ? channels : 1)
        let planes = format.isInterleaved ? 1 : channels
        guard samples > 0 else { return 0 }
        var peak: Float = 0
        if let data = floatChannelData {
            for plane in 0..<planes {
                var planePeak: Float = 0
                vDSP_maxmgv(data[plane], 1, &planePeak, vDSP_Length(samples))
                peak = max(peak, planePeak)
            }
        } else if let data = int16ChannelData {
            for plane in 0..<planes {
                for index in 0..<samples {
                    peak = max(peak, abs(Float(data[plane][index])) / Float(Int16.max))
                }
            }
        }
        return peak
    }
}
