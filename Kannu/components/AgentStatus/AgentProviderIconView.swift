import AppKit
import SwiftUI

enum AgentProviderIconSource: Equatable {
    case cursor
    case claude
    case codex
    case vscode
    case unknown(String)

    init(providerID: ProviderID) {
        switch providerID {
        case .cursor: self = .cursor
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }

    init(rawProvider: String) {
        switch rawProvider.lowercased() {
        case "cursor": self = .cursor
        case "claude": self = .claude
        case "codex": self = .codex
        case "vscode": self = .vscode
        default: self = .unknown(rawProvider)
        }
    }

    init(hookProvider: AgentHookProvider) {
        switch hookProvider {
        case .cursor: self = .cursor
        case .vscode: self = .vscode
        case .codex: self = .codex
        }
    }
}

struct AgentProviderIconView: View {
    let source: AgentProviderIconSource
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let icon = source.resolvedIconImage() {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                AppIconImage(
                    bundleIdentifiers: source.bundleIdentifiers,
                    symbolFallback: source.symbolFallback,
                    symbolColor: source.symbolColor,
                    size: size
                )
            }
        }
        .frame(width: size, height: size)
    }
}

private extension AgentProviderIconSource {
    var bundleIdentifiers: [String] {
        switch self {
        case .cursor:
            return ["com.cursor.Cursor", "com.todesktop.230313mzl4w4u92"]
        case .claude:
            return ["com.anthropic.claude"]
        case .codex:
            return ["com.openai.chat", "com.openai.codex"]
        case .vscode:
            return ["com.microsoft.VSCode", "com.visualstudio.code.oss"]
        case .unknown:
            return []
        }
    }

    var applicationPaths: [String] {
        switch self {
        case .cursor:
            return ["/Applications/Cursor.app"]
        case .claude:
            return ["/Applications/Claude.app"]
        case .codex:
            return ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        case .vscode:
            return ["/Applications/Visual Studio Code.app", "/Applications/Code.app"]
        case .unknown:
            return []
        }
    }

    var symbolFallback: String {
        switch self {
        case .cursor: return "cursorarrow.rays"
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .unknown: return "app.fill"
        }
    }

    var symbolColor: Color {
        switch self {
        case .cursor: return .primary
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.36)
        case .codex: return .green
        case .vscode: return Color(red: 0.27, green: 0.51, blue: 0.85)
        case .unknown: return .secondary
        }
    }

    func resolvedIconImage() -> NSImage? {
        for path in applicationPaths {
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            return Self.thumbnail(from: NSWorkspace.shared.icon(forFile: expanded))
        }

        for bundleID in bundleIdentifiers {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            return Self.thumbnail(from: NSWorkspace.shared.icon(forFile: appURL.path))
        }

        return nil
    }

    static func thumbnail(from icon: NSImage) -> NSImage {
        let thumb = NSImage(size: NSSize(width: 32, height: 32))
        thumb.lockFocus()
        icon.draw(
            in: NSRect(origin: .zero, size: NSSize(width: 32, height: 32)),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return thumb
    }
}
