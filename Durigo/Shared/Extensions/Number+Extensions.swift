//
//  Number+Extensions.swift
//  Durigo
//
//  Created by Joshua Cardozo on 23/11/23.
//

import Foundation

extension Double {
    /// Whole rupees with Indian grouping ("₹1,02,610"), whatever the device's
    /// region: Durigo's prices have no paise. `locale` no longer changes it.
    func asCurrencyString(locale: Locale = .current) -> String? {
        Double(self).rupees
    }
    
    func formatNumberWithFraction() -> String {
        let integerPart = Int(self)
        let fractionalPart = self - Double(integerPart)

        if fractionalPart == 0.5 {
            return integerPart == 0 ? "½" : "\(integerPart) ½"
        } else {
            return "\(integerPart)"
        }
    }
}

extension Float {
    /// Whole rupees with Indian grouping ("₹1,02,610"), whatever the device's
    /// region: Durigo's prices have no paise. `locale` no longer changes it.
    func asCurrencyString(locale: Locale = .current) -> String? {
        Double(self).rupees
    }
}

extension Int {
    /// Whole rupees with Indian grouping ("₹1,02,610"), whatever the device's
    /// region: Durigo's prices have no paise. `locale` no longer changes it.
    func asCurrencyString(locale: Locale = .current) -> String? {
        Double(self).rupees
    }
}

private let rupeeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale(identifier: "en_IN")
    formatter.currencyCode = "INR"
    formatter.currencySymbol = "₹"
    formatter.maximumFractionDigits = 0
    return formatter
}()

extension Double {
    /// "₹1,02,610": whole rupees, Indian grouping, as on the web
    var rupees: String { rupeeFormatter.string(from: NSNumber(value: self.rounded())) ?? "₹\(Int(self.rounded()))" }
}

extension Int {
    /// "₹1,02,610": Indian grouping, as on the web
    var rupees: String { Double(self).rupees }
}
