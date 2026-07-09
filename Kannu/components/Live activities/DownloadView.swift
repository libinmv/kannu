/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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

enum Browser {
    case safari
    case chrome
}

struct DownloadFile {
    var name: String
    var size: Int
    var formattedSize: String
    var browser: Browser
}

class DownloadWatcher: ObservableObject {
    @Published var downloadFiles: [DownloadFile] = []
}

struct DownloadArea: View {
    @EnvironmentObject var watcher: DownloadWatcher

    var body: some View {
        HStack(alignment: .center) {
            HStack {
                if watcher.downloadFiles.first!.browser == .safari {
                    AppIcon(for: "com.apple.safari")
                } else {
                    Image(.chrome).resizable().scaledToFit().frame(width: 30, height: 30)
                }
                VStack(alignment: .leading) {
                    Text("Download")
                    Text("In progress").font(.system(.footnote)).foregroundStyle(.gray)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                VStack(alignment: .trailing) {
                    Text(watcher.downloadFiles.first!.formattedSize)
                    Text(watcher.downloadFiles.first!.name).font(.caption2).foregroundStyle(.gray)
                }
            }
        }
    }
}
