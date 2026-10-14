import SwiftUI

/// Play, pause, and speed for the stroke recording already stored in the open project.
/// Speed changes how fast those lines are drawn. It does not rewrite `strokes.jsonl`.
struct StrokePlaybackBar: View {
    @Bindable var session: EditorSession
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Strokes").font(ToolHeaderStyle.titleFont)
            Button(session.strokePlaybackTitle, action: toggle)
                .disabled(session.document == nil)
                .help(session.strokePlaybackHelp)
                .accessibilityIdentifier("strokePlayback")
            Text(session.strokePlaybackStatus)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("strokePlaybackStatus")
            Text("Speed")
            Slider(value: Binding(get: { Double(session.strokePlaybackRate) },
                                  set: { session.strokePlaybackRate = CGFloat($0) }),
                   in: 0.25...8)
                .frame(width: 140)
                .help("How fast the recording is drawn. 1× is the pace written in the file. The file is not changed.")
                .accessibilityIdentifier("strokePlaybackSpeed")
            Text(session.strokePlaybackRateLabel)
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .toolHeaderBar()
    }
}
