import SwiftUI

/// While the minutes are written: the finisher's steps, done ones ticked,
/// the current one spinning.
struct ProcessingView: View {
    let meeting: Meeting
    let step: MeetingFinisher.Step
    /// This run's steps, in order.
    let steps: [MeetingFinisher.Step]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Membuat notulen")
                    .font(.title2.weight(.semibold))
                Text("Biasanya selesai dalam 1–2 menit.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps, id: \.self) { row($0) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color.canvas.ignoresSafeArea() }
        .navigationTitle(meeting.title.isEmpty ? "Tanpa judul" : meeting.title)
    }

    private func row(_ item: MeetingFinisher.Step) -> some View {
        let index = steps.firstIndex(of: item) ?? 0
        let current = steps.firstIndex(of: step) ?? 0
        return HStack(spacing: 10) {
            Group {
                if index < current {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                } else if index == current {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(item.label)
                .foregroundStyle(index > current ? .secondary : .primary)
        }
    }
}
