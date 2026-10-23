import Testing
@testable import Notulen

struct TextScaleTests {
    @Test func stepsUpAndDownAndStopsAtTheEnds() {
        #expect(TextScale.bigger(than: 1.25) == 1.4)
        #expect(TextScale.smaller(than: 1.25) == 1.15)
        #expect(TextScale.bigger(than: 2.4) == 2.4)
        #expect(TextScale.smaller(than: 0.85) == 0.85)
        // A value between steps (from an older build) snaps to the next step.
        #expect(TextScale.bigger(than: 1.3) == 1.4)
        #expect(TextScale.smaller(than: 1.3) == 1.25)
    }

    /// A pinch takes one step once it opens or closes past 10%.
    @Test func pinchStepsPastTenPercent() {
        #expect(TextScale.pinched(1.25, magnification: 1.05) == nil)
        #expect(TextScale.pinched(1.25, magnification: 0.95) == nil)
        #expect(TextScale.pinched(1.25, magnification: 1.2) == 1.4)
        #expect(TextScale.pinched(1.25, magnification: 0.8) == 1.15)
        #expect(TextScale.pinched(2.4, magnification: 1.5) == 2.4)
    }
}
