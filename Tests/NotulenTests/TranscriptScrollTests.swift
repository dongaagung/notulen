import AppKit
import SwiftUI
import Testing
@testable import Notulen

@MainActor
struct TranscriptScrollTests {
    /// Opened mid-meeting (the inspector), a long transcript shows its
    /// latest lines, not its first, without waiting for the next line.
    @Test func opensAtTheLatestLine() async throws {
        let lines = (0..<200).map {
            TranscriptLine(channel: .meeting, speaker: .others, text: "Baris \($0)", start: Double($0), end: Double($0) + 1)
        }
        // Never shown on screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSHostingView(
            rootView: TranscriptView(transcript: Transcript(lines: lines)).frame(width: 300, height: 400))
        window.contentView = content
        var scrollView: NSScrollView?
        let atEnd = await waitUntil {
            content.layoutSubtreeIfNeeded()
            scrollView = Self.scrollView(in: content)
            guard let scrollView, let height = scrollView.documentView?.frame.height, height > 1_000 else {
                return false
            }
            return scrollView.documentVisibleRect.maxY >= height - 30
        }
        #expect(atEnd, "visible \(scrollView?.documentVisibleRect ?? .zero), content \(scrollView?.documentView?.frame.height ?? 0)")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
