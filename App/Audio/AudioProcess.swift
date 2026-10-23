import CoreAudio
import Darwin
import Foundation

/// A process registered with Core Audio.
struct AudioProcess: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    /// The app the process belongs to. Browser and meeting-app helpers report
    /// their host app, so picking "Google Chrome" also taps its renderers.
    let appBundleID: String
    let appName: String
    let isPlayingAudio: Bool

    var id: AudioObjectID { objectID }

    /// Whether the process is the app `bundleID` or one of its helpers.
    func belongs(to bundleID: String) -> Bool {
        appBundleID == bundleID || self.bundleID == bundleID
    }
}

/// One pickable app in the audio-source picker.
struct AudioApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let isPlayingAudio: Bool

    var id: String { bundleID }
}

enum AudioProcessList {
    static func current() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self, initial: .unknown)) ?? []
        return ids.compactMap(process(for:))
    }

    /// Apps with audio, playing ones first, without this app itself.
    static func apps() -> [AudioApp] {
        let ownBundleID = Bundle.main.bundleIdentifier
        var byID: [String: AudioApp] = [:]
        for process in current() where !process.appBundleID.isEmpty && process.appBundleID != ownBundleID {
            let playing = process.isPlayingAudio || (byID[process.appBundleID]?.isPlayingAudio ?? false)
            byID[process.appBundleID] = AudioApp(
                bundleID: process.appBundleID, name: process.appName, isPlayingAudio: playing)
        }
        return byID.values.sorted {
            if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func process(for id: AudioObjectID) -> AudioProcess? {
        guard let pid = try? id.read(kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
        let bundleID = (try? id.readString(kAudioProcessPropertyBundleID)) ?? ""
        let playing = (try? id.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
        let host = executablePath(pid: pid).flatMap(hostApp(executablePath:))
        return AudioProcess(
            objectID: id, pid: pid, bundleID: bundleID,
            appBundleID: host?.bundleID ?? bundleID,
            appName: host?.name ?? bundleID,
            isPlayingAudio: playing != 0)
    }

    /// The outermost `.app` bundle that contains `path`.
    static func hostApp(executablePath path: String) -> (bundleID: String, name: String)? {
        let components = URL(filePath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let appURL = URL(filePath: NSString.path(withComponents: Array(components[...index])))
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        return (bundleID, name)
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
