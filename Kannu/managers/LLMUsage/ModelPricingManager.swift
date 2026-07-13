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

    var isUnpriced: Bool {
        promptPrice <= 0 && completionPrice <= 0
    }
}

/// Manager class to handle fetching and caching of LLM pricing data
class ModelPricingManager: ObservableObject {
    static let shared = ModelPricingManager()
    
    @Published private(set) var pricingData: ModelPricingData?
    
    private let remoteURL = URL(string: "https://raw.githubusercontent.com/libinmv/kannu/main/Kannu/managers/LLMUsage/pricing.json")!
    
    private init() {
        loadInitialPricing()
        Task {
            await fetchRemotePricing()
        }
    }
    
    /// Loads initial pricing from local bundle fallback
    private func loadInitialPricing() {
        if let localURL = Bundle.main.url(forResource: "pricing", withExtension: "json", subdirectory: "Kannu/managers/LLMUsage") {
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
                if self.shouldAcceptRemotePricing(local: self.pricingData, remote: decoded) {
                    self.pricingData = decoded
                    print("✅ ModelPricingManager: Successfully updated pricing from remote")
                } else {
                    let localCount = self.pricedModelCount(in: self.pricingData)
                    let remoteCount = self.pricedModelCount(in: decoded)
                    print("⚠️ ModelPricingManager: Ignoring remote pricing (remote priced models: \(remoteCount), local priced models: \(localCount))")
                }
            }
        } catch {
            print("⚠️ ModelPricingManager: Failed to fetch remote pricing (using local/cached): \(error)")
        }
    }
    
    /// Resolves pricing for a specific model ID
    func getPricing(for modelId: String) -> (prompt: Double, completion: Double)? {
        guard let model = pricingEntry(for: modelId), !model.pricing.isUnpriced else {
            return nil
        }
        return (model.pricing.promptPrice, model.pricing.completionPrice)
    }

    private func pricingEntry(for modelId: String) -> ModelPriceEntry? {
        guard let models = pricingData?.models else { return nil }
        if let direct = models.first(where: { $0.id.caseInsensitiveCompare(modelId) == .orderedSame }) {
            return direct
        }

        let normalized = normalizedModelID(modelId)
        return models.first(where: { $0.id.caseInsensitiveCompare(normalized) == .orderedSame })
    }

    private func normalizedModelID(_ rawModelId: String) -> String {
        let raw = rawModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        let aliases: [(String, String)] = [
            ("anthropic/claude-sonnet-4", "anthropic/claude-sonnet-4"),
            ("claude-sonnet-4", "anthropic/claude-sonnet-4"),
            ("anthropic/claude-opus-4", "anthropic/claude-opus-4"),
            ("claude-opus-4", "anthropic/claude-opus-4"),
            ("anthropic/claude-3-haiku", "anthropic/claude-3-haiku"),
            ("claude-3-haiku", "anthropic/claude-3-haiku"),
            ("openai/gpt-4o-mini", "openai/gpt-4o-mini"),
            ("gpt-4o-mini", "openai/gpt-4o-mini"),
            ("openai/gpt-4o", "openai/gpt-4o"),
            ("gpt-4o", "openai/gpt-4o"),
            ("openai/gpt-4.1-mini", "openai/gpt-4.1-mini"),
            ("gpt-4.1-mini", "openai/gpt-4.1-mini"),
            ("openai/gpt-4.1", "openai/gpt-4.1"),
            ("gpt-4.1", "openai/gpt-4.1"),
            ("openai/gpt-5-mini", "openai/gpt-5-mini"),
            ("gpt-5-mini", "openai/gpt-5-mini"),
            ("openai/gpt-5-nano", "openai/gpt-5-nano"),
            ("gpt-5-nano", "openai/gpt-5-nano"),
            ("openai/gpt-5", "openai/gpt-5"),
            ("gpt-5", "openai/gpt-5"),
            ("openai/o4-mini", "openai/o4-mini"),
            ("o4-mini", "openai/o4-mini"),
            ("openai/o3", "openai/o3"),
            ("o3", "openai/o3")
        ]
        if let mapped = aliases.first(where: { lower.hasPrefix($0.0) })?.1 {
            return mapped
        }

        if lower.hasPrefix("composer-") || lower.hasPrefix("cursor-") {
            return "cursor/composer-default"
        }
        return raw
    }

    private func pricedModelCount(in data: ModelPricingData?) -> Int {
        data?.models.filter { !$0.pricing.isUnpriced }.count ?? 0
    }

    private func shouldAcceptRemotePricing(local: ModelPricingData?, remote: ModelPricingData) -> Bool {
        guard local != nil else { return true }
        return pricedModelCount(in: remote) >= pricedModelCount(in: local)
    }
}
