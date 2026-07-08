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

enum ClipboardTab: String, CaseIterable {
    case history = "History"
    case favorites = "Favorites"
    
    var icon: String {
        switch self {
        case .history: return "clock"
        case .favorites: return "heart.fill"
        }
    }
    
    var localizedName: String {
        switch self {
            case .history: return String(localized: "History")
            case .favorites: return String(localized: "Favorites")
        }
    }
}

struct ClipboardTabButton: View {
    let tab: ClipboardTab
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    
    var itemCount: Int {
        switch tab {
        case .history:
            return clipboardManager.regularHistory.count
        case .favorites:
            return clipboardManager.pinnedItems.count
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                
                Text(tab.localizedName)
                    .font(.system(size: 11, weight: .medium))
                
                if itemCount > 0 {
                    Text("\(itemCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.3) : Color.gray.opacity(0.2))
                        )
                }
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
