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

import SwiftUI
import Lottie
import LottieUI
import Defaults

struct LottieAnimationView: View {
    let state1 = LUStateData(type: .loadedFrom(URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!), speed: 1.0, loopMode: .loop)
    @Default(.selectedVisualizer) var selectedVisualizer
    var body: some View {
        if selectedVisualizer == nil {
            LottieView(state: state1)
        } else {
            LottieView(
                state: LUStateData(
                    type: .loadedFrom(selectedVisualizer!.url),
                    speed: selectedVisualizer!.speed,
                    loopMode: .loop
                )
            )
        }
    }
}

#Preview {
    LottieAnimationView()
}
