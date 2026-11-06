import Foundation

/// Formats à la française. Les montants respectent le masquage et le mode confidentiel (réglages de Mon espace).
enum Fmt {
    private static let f2: NumberFormatter = { let f = NumberFormatter(); f.locale = Locale(identifier: "fr_FR"); f.numberStyle = .decimal; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; return f }()
    private static let f0: NumberFormatter = { let f = NumberFormatter(); f.locale = Locale(identifier: "fr_FR"); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f }()

    static var masque: Bool { UserDefaults.standard.bool(forKey: "masque") }
    static var confidentiel: Bool { UserDefaults.standard.bool(forKey: "confidentiel") }

    static func eur(_ v: Double, _ dec: Int = 2, signe: Bool = false) -> String {
        if masque { return "•••• €" }
        var x = abs(v) < 0.005 ? 0 : v
        if confidentiel && abs(x) >= 10 { x = (x / 10).rounded() * 10 }
        let txt = (dec == 0 ? f0 : f2).string(from: NSNumber(value: abs(x))) ?? "0"
        let pre = signe ? (x >= 0 ? "+" : "−") : (x < 0 ? "−" : "")
        return "\(pre)\(txt)\u{00a0}€"
    }
    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))\u{00a0}%" }
    static func nombre(_ v: Double, _ dec: Int = 2) -> String { (dec == 0 ? f0 : f2).string(from: NSNumber(value: v)) ?? "\(v)" }
    /// Lit un montant tapé à la française (« 1 234,50 »).
    static func lire(_ t: String) -> Double {
        let s = t.replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "€", with: "").replacingOccurrences(of: ",", with: ".")
        return ((Double(s) ?? 0) * 100).rounded() / 100
    }
}
