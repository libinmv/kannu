import SwiftUI

struct AgentChatNameLabel: View {
    let text: String
    var maxStaticLength: Int = 12
    var font: Font = .caption2
    var nsFont: NSFont.TextStyle = .caption1
    var textColor: Color = .secondary
    var marqueeWidth: CGFloat = 160

    @State private var isHovering = false

    private var usesMarquee: Bool {
        text.count > maxStaticLength
    }

    private var staticText: String {
        guard usesMarquee else { return text }
        return String(text.prefix(maxStaticLength)) + "…"
    }

    var body: some View {
        Group {
            if usesMarquee, isHovering {
                MarqueeText(
                    .constant(text),
                    font: font,
                    nsFont: nsFont,
                    textColor: textColor,
                    minDuration: 0.35,
                    frameWidth: marqueeWidth
                )
            } else {
                Text(staticText)
                    .font(font)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .frame(maxWidth: usesMarquee ? marqueeWidth : nil, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
