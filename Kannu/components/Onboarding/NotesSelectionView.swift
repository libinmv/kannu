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

import Defaults
import SwiftUI

/// What onboarding's Notes step chose. Held by `OnboardingView` and applied at Finish, like the
/// music source: turning Apple Notes sync on talks to Notes, and that Automation dialog belongs to
/// the Permissions step that follows.
enum OnboardingNotesChoice: CaseIterable, Identifiable {
    case off
    case notchOnly
    case kannuFolder
    case wholeAccount

    var id: Self { self }

    /// Whether the Permissions step needs its "Control Notes" row.
    var syncsWithAppleNotes: Bool { self == .kannuFolder || self == .wholeAccount }

    /// Written at Finish. After a Not now on "Control Notes", the notes stay in the notch and sync
    /// stays off, so nothing asks later; the user can turn it on in Brain › Notes.
    func apply(notesAutomationDeferred: Bool) {
        guard self != .off else { return }
        Defaults[.enableNotes] = true
        Defaults[.appleNotesSyncScope] = self == .wholeAccount ? .wholeAccount : .kannuFolder
        Defaults[.appleNotesSyncScopeMigrated] = true
        Defaults[.enableAppleNotesSync] = syncsWithAppleNotes && !notesAutomationDeferred
    }
}

/// Onboarding step: whether the notch keeps notes, and whether they sync with Apple Notes.
/// Nothing here touches Notes; the choice is returned on Continue.
struct NotesSelectionView: View {
    let onContinue: (OnboardingNotesChoice) -> Void

    @State private var selection: OnboardingNotesChoice = .off

    var body: some View {
        VStack(spacing: 20) {
            Text("Notes in the Notch?")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text("Jot something down without leaving your editor. You can change this later in Brain › Notes.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(spacing: 10) {
                ForEach(OnboardingNotesChoice.allCases) { choice in
                    NotesOptionCard(
                        icon: icon(for: choice),
                        title: title(for: choice),
                        subtitle: subtitle(for: choice),
                        isSelected: selection == choice,
                        onTap: { withAnimation(.easeInOut(duration: 0.2)) { selection = choice } }
                    )
                }
            }
            .padding(.horizontal)

            Spacer()

            Button("Continue") {
                onContinue(selection)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private func icon(for choice: OnboardingNotesChoice) -> String {
        switch choice {
        case .off: return "xmark"
        case .notchOnly: return "note.text"
        case .kannuFolder: return "folder"
        case .wholeAccount: return "tray.full"
        }
    }

    private func title(for choice: OnboardingNotesChoice) -> String {
        switch choice {
        case .off: return String(localized: "No notes")
        case .notchOnly: return String(localized: "Notes in the notch")
        case .kannuFolder: return String(localized: "Sync the Kannu folder")
        case .wholeAccount: return String(localized: "Sync all my Apple Notes")
        }
    }

    private func subtitle(for choice: OnboardingNotesChoice) -> String {
        switch choice {
        case .off:
            return String(localized: "Leave the Notes tab off.")
        case .notchOnly:
            return String(localized: "Notes stay on this Mac, in the notch only.")
        case .kannuFolder:
            return String(localized: "Two-way sync with a Kannu folder in Apple Notes. Your other notes are never touched.")
        case .wholeAccount:
            return String(localized: "Also shows every note in your Apple Notes account, read-only in the notch.")
        }
    }
}

private struct NotesOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 40, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 2 : 0)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { isHovering = hovering }
        }
    }
}
