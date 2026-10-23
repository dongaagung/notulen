import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep by itself while a meeting records (the
/// display may still turn off), and reports when it sleeps anyway, as when
/// the lid closes without an external display or the battery runs out.
@MainActor
final class PowerGuard {
    /// Called before the Mac sleeps. Capture should stop here, at once.
    var onWillSleep: (@MainActor () -> Void)?
    var onDidWake: (@MainActor () -> Void)?

    /// True while it keeps the Mac awake.
    private(set) var preventsSleep = false

    private let notificationCenter: NotificationCenter
    private let takesSystemAssertion: Bool
    private var assertion: IOPMAssertionID?
    private var observers: [any NSObjectProtocol] = []

    /// `notificationCenter` posts sleep and wake: the workspace's, or a
    /// test's own. Without `takesSystemAssertion` (tests), `preventsSleep`
    /// follows `begin()`, sleep and `end()` but the system is never asked.
    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        takesSystemAssertion: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        self.takesSystemAssertion = takesSystemAssertion
    }

    /// Keeps the Mac awake and listens for sleep and wake. After a sleep it
    /// keeps listening, but only keeps the Mac awake once called again.
    func begin() {
        if observers.isEmpty { observeSleepAndWake() }
        guard !preventsSleep else { return }
        if takesSystemAssertion {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Notulen sedang merekam" as CFString,
                &id)
            guard result == kIOReturnSuccess else { return }
            assertion = id
        }
        preventsSleep = true
    }

    /// Lets the Mac sleep again and stops listening.
    func end() {
        releaseAssertion()
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers = []
    }

    private func releaseAssertion() {
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
        preventsSleep = false
    }

    private func observeSleepAndWake() {
        observers = [
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDidWake?() }
            },
        ]
    }

    /// Nothing records while asleep, nor while the owner is asked whether to
    /// go on after a long sleep, so the Mac may sleep again until `begin()`.
    private func willSleep() {
        releaseAssertion()
        onWillSleep?()
    }
}
