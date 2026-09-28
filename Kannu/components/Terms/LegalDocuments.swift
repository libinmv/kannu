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

import AppKit

/// Opens the legal documents bundled with Kannu — the Terms of Use, the GPL and the NOTICE — which
/// the build copies from the repository root, so the app carries the one authoritative copy of each.
enum LegalDocuments {
    enum Document {
        case terms, license, notice

        fileprivate var resource: (name: String, extension: String) {
            switch self {
            case .terms: return TermsOfUse.termsResource
            case .license: return TermsOfUse.licenseResource
            case .notice: return TermsOfUse.noticeResource
            }
        }
    }

    static func url(for document: Document) -> URL? {
        let resource = document.resource
        return Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.extension.isEmpty ? nil : resource.extension
        )
    }

    /// The terms' text for the gate, or nil when the bundle is missing it.
    static func termsText() -> String? {
        guard let url = url(for: .terms) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Opens a document in TextEdit. Named explicitly because `LICENSE` and `NOTICE` have no
    /// extension, so `NSWorkspace.open(_:)` would have no app to choose. Returns false when the file
    /// is not in the bundle, so the caller can say so instead of doing nothing.
    @discardableResult
    static func open(_ document: Document) -> Bool {
        guard let url = url(for: document) else { return false }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
