import Foundation

/// Dates au format de la base (« AAAA-MM-JJ »), toujours à l'heure de Paris.
enum J {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        c.locale = Locale(identifier: "fr_FR")
        return c
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let mois = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
    static let moisCourts = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
    static let jours = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]

    static var aujourdhui: Date { cal.startOfDay(for: Date()) }
    static var auj: String { iso(aujourdhui) }
    static func iso(_ d: Date) -> String { fmt.string(from: d) }
    static func date(_ s: String) -> Date { fmt.date(from: String(s.prefix(10))) ?? aujourdhui }
    static func plus(_ d: Date, jours n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d) ?? d }
    static func plus(_ s: String, jours n: Int) -> String { iso(plus(date(s), jours: n)) }
    static func ecart(_ a: Date, _ b: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0 }
    static func ecart(_ a: String, _ b: String) -> Int { ecart(date(a), date(b)) }
    static func comp(_ d: Date) -> (a: Int, m: Int, j: Int) {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
    /// Date d'un jour du mois, ramené au dernier jour si le mois est plus court (le 31 → le 30 ou le 28).
    static func faire(_ a: Int, _ m: Int, _ j: Int) -> Date {
        let premier = cal.date(from: DateComponents(year: a, month: m, day: 1)) ?? aujourdhui
        let n = cal.range(of: .day, in: .month, for: premier)?.count ?? 28
        return cal.date(from: DateComponents(year: a, month: m, day: min(j, n))) ?? premier
    }
    static func moisSuivant(_ d: Date, _ k: Int = 1) -> Date {
        let c = comp(d)
        return faire(c.a, c.m + k, c.j)   // DateComponents accepte un mois > 12
    }
    static func finDuMois(_ d: Date) -> Date {
        let c = comp(d)
        return plus(faire(c.a, c.m + 1, 1), jours: -1)
    }
    static func debutDuMois(_ d: Date) -> Date { let c = comp(d); return faire(c.a, c.m, 1) }
    static func jourSemaine(_ s: String) -> Int { (cal.component(.weekday, from: date(s)) + 5) % 7 }   // 0 = lundi
    static func court(_ s: String) -> String { let c = comp(date(s)); return "\(c.j) \(moisCourts[c.m - 1])" }
    static func libelleJour(_ s: String) -> String {
        let e = ecart(date(s), aujourdhui)
        if e == 0 { return "Aujourd'hui" }
        if e == 1 { return "Hier" }
        let d = date(s), c = comp(d), wd = cal.component(.weekday, from: d) - 1
        let annee = c.a != comp(aujourdhui).a ? " \(c.a)" : ""
        return "\(jours[wd]) \(c.j) \(mois[c.m - 1])\(annee)".capitalizedPremiere
    }
}

extension String {
    var capitalizedPremiere: String { prefix(1).uppercased() + dropFirst() }
    var sansAccents: String { folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased() }
}
