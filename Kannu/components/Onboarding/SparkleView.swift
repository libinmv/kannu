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
import AppKit

class SparkleNSView: NSView {
    private var emitterLayer: CAEmitterLayer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        setupEmitterLayer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupEmitterLayer() {
        let emitterLayer = CAEmitterLayer()
        emitterLayer.emitterShape = .rectangle
        emitterLayer.emitterMode = .surface
        emitterLayer.renderMode = .oldestFirst
        
        let cell = CAEmitterCell()
        cell.contents = NSImage(named: "sparkle")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cell.birthRate = 50
        cell.lifetime = 5
        cell.velocity = 10
        cell.velocityRange = 5
        cell.emissionRange = .pi * 2
        cell.scale = 0.2
        cell.scaleRange = 0.1
        cell.alphaSpeed = -0.5
        cell.yAcceleration = 10 // Add a slight downward motion
        
        emitterLayer.emitterCells = [cell]
        
        self.layer?.addSublayer(emitterLayer)
        self.emitterLayer = emitterLayer
        
        updateEmitterForCurrentBounds()
    }
    
    private func updateEmitterForCurrentBounds() {
        guard let emitterLayer = self.emitterLayer else { return }
        
        emitterLayer.frame = self.bounds
        emitterLayer.emitterSize = self.bounds.size
        emitterLayer.emitterPosition = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        
        // Adjust birth rate based on view size
        let adjustedBirthRate = 20 // Assuming 200x200 as base size
        emitterLayer.emitterCells?.first?.birthRate = Float(adjustedBirthRate)
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateEmitterForCurrentBounds()
    }
}

struct SparkleView: NSViewRepresentable {
    func makeNSView(context: Context) -> SparkleNSView {
        return SparkleNSView()
    }
    
    func updateNSView(_ nsView: SparkleNSView, context: Context) {}
}
