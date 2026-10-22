import SwiftUI

/// SwiftUI's `State` property wrapper under another name. In the macOS 27 SDK
/// `@State` resolves to a macro whose plugin ships only with Xcode, and this
/// project builds with Command Line Tools, so views use `@ViewState`.
typealias ViewState<Value> = SwiftUI.State<Value>
