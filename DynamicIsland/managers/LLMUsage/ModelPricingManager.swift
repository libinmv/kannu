/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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

/// Model for dynamic pricing data structure
struct ModelPricingData: Codable {
    let models: [ModelPriceEntry]
    let lastUpdated: String?
    
    enum CodingKeys: String, CodingKey {
        case models
        case lastUpdated = "last_updated"
    }
}

struct ModelPriceEntry: Codable, Identifiable {
    let id: String
    let name: String
    let pricing: ModelRates
}

struct ModelRates: Codable {
    let prompt: String
    let completion: String
    
    var promptPrice: Double {
        Double(prompt) ?? 0.0
    }
    
    var completionPrice: Double {
        Double(completion) ?? 0.0
    }
}

/// Manager class to handle fetching and caching of LLM pricing data
class ModelPricingManager: ObservableObject {
    static let shared = ModelPricingManager()
    
    @Published private(set) var pricingData: ModelPricingData?
    
    private let remoteURL = URL(string: "https://raw.githubusercontent.com/Ebullioscopic/Atoll/feat/dynamic-pricing-workflow/DynamicIsland/managers/LLMUsage/pricing.json")!
    
    private init() {
        loadInitialPricing()
        Task {
            await fetchRemotePricing()
        }
    }
    
    /// Loads initial pricing from local bundle fallback
    private func loadInitialPricing() {
        if let localURL = Bundle.main.url(forResource: "pricing", withExtension: "json", subdirectory: "DynamicIsland/managers/LLMUsage") {
            do {
                let data = try Data(contentsOf: localURL)
                self.pricingData = try JSONDecoder().decode(ModelPricingData.self, from: data)
                print("✅ ModelPricingManager: Loaded bundled pricing fallback")
            } catch {
                print("❌ ModelPricingManager: Failed to load bundled pricing: \(error)")
            }
        } else {
            // Check flat manager path if subdirectory lookup fails
            if let localURL = Bundle.main.url(forResource: "pricing", withExtension: "json") {
                do {
                    let data = try Data(contentsOf: localURL)
                    self.pricingData = try JSONDecoder().decode(ModelPricingData.self, from: data)
                    print("✅ ModelPricingManager: Loaded bundled pricing from flat path")
                } catch {
                    print("❌ ModelPricingManager: Failed to load bundled pricing (flat): \(error)")
                }
            }
        }
    }
    
    /// Asynchronously fetches dynamic pricing from GitHub
    func fetchRemotePricing() async {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        let session = URLSession(configuration: configuration)
        
        do {
            let (data, response) = try await session.data(from: remoteURL)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("⚠️ ModelPricingManager: Remote fetch returned non-200 status")
                return
            }
            
            let decoded = try JSONDecoder().decode(ModelPricingData.self, from: data)
            
            await MainActor.run {
                self.pricingData = decoded
                print("✅ ModelPricingManager: Successfully updated pricing from remote")
            }
        } catch {
            print("⚠️ ModelPricingManager: Failed to fetch remote pricing (using local/cached): \(error)")
        }
    }
    
    /// Resolves pricing for a specific model ID
    func getPricing(for modelId: String) -> (prompt: Double, completion: Double)? {
        guard let model = pricingData?.models.first(where: { $0.id == modelId }) else {
            return nil
        }
        return (model.pricing.promptPrice, model.pricing.completionPrice)
    }
}
