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

import Foundation
import SwiftUI
import Defaults

struct SystemItemButton: View {
    @EnvironmentObject var vm: KannuViewModel
    @State var icon: String = "gear"
    var onTap: () -> Void
    @State var label: String?
    @State var showEmojis: Bool = true
    @State var emoji: String = "🔧"

    var body: some View {
        Button(action: onTap) {
            if Defaults[.tileShowLabels] {
                HStack {
                    if !showEmojis {
                        Image(systemName: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 10)
                            .foregroundStyle(.gray)
                    }

                    Text((showEmojis ? "\(emoji) " : "") + label!)
                        .font(.caption2)
                        .fontWeight(.regular)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            } else {
                Color.clear
                    .overlay {
                        Image(systemName: icon)
                            .foregroundStyle(.gray)
                    }
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .buttonStyle(BouncingButtonStyle(vm: vm))
    }
}

func logout() {
    DispatchQueue.global(qos: .background).async {
        let appleScript = """
        tell application "System Events" to log out
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("Error: \(error)")
            }
        }
    }
}

struct KannuSystemTiles: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Microphone privacy indicator runs automatically whenever apps access audio.")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.gray)
            }

            Text("Manage indicator preferences from Settings → Privacy. No manual microphone toggle is required.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

#Preview {
    KannuSystemTiles().padding()
}
