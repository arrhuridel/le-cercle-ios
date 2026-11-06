import Foundation

/// Lecture des relevés CSV et des captures, et catégorisation d'un libellé bancaire :
/// tes règles, puis ton historique, puis les règles génériques reprises de `releve.py`.
enum Import {
    struct Ligne: Identifiable, Hashable {
        var id = UUID()
        var date: String
        var libelle: String
        var montant: Double          // + crédit, − débit
        var sc = "Autre envie"
        var note = ""
        var source = "à vérifier"
        var doublon: String? = nil
        var garder = true
    }

    private static let entrants: [(String, String)] = [
        ("\\bSALAIRE\\b|\\bPAIE\\b|REMUNER", "Salaire"), ("\\bLOYER\\b", "Remboursement loyer"),
        ("VIR CAF\\b|\\bCAF\\b|ALLOCATION|\\bCROUS\\b|\\bBOURSE\\b|FRANCE TRAVAIL", "Bourse & aides"),
        ("WINAMAX|BETCLIC|\\bPMU\\b|\\bFDJ\\b|UNIBET", "Gains de jeux"), ("VERSEMENT ESPECES|DEPOT ESPECES|^VRST", "Dépôt espèces"),
        ("TRADE REPUBLIC|DEPUIS BITSTACK", "Vente placement"), ("LIVRET|DEPUIS BOURSOBANK", "Retrait d'épargne"),
        ("INTERET|DIVIDENDE", "Intérêts & primes"), ("NOEL|ANNIV|CADEAU", "Cadeau reçu"),
        ("REMB|REMBOURSEMENT|CAGNOTTE|^VIR ", "Remboursement"),
    ]
    private static let sortants: [(String, String)] = [
        ("LIVRET|LDDS|\\bPEL\\b|\\bCEL\\b", "Livret"), ("TRADE REPUBLIC|BOURSE DIRECT|DEGIRO|\\bPEA\\b|ASSURANCE VIE", "Investissement"),
        ("COTIS|COMMISSION|AGIOS|FRAIS", "Frais bancaires"), ("\\bLOYER\\b|FONCIA|NEXITY|QUITTANCE", "Loyer"),
        ("ALTERNA|\\bEDF\\b|ENGIE|TOTALENERGIES|EKWATEUR|VEOLIA|SUEZ", "Factures"), ("FREE TELECOM|LIVEBOX|BBOX", "Factures"),
        ("BOUYGUES|ORANGE|\\bSFR\\b|FREE MOBILE|SOSH|\\bRED\\b", "Abonnements"),
        ("MAIF|MACIF|MATMUT|\\bAXA\\b|ALLIANZ|GROUPAMA|MAAF|ASSURANCE", "Assurances"), ("MUTUELLE|PHARMACIE|DOCTOLIB|MEDECIN|HARMONIE", "Santé"),
        ("NETFLIX|SPOTIFY|DEEZER|DISNEY|APPLE\\.COM|ICLOUD|AMAZON PRIME|CANAL|AUDIBLE|OPENAI|ANTHROPIC|GOOGLE ONE|FITNESS|BASIC FIT", "Abonnements"),
        ("NAOLIB|SEMITAN|SNCF|RATP|NAVIGO|BLABLACAR|PEAGE|ESSENCE|TOTAL ACCESS|ESSO", "Transport"),
        ("LIDL|CARREFOUR|AUCHAN|LECLERC|INTERMARCHE|MONOPRIX|SUPER U|BIOCOOP|FRANPRIX|PICARD|BOULANGERIE|IZLY|SUPERMARCHE", "Courses"),
        ("MCDO|MC DONALD|BURGER|KFC|UBER \\* ?EATS|UBER EATS|DELIVEROO|RESTAURANT|PIZZ|SUSHI|\\bBAR\\b|CAFE|BRASSERIE|CREPERIE|KEBAB", "Restos & sorties"),
        ("AMAZON|AMZ|FNAC|ZARA|H&M|DECATHLON|IKEA|KIABI", "Shopping"), ("CINEMA|UGC|PATHE|STEAM|PLAYSTATION|NINTENDO", "Loisirs"),
        ("AIRBNB|BOOKING|HOTEL|RYANAIR|EASYJET|AIR FRANCE", "Voyages"), ("RETRAIT DAB|^RETRAIT", "Espèces"),
        ("BETCLIC|WINAMAX|\\bFDJ\\b|POKER|CASINO", "Jeux d'argent"), ("DGFIP|IMPOT|TRESOR PUBLIC", "Autre besoin"),
    ]
    private static let motsVides: Set<String> = ["NANTES", "REZE", "PARIS", "LYON", "SAINT", "HERBLAIN", "ORLEANS", "CARTE", "PAIEMENT", "SEPA", "PRLV", "INST", "REMBOURSEMENT", "VIREMENT", "FRANCE"]

    static func norm(_ s: String) -> String { s.sansAccents.uppercased() }
    private static func cherche(_ motif: String, _ texte: String) -> Bool { texte.range(of: motif, options: .regularExpression) != nil }

    /// « PAIEMENT CB 0611 LIDL REZE CARTE 1234 » → texte lisible « LIDL REZE » et jour d'achat « 06/11 ».
    static func nettoyer(_ lib: String) -> (texte: String, jour: Int?, mois: Int?) {
        var t = norm(lib).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        var j: Int?, m: Int?
        if let r = t.range(of: "^(?:\\d+ )?PAIEMENTS? (?:CB|PSC) (\\d{2})(\\d{2}) ", options: .regularExpression) {
            let ent = t[r].components(separatedBy: " ").filter { $0.count == 4 && Int($0) != nil }.last ?? ""
            if ent.count == 4 { j = Int(ent.prefix(2)); m = Int(ent.suffix(2)) }
            t = String(t[r.upperBound...])
        }
        for motif in [" CARTE .*$", "^(PRLV SEPA|PRLV|VIR SEPA|VIR INST|VIR|CB)\\s+", "^RETRAIT DAB \\d{4}\\s*", "\\b\\d[\\d/.-]{4,}\\b", "\\bREF\\S*"] {
            t = t.replacingOccurrences(of: motif, with: " ", options: .regularExpression)
        }
        return (t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " "), j, m)
    }
    static func joli(_ t: String) -> String { t.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
    static func cleLibelle(_ lib: String) -> String { nettoyer(lib).texte.split(separator: " ").filter { $0.count >= 3 && $0.rangeOfCharacter(from: .decimalDigits) == nil }.prefix(2).joined(separator: " ") }

    struct Regle: Codable, Hashable, Identifiable { var id = UUID(); var motif: String; var sc: String; var note: String }

    static func proposer(_ libelle: String, _ montant: Double, regles: [Regle], historique: [Operation]) -> (sc: String, note: String, source: String) {
        let L = norm(libelle), credit = montant > 0, texte = nettoyer(libelle).texte
        func bonSens(_ sc: String) -> Bool { (Ref.theme(sc).cat == .revenu) == credit }
        for r in regles where !r.motif.isEmpty && L.contains(norm(r.motif)) && bonSens(r.sc) { return (r.sc, r.note.isEmpty ? joli(texte) : r.note, "ta règle") }
        let mots = Set(texte.split(separator: " ").map(String.init).filter { $0.count >= 4 && !motsVides.contains($0) })
        if !mots.isEmpty, let h = historique.reversed().first(where: { o in
            bonSens(o.sc) && o.cat != .virement && !Set(norm(Analyse.marchand(o)).components(separatedBy: CharacterSet.alphanumerics.inverted)).isDisjoint(with: mots)
        }) { return (h.sc, Analyse.marchand(h), "ton historique") }
        for (motif, sc) in credit ? entrants : sortants where cherche(motif, L) && bonSens(sc) {
            return (sc, sc == "Espèces" ? "Retrait d'espèces" : (texte.isEmpty ? sc : joli(texte)), "règle")
        }
        return (credit ? "Autre revenu" : "Autre envie", texte.isEmpty ? "Opération" : joli(texte), "à vérifier")
    }

    /// Lit un relevé : Crédit Mutuel / CIC (Date;Date de valeur;Débit;Crédit;Libellé;Solde) ou format générique.
    static func lireCSV(_ donnees: Data) throws -> (lignes: [Ligne], format: String) {
        let texte = String(data: donnees, encoding: .utf8) ?? String(data: donnees, encoding: .windowsCP1252) ?? ""
        let lignes = texte.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let premiere = lignes.first else { throw ErreurImport.vide }
        let sep: Character = [";", ",", "\t"].max { a, b in premiere.filter { $0 == a }.count < premiere.filter { $0 == b }.count } ?? ";"
        func couper(_ l: String) -> [String] {
            var r: [String] = [], c = "", q = false
            for ch in l { if ch == "\"" { q.toggle() } else if ch == sep && !q { r.append(c); c = "" } else { c.append(ch) } }
            r.append(c)
            return r.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let rows = lignes.map(couper)
        guard let iTete = rows.firstIndex(where: { $0.contains { $0.sansAccents.contains("date") } }) else { throw ErreurImport.colonnes }
        let tete = rows[iTete].map(\.sansAccents)
        func col(_ ok: (String) -> Bool) -> Int? { tete.firstIndex(where: ok) }
        let cDate = col { $0.hasPrefix("date") && !$0.contains("valeur") } ?? 0
        let cLib = col { c in ["libell", "description", "label", "intitul", "nom", "note", "name"].contains { c.contains($0) } }
        let cDeb = col { $0.hasPrefix("debit") }, cCre = col { $0.hasPrefix("credit") }, cMnt = col { $0.hasPrefix("montant") || $0.contains("amount") || $0 == "valeur" }
        guard let cL = cLib, cMnt != nil || cDeb != nil || cCre != nil else { throw ErreurImport.colonnes }
        func nombre(_ t: String) -> Double {
            var s = t.replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "€", with: "")
            if s.contains(",") && s.contains(".") { s = s.lastIndex(of: ",")! > s.lastIndex(of: ".")! ? s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") : s.replacingOccurrences(of: ",", with: "") }
            else { s = s.replacingOccurrences(of: ",", with: ".") }
            return Double(s) ?? 0
        }
        func dater(_ t: String) -> String? {
            let p = t.split(whereSeparator: { "/.-".contains($0) }).map(String.init)
            guard p.count >= 3 else { return nil }
            if p[0].count == 4, let a = Int(p[0]), let m = Int(p[1]), let j = Int(p[2].prefix(2)) { return J.iso(J.faire(a, m, j)) }
            guard let j = Int(p[0]), let m = Int(p[1]), var a = Int(p[2].prefix(4)) else { return nil }
            if a < 100 { a += 2000 }
            return J.iso(J.faire(a, m, j))
        }
        var out: [Ligne] = []
        for r in rows.dropFirst(iTete + 1) where r.count > max(cDate, cL) {
            guard let d = dater(r[cDate]) else { continue }
            let v: Double = cMnt.map { nombre(r[safe: $0] ?? "") } ?? (nombre(r[safe: cCre ?? -1] ?? "") - abs(nombre(r[safe: cDeb ?? -1] ?? "")))
            if abs(v) < 0.005 { continue }
            out.append(Ligne(date: d, libelle: r[cL], montant: (v * 100).rounded() / 100))
        }
        return (out, tete.joined(separator: ";").contains("date de valeur") ? "Crédit Mutuel / CIC" : "générique")
    }
    enum ErreurImport: LocalizedError { case vide, colonnes
        var errorDescription: String? { self == .vide ? "Fichier vide." : "Colonnes date, libellé ou montant introuvables." }
    }

    /// Du texte lu sur une image : un ticket (ligne TOTAL) ou une capture d'appli bancaire (plusieurs montants).
    static func analyserTexte(_ texte: String) -> [Ligne] {
        let lignes = texte.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let reM = "([-−+])?\\s?(\\d{1,4}(?:[ .]\\d{3})*[,.]\\d{2})\\s?(€|EUR)?"
        func montant(_ l: String) -> Double? {
            guard let r = l.range(of: reM, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let m = String(l[r]), neg = m.hasPrefix("-") || m.hasPrefix("−")
            let chiffres = m.replacingOccurrences(of: "[^0-9,.]", with: "", options: .regularExpression)
            let v = Double(chiffres.replacingOccurrences(of: "(?<=\\d)[ .](?=\\d{3})", with: "", options: .regularExpression).replacingOccurrences(of: ",", with: ".")) ?? 0
            return neg ? -v : v
        }
        var date = J.auj
        if let r = texte.range(of: "\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{2,4}", options: .regularExpression) {
            let p = texte[r].split(whereSeparator: { "/.-".contains($0) }).compactMap { Int($0) }
            if p.count == 3 { let d = J.iso(J.faire(p[2] < 100 ? 2000 + p[2] : p[2], p[1], p[0])); if d <= J.auj { date = d } }
        }
        let marchand = lignes.first { $0.range(of: "[A-Za-z]{3,}", options: .regularExpression) != nil && montant($0) == nil } ?? "Ticket"
        if let total = lignes.first(where: { $0.range(of: "TOTAL|A PAYER|À PAYER|MONTANT|NET A", options: [.regularExpression, .caseInsensitive]) != nil && montant($0) != nil }),
           let m = montant(total) { return [Ligne(date: date, libelle: marchand, montant: -abs(m))] }
        return lignes.filter { montant($0) != nil && $0.range(of: "SOLDE|DISPONIBLE|TOTAL", options: [.regularExpression, .caseInsensitive]) == nil }.compactMap { l in
            guard let m = montant(l) else { return nil }
            let lib = l.replacingOccurrences(of: reM, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
            let signe = l.range(of: "^[^0-9]*[-−+]", options: .regularExpression) != nil
            return Ligne(date: date, libelle: lib.isEmpty ? marchand : lib, montant: signe ? m : -abs(m))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
