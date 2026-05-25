//
//  MMR.swift
//  Folio
//
//  Maximum Marginal Relevance re-ranking. Given a list of candidates already
//  ordered by relevance, pick `k` of them greedily so each new pick balances
//  staying close to the query against being unlike everything picked so far.
//

import Foundation

/// Configuration for MMR re-ranking. `lambda` trades off relevance against
/// diversity (1.0 = pure relevance, 0.0 = pure novelty). `k` is the number of
/// items the caller wants; if `nil`, MMR returns all input items in MMR order.
public struct MMRConfig: Sendable, Hashable {
    public let lambda: Double
    public let k: Int?

    public init(lambda: Double = 0.5, k: Int? = nil) {
        precondition((0.0...1.0).contains(lambda), "lambda must be in [0, 1]")
        if let k { precondition(k > 0, "k must be positive") }
        self.lambda = lambda
        self.k = k
    }
}

enum MMR {
    /// Re-rank `items` greedily by MMR. Candidates without a vector keep their
    /// fusion-score position relative to other vector-less items but lose the
    /// novelty penalty (we can't measure how similar they are to already-picked
    /// items). In practice that's the only sensible degradation since requiring
    /// vectors would silently empty the result list when no embedding provider
    /// is configured.
    static func rerank<T>(
        _ items: [T],
        lambda: Double,
        k: Int,
        relevance: (T) -> Double,
        vector: (T) -> [Float]?
    ) -> [T] {
        guard !items.isEmpty else { return [] }
        let target = min(k, items.count)

        var remaining = Array(items.indices)
        var selected: [Int] = []
        selected.reserveCapacity(target)

        while selected.count < target, !remaining.isEmpty {
            var bestIdx = remaining[0]
            var bestScore = -Double.infinity

            for candidate in remaining {
                let rel = relevance(items[candidate])
                var penalty = 0.0
                if let candidateVec = vector(items[candidate]) {
                    for chosen in selected {
                        if let chosenVec = vector(items[chosen]) {
                            penalty = max(penalty, cosine(candidateVec, chosenVec))
                        }
                    }
                }
                let mmrScore = lambda * rel - (1 - lambda) * penalty
                if mmrScore > bestScore {
                    bestScore = mmrScore
                    bestIdx = candidate
                }
            }

            selected.append(bestIdx)
            remaining.removeAll { $0 == bestIdx }
        }

        return selected.map { items[$0] }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        return (na == 0 || nb == 0) ? 0 : dot / (sqrt(na) * sqrt(nb))
    }
}
