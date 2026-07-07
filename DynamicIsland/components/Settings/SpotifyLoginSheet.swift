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
import os
import SwiftUI
@preconcurrency import WebKit

private enum SpotifyLoginConstants {
    static let loginURL = URL(string: "https://accounts.spotify.com/en/login")!
    static let externalLoginURL = URL(string: "https://open.spotify.com/")!
    static let cookieInstructionsURL = URL(
        string: "https://github.com/Paxsenix0/Spotify-Canvas-API#how-to-get-sp_dc-cookie"
    )!
    static let cookieDomainSuffix = "spotify.com"
    static let cookieName = "sp_dc"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
    static let blockedOAuthHostSuffixes = ["accounts.google.com", "accounts.youtube.com"]
    static let googleSignInRedirectURL = URL(string: "https://accounts.spotify.com/en/login")!
}

private let spotifyLoginLogger = os.Logger(subsystem: "com.kannu.app", category: "SpotifyLogin")

struct SpotifyLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCapture: (String) -> Void

    @State private var statusText: String =
        "Sign in with email & password, Apple, or Facebook. Google blocks in-app sign-in — use “Open in Browser” for Google accounts."
    @State private var didCapture = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Spotify")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(SpotifyLoginConstants.externalLoginURL)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .help("Spotify often blocks in-app logins. Sign in via your normal browser, then paste sp_dc in Settings.")
                Button("Reset Session") {
                    NotificationCenter.default.post(name: .spotifyLoginSheetReset, object: nil)
                    statusText = "Session cleared. Sign in again to capture the cookie."
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            SpotifyLoginWebView { value in
                guard !didCapture else { return }
                didCapture = true
                statusText = "Captured sp_dc cookie. Validating…"
                onCapture(value)
                dismiss()
            } onStatus: { message in
                statusText = message
            }
        }
        .frame(minWidth: 520, minHeight: 640)
    }
}

extension Notification.Name {
    static let spotifyLoginSheetReset = Notification.Name("SpotifyLoginSheetReset")
}

struct SpotifyLoginWebView: NSViewRepresentable {
    let onCapture: (String) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = FirstClickWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = SpotifyLoginConstants.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.attach(webView: webView)
        webView.load(URLRequest(url: SpotifyLoginConstants.loginURL))
        DispatchQueue.main.async { [weak webView] in
            webView?.window?.makeFirstResponder(webView)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private final class FirstClickWebView: WKWebView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        private let onCapture: (String) -> Void
        private let onStatus: (String) -> Void
        private weak var webView: WKWebView?
        private var resetObserver: NSObjectProtocol?

        init(onCapture: @escaping (String) -> Void, onStatus: @escaping (String) -> Void) {
            self.onCapture = onCapture
            self.onStatus = onStatus
            super.init()
            resetObserver = NotificationCenter.default.addObserver(
                forName: .spotifyLoginSheetReset,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.resetSession() }
            }
        }

        deinit {
            if let resetObserver {
                NotificationCenter.default.removeObserver(resetObserver)
            }
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
        }

        func detach() {
            webView?.configuration.websiteDataStore.httpCookieStore.remove(self)
            webView = nil
        }

        private func resetSession() {
            guard let webView else { return }
            let store = webView.configuration.websiteDataStore
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
                Task { @MainActor in
                    self?.webView?.load(URLRequest(url: SpotifyLoginConstants.loginURL))
                }
            }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor in
                    self?.handle(cookies: cookies)
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url, Self.isBlockedOAuthHost(url.host) {
                decisionHandler(.cancel)
                spotifyLoginLogger.debug(
                    "Blocked embedded OAuth navigation to host=\(url.host ?? "", privacy: .public)"
                )
                onStatus(
                    "Google blocks in-app sign-in. Use email & password, Apple, or tap “Open in Browser” to sign in there and paste sp_dc in Settings."
                )
                webView.load(URLRequest(url: SpotifyLoginConstants.googleSignInRedirectURL))
                return
            }
            decisionHandler(.allow)
        }

        private static func isBlockedOAuthHost(_ host: String?) -> Bool {
            guard let host else { return false }
            return SpotifyLoginConstants.blockedOAuthHostSuffixes.contains { host.hasSuffix($0) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let host = webView.url?.host ?? ""
            spotifyLoginLogger.debug("didFinish host=\(host, privacy: .public)")
            if host.contains("accounts.spotify.com") {
                onStatus("Sign in to your Spotify account.")
            } else if host.contains("open.spotify.com") {
                onStatus("Open Spotify shouldn't load here — capture should fire before this. Falling back.")
            } else if host.contains("www.spotify.com") || host.contains("spotify.com") {
                onStatus("Logged in. Finishing capture…")
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                let names = cookies
                    .filter { $0.domain.hasSuffix("spotify.com") }
                    .map { "\($0.name)@\($0.domain)" }
                    .joined(separator: ", ")
                spotifyLoginLogger.debug("cookies after load: \(names, privacy: .public)")
                Task { @MainActor in
                    self?.handle(cookies: cookies)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStatus("Load failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStatus("Load failed: \(error.localizedDescription)")
        }

        // Allow pop-ups (e.g. SSO providers) to load inline in the same webview.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                if Self.isBlockedOAuthHost(url.host) {
                    onStatus(
                        "Google blocks in-app sign-in. Use email & password, Apple, or tap “Open in Browser” to sign in there and paste sp_dc in Settings."
                    )
                    return nil
                }
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: - Capture

        private func handle(cookies: [HTTPCookie]) {
            let match = cookies.first { cookie in
                cookie.name == SpotifyLoginConstants.cookieName
                    && cookie.domain.hasSuffix(SpotifyLoginConstants.cookieDomainSuffix)
            }
            guard let match, !match.value.isEmpty else { return }
            onCapture(match.value)
        }
    }
}
