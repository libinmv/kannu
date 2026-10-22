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

/// The prompt Settings › Notch skin copies for an image AI: it asks the user about the skin they
/// want, then draws one that fits the notch. The numbers follow how a skin is drawn: scaled to
/// fill the open notch (640 × 200 pt by default, so 1920 × 600 px is 3×) and, closed, a thin strip
/// through the middle. `docs/notch-skins.md` quotes it verbatim; `NotchSkinTests` keeps them equal.
enum NotchSkinPrompt {
    static let text = """
        You are a designer making a background image ("skin") for Kannu, a macOS app that lives in the \
        MacBook notch. The image fills the panel that drops down from the top centre of the screen.

        First, ask me these questions one at a time, and wait for each answer. Do not generate anything \
        until I have answered all of them.
        1. What mood or theme do you want? (For example: calm, cosy, sci-fi, retro arcade, nature, devilish.)
        2. Which two or three colours should lead?
        3. Any motifs, textures or patterns? (For example: circuit lines, marble, waves, embers.)
        4. How bold should it be: subtle, balanced or loud?
        5. Anything to avoid?

        Then sum up my answers in one short paragraph and generate one image that follows these rules:
        - 1920 × 600 pixels, landscape, PNG.
        - Keep the centre (about the middle 60% of the width) dark and low in detail. Kannu draws \
        text, icons, album art and a small coloured status light there, and they must stay readable.
        - Put the decoration toward the left and right edges, balanced on both sides.
        - Keep the top centre close to black, so it blends into the camera notch.
        - Keep important detail at least 40 pixels from every edge: the corners are rounded and clipped.
        - No text, letters, logos, watermarks, interface elements, people or faces.
        - It must still look right as a thin horizontal strip through the middle, which is all the \
        closed notch shows.

        If I ask for changes, keep the same size and rules.
        """
}
