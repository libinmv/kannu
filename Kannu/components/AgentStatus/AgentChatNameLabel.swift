import SwiftUI

struct AgentChatNameLabel: View {
    let text: String
    var secondarySuffix: String? = nil
    var separator: String = " · "
    var maxStaticLength: Int = 12
    var font: Font = .caption2
    var nsFont: NSFont.TextStyle = .caption1
    var textColor: Color = .secondary
    var secondaryTextColor: Color = .secondary
    var marqueeWidth: CGFloat = 160

    @State private var isHovering = false

    private var normalizedSecondarySuffix: String? {
        let trimmed = secondarySuffix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var combinedText: String {
        guard let normalizedSecondarySuffix else { return text }
        return text + separator + normalizedSecondarySuffix
    }

    private var usesMarquee: Bool {
        combinedText.count > maxStaticLength
    }

    private var staticText: String {
        guard usesMarquee else { return combinedText }
        return String(combinedText.prefix(maxStaticLength)) + "…"
    }

    var body: some View {
        Group {
            if usesMarquee, isHovering {
                MarqueeText(
                    .constant(combinedText),
                    font: font,
                    nsFont: nsFont,
                    textColor: textColor,
                    minDuration: 0.35,
                    frameWidth: marqueeWidth
                )
            } else if let normalizedSecondarySuffix {
                (
                    Text(text).foregroundStyle(textColor)
                    + Text(separator + normalizedSecondarySuffix).foregroundStyle(secondaryTextColor)
                )
                .font(font)
                .lineLimit(1)
                .frame(maxWidth: usesMarquee ? marqueeWidth : nil, alignment: .leading)
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
