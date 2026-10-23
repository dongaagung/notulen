import AppKit
import PDFKit
import Synchronization
import WebKit

/// Prints the minutes' HTML to a PDF: A4 pages with selectable text. The
/// page is laid out in an offscreen web view, then WebKit paginates it
/// through a print operation that saves to the file instead of printing.
@MainActor
enum PDFExporter {
    /// A4 in points.
    static let paperSize = NSSize(width: 595.28, height: 841.89)
    /// The 18 mm margin of the HTML's `@page` rule, in points.
    static let margin: CGFloat = 18 / 25.4 * 72

    enum Failure: LocalizedError {
        case load(String)
        case notSaved

        var errorDescription: String? {
            switch self {
            case .load(let reason): "Halaman PDF tidak bisa disiapkan: \(reason)"
            case .notSaved: "File PDF tidak bisa disimpan."
            }
        }
    }

    /// "Weekly Sync – 2026-10-22.pdf". "/" and ":" become "-": Finder
    /// shows ":" as "/", and "/" can't be in a file name.
    nonisolated static func fileName(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let safe = title.replacing("/", with: "-").replacing(":", with: "-")
        return "\(safe) – \(stamp).pdf"
    }

    static func export(html: String, to url: URL) async throws {
        let frame = NSRect(origin: .zero, size: paperSize)
        let webView = WKWebView(frame: frame)
        // `runModal(for:)` needs a window: this one holds the web view and
        // never shows.
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.contentView = nil }

        let loader = Loader()
        webView.navigationDelegate = loader
        try await loader.load(html, in: webView)

        let operation = webView.printOperation(with: printInfo(saving: url))
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard await Runner().run(operation, for: window) else { throw Failure.notSaved }
        if let title = webView.title, !title.isEmpty { setTitle(title, of: url) }
    }

    /// Printing leaves the PDF untitled; the page's `<title>` becomes its
    /// Title. Best effort: the PDF is saved either way.
    private static func setTitle(_ title: String, of url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        document.documentAttributes = attributes
        guard let data = document.dataRepresentation() else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A4, saved to `url`. WebKit lays the pages out by the HTML's `@page`
    /// rule; the margins here only repeat it.
    private static func printInfo(saving url: URL) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = paperSize
        info.orientation = .portrait
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return info
    }

    /// Waits for the HTML to finish loading.
    @MainActor
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?

        func load(_ html: String, in webView: WKWebView) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        private func finish(_ error: (any Error)?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                continuation.resume(throwing: Failure.load(error.localizedDescription))
            } else {
                continuation.resume()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            finish(error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            finish(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(Failure.load("proses WebKit berhenti"))
        }
    }

    /// Runs a print operation without panels and waits for it to end. A
    /// web view prints asynchronously, so `runModal(for:)`, not `run()`;
    /// AppKit then reports the end from a thread of its own.
    private final class Runner: NSObject, Sendable {
        private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

        @MainActor
        func run(_ operation: NSPrintOperation, for window: NSWindow) async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation.withLock { $0 = continuation }
                operation.runModal(
                    for: window, delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
            }
        }

        @objc nonisolated private func printOperationDidRun(
            _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
        ) {
            continuation.withLock { $0.take() }?.resume(returning: success)
        }
    }
}
