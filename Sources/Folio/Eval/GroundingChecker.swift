//
//  GroundingChecker.swift
//  Folio
//
//  Pure functions that score how well a generated answer is grounded in the
//  passages that produced it. Used by `AnswerPolicy` for opt-in refusal and by
//  the eval harness for regression tracking. Both functions return 1.0 when
//  there is nothing to check (no quotes / no numbers) so prose answers without
//  quotes or numbers don't get penalised.
//

import Foundation

/// Fraction of double-quoted spans in `text` that appear verbatim in at least
/// one of `passages`. Returns 1.0 when the answer contains no quoted spans.
///
/// Catches the most common hallucination: the model fabricates a quotation
/// attributed to a source that doesn't actually contain it.
public func quoteGrounding(text: String, passages: [RetrievedResult]) -> Double {
    let quoteRegex = /"([^"]+)"/
    let matches = text.matches(of: quoteRegex)
    guard !matches.isEmpty else { return 1.0 }

    let haystack = passages.map(\.text).joined(separator: "\n")
    var hits = 0
    for match in matches {
        let span = String(match.output.1)
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits += 1
            continue
        }
        if haystack.contains(trimmed) {
            hits += 1
        }
    }
    return Double(hits) / Double(matches.count)
}

/// Fraction of numeric tokens (integers or decimals) in `text` that also
/// appear in at least one of `passages`. Returns 1.0 when the answer contains
/// no numbers. Year-like tokens, currency amounts, and percentages all reduce
/// to a numeric substring check — imperfect but cheap and catches the most
/// common case where a model invents a statistic.
public func numericConsistency(text: String, passages: [RetrievedResult]) -> Double {
    let numberRegex = /\d+(?:[.,]\d+)*/
    let matches = text.matches(of: numberRegex)
    guard !matches.isEmpty else { return 1.0 }

    let haystack = passages.map(\.text).joined(separator: "\n")
    var hits = 0
    for match in matches {
        let token = String(match.output)
        if haystack.contains(token) {
            hits += 1
        }
    }
    return Double(hits) / Double(matches.count)
}
