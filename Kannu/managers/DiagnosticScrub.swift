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

/// Takes the person and the machine out of a diagnostic before a user is offered the chance to send
/// it. Shared by the hang watchdog and the crash reporter so the two cannot drift.
///
/// Both callers also build their output from an allowlist of fields rather than stripping a
/// blocklist out of the whole file: a field nobody thought about is then absent by default instead of
/// being published by default. This type is the second layer, for the text that does get through.
enum DiagnosticScrub {

    /// Home folder to `~`, and any other `/Users/<name>` to `/Users/redacted`.
    ///
    /// Stack frames carry module paths, and in a dev build those sit under the developer's home
    /// folder. Nothing else in a stack is user data: no arguments, no file contents, no chat names,
    /// no session ids.
    static func paths(in text: String, home: String) -> String {
        var out = text
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !trimmedHome.isEmpty, trimmedHome != "/" {
            out = out.replacingOccurrences(of: trimmedHome, with: "~")
        }
        guard let pattern = try? NSRegularExpression(pattern: "/Users/[^/\\s\"]+") else { return out }
        out = pattern.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..., in: out),
            withTemplate: "/Users/redacted"
        )
        // A mounted volume is usually named after its owner too ("Davids-MacBook-Pro", "Work SSD"),
        // and an app run from one symbolises every frame to it.
        // Two passes. A label followed by a path is taken whole, spaces included ("Davids MacBook"
        // used to keep "MacBook"); the line break bounds it so it cannot run into the next frame. A
        // bare volume root at the end of a token is the old pattern.
        for pattern in [#"/Volumes/[^/"\n]+(?=/)"#, #"/Volumes/(?!redacted(?:/|$))[^/\s"]+"#] {
            guard let volumes = try? NSRegularExpression(pattern: pattern) else { continue }
            out = volumes.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "/Volumes/redacted"
            )
        }
        return out
    }

    /// The host part of a diagnostic's own file name, whatever the host is called.
    ///
    /// macOS names resource reports `<App>_<date>-<time>_<host>.<kind>`. `hostName(_:in:)` needs the
    /// name to find it, and a Mac whose local name cannot be read left the file name — shown to the
    /// user and put in the GitHub issue — carrying it. This pass needs nothing: the component
    /// between the timestamp and a known extension is the host. The hyphen shape macOS uses for
    /// crashes (`Kannu-2026-09-12-213652.ips`) has no host and is left as it is.
    static func fileName(_ name: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: #"^([^_/]+_[0-9-]+_)(.+?)(\.cpu_resource\.diag|\.wakeups_resource\.diag|\.ips|\.hang|\.spin)$"#
        ) else { return name }
        return pattern.stringByReplacingMatches(
            in: name,
            range: NSRange(name.startIndex..., in: name),
            withTemplate: "$1this-mac$3"
        )
    }

    /// The computer's name, which macOS puts in every diagnostic *file name*
    /// (`Kannu_2026-09-12-033808_Davids-MacBook-Pro.cpu_resource.diag`) and which is usually the
    /// owner's own name.
    /// Matched on word boundaries. A plain substring replace mangles the fields a maintainer needs:
    /// a Mac named "iMac" turns the model code `iMac21,1` into `this-mac21,1`.
    static func hostName(_ hostName: String, in text: String) -> String {
        let candidates = Set([hostName, hostName.replacingOccurrences(of: ".local", with: "")])
            .filter { $0.count >= 3 }
        var out = text
        for candidate in candidates {
            // Not `\b`: `_` counts as a word character, so `\b` finds no boundary in
            // `Kannu_2026-09-12_Davids-MacBook-Pro.diag` — which is the file name this exists for.
            // Alphanumeric lookaround gets both cases right: it still matches there, and it leaves
            // `iMac21,1` alone for a Mac called "iMac".
            guard let pattern = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: candidate))(?![A-Za-z0-9])"
            ) else { continue }
            out = pattern.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "this-mac"
            )
        }
        return out
    }

    /// Everything, in the order that matters: the host name first, because a home folder often
    /// contains it, then the paths.
    static func everything(in text: String, home: String, hostName: String) -> String {
        Self.hostName(hostName, in: paths(in: text, home: home))
    }
}
