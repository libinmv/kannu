/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI

/// The Terms of Use gate's content: the full text, an unchecked agreement box, and Accept / Decline.
///
/// Standard clickwrap on purpose. The whole text is on screen before the choice, the box starts
/// unchecked and Accept stays disabled until it is ticked, so acceptance is an affirmative act; and
/// Decline quits, so there is no way into the app around it.
struct TermsOfUseView: View {
    /// Nil when the bundle has no terms: the gate then fails closed and says why.
    let termsText: String?
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var agreed = false
    @State private var licenseMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kannu Terms of Use")
                    .font(.title2.weight(.semibold))
                Text("Please read these terms. You need to accept them to start using Kannu.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Group {
                    if let termsText {
                        Text(Self.rendered(termsText))
                    } else {
                        Text("The Terms of Use could not be loaded from this copy of Kannu. Please reinstall it from kannu.app.")
                            .foregroundStyle(.red)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            Toggle("I have read and agree to the Terms of Use", isOn: $agreed)
                .toggleStyle(.checkbox)
                .disabled(termsText == nil)

            HStack(spacing: 10) {
                Button("View License") {
                    licenseMissing = !LegalDocuments.open(.license)
                }
                if licenseMissing {
                    Text("The license is missing from this copy of Kannu.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Decline", role: .cancel, action: onDecline)
                Button("Accept", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!agreed || termsText == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 660)
    }

    /// The Markdown rendered for SwiftUI: the `# ` title line is dropped (the view shows its own),
    /// and the rest keeps its line breaks while bold section titles and links render inline.
    static func rendered(_ markdown: String) -> AttributedString {
        let body = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop { $0.hasPrefix("# ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }
}
