import SwiftUI

/// Options for Edit > Watercolor Fill Selection. The values stay on the session for the next fill.
struct WatercolorOptionsSheet: View {
    @Bindable var session: EditorSession
    @State private var angleText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("Bleed", value: session.watercolorOptions.bleed) {
                Slider(value: $session.watercolorOptions.bleed, in: 0...1)
            }
            labeled("Texture", value: session.watercolorOptions.texture) {
                Slider(value: $session.watercolorOptions.texture, in: 0...1)
            }
            labeled("Border", value: session.watercolorOptions.border) {
                Slider(value: $session.watercolorOptions.border, in: 0...1)
            }
            HStack {
                Text("Opacity")
                Slider(value: $session.watercolorOptions.opacity, in: 0...255)
                Text("\(Int(session.watercolorOptions.opacity.rounded()))")
                    .monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            Picker("Direction", selection: $session.watercolorOptions.outward) {
                Text("Out").tag(true)
                Text("In").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Angle")
                TextField("Random", text: $angleText)
                    .frame(width: 72)
                    .onSubmit { applyAngle() }
                Text("degrees, empty for a random start")
                    .foregroundStyle(.secondary)
            }
            Toggle("Scatter texture", isOn: $session.watercolorOptions.scatter)
            Toggle("Clip to selection", isOn: $session.watercolorOptions.clip)
            HStack {
                Spacer()
                Button("Cancel") { session.showWatercolorOptions = false }
                Button("Fill") {
                    applyAngle()
                    session.showWatercolorOptions = false
                    Task { await session.watercolorFillSelection() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            if let angle = session.watercolorOptions.angle { angleText = String(Int(angle.rounded())) }
        }
    }

    private func applyAngle() {
        let trimmed = angleText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { session.watercolorOptions.angle = nil; return }
        if let value = Double(trimmed), value.isFinite { session.watercolorOptions.angle = CGFloat(value) }
    }

    private func labeled(_ title: String, value: CGFloat, @ViewBuilder slider: () -> some View) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            slider()
            Text(value, format: .number.precision(.fractionLength(2)))
                .monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

/// Options for Edit > Hatch Selection. Rand defaults to 0, matching p5.brush.
struct HatchOptionsSheet: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Angle")
                Slider(value: $session.hatchOptions.angle, in: 0...180)
                Text("\(Int(session.hatchOptions.angle.rounded()))°").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("Spacing")
                Slider(value: Binding(get: { session.hatchOptions.spacing ?? max(4, session.brushSettings.diameter * 0.7) },
                                     set: { session.hatchOptions.spacing = $0 }), in: 2...80)
            }
            HStack {
                Text("Rand")
                Slider(value: $session.hatchOptions.rand, in: 0...1)
            }
            HStack {
                Text("Gradient")
                Slider(value: $session.hatchOptions.gradient, in: 0...1)
            }
            Toggle("Continuous", isOn: $session.hatchOptions.continuous)
            Picker("Brush", selection: Binding(get: { session.hatchOptions.brush ?? session.brushSettings.natural }, set: { session.hatchOptions.brush = $0 })) {
                ForEach(NaturalBrushKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { session.showHatchOptions = false }
                Button("Hatch") {
                    session.showHatchOptions = false
                    Task { await session.hatchSelection() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
