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
import SwiftUIIntrospect

struct ProOnboard: View {
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Image("spotlight")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.bottom)
                    .blur(radius: 3)
                    .offset(y: -5)
                    .background(SparkleView().opacity(0.6))
                VStack(spacing: 8) {
                    Image("logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .padding(.bottom, 8)
                    Text("Kannu")
                        .font(.system(.largeTitle, design: .serif))
                    Text("Welcome")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 30)
                    if false {
                        Text("PRO")
                            .font(.system(size: 18, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.7), location: 0.3), .init(color: .clear, location: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .blendMode(.overlay)
                            )
                            .padding(.bottom, 30)
                    }
                    Button {
                        if let url = URL(string: "https://www.linkedin.com/in/hariharan-mudaliar/") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Buy us a coffee", systemImage: "cup.and.saucer.fill")
                            .font(.headline)
                            .foregroundColor(Color.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.yellow)
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.bottom, 20)

                    Button {
                        NSApp.keyWindow?.close()
                    } label: {
                        Text("Get started")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                }
                .padding(.top)
            }
            
            Image("dynamicisland")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
                .padding(.bottom, 36)
                .blendMode(.overlay)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
        .onAppear {
            NSApp.mainWindow?.standardWindowButton(.zoomButton)?.isHidden = true
            NSApp.mainWindow?.standardWindowButton(.closeButton)?.isHidden = true
            NSApp.mainWindow?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            NSApp.mainWindow?.styleMask.remove(.resizable)
        }
        .frame(width: 350, height: 500)
        .introspect(.window, on: .macOS(.v14, .v15)) { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.center()
        }
    }
}
