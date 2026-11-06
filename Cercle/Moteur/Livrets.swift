import Foundation

/// Une ligne de relevé de livret, stockée par le site dans `profils.avoirs` sous la forme [date, montant, solde, libellé].
struct LigneLivret: Codable, Hashable {
    var date: String
    var montant: Double
    var solde: Double?
    var libelle: String

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        date = try c.decode(String.self)
        montant = try c.decode(Double.self)
        solde = try c.decodeIfPresent(Double.self)
        libelle = (try? c.decode(String.self)) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(date); try c.encode(montant); try c.encode(solde); try c.encode(libelle)
    }
}

struct Avoir: Codable, Hashable {
    var lignes: [LigneLivret]
    init(lignes: [LigneLivret]) { self.lignes = lignes }
    /// Une ligne illisible est ignorée au lieu de faire échouer tout le relevé.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lignes = ((try? c.decode([PeutEtre].self, forKey: .lignes)) ?? []).compactMap(\.ligne)
    }
    private struct PeutEtre: Decodable {
        let ligne: LigneLivret?
        init(from decoder: Decoder) throws { ligne = try? LigneLivret(from: decoder) }
    }
}

/// Soldes des livrets, calculés exactement comme le site (`calculer_livrets` dans app.py) :
/// - sur la période des relevés : le dernier solde connu de chaque livret ;
/// - après le dernier relevé : ce solde, plus les versements et moins les retraits saisis sur le compte courant ;
/// - avant le premier relevé : le total reconstitué en remontant les virements.
/// Pourquoi : les livrets avaient de l'argent avant le début de l'historique et rapportent des intérêts,
/// donc la somme des virements seule ne donne pas le vrai solde.
struct Livrets {
    let noms: [String]
    let lignes: [String: [LigneLivret]]
    let debutReleves: String
    let finReleves: String
    let flux: [(jour: String, livret: String, delta: Double)]

    init?(avoirs: [String: Avoir]?, ops: [Operation]) {
        let l = (avoirs ?? [:]).compactMapValues { a -> [LigneLivret]? in
            let s = a.lignes.filter { $0.solde != nil }.sorted { $0.date < $1.date }
            return s.isEmpty ? nil : s
        }
        guard !l.isEmpty else { return nil }
        noms = l.keys.sorted { a, b in a.contains("Bleu") && !b.contains("Bleu") || (a.contains("Bleu") == b.contains("Bleu") && a < b) }
        lignes = l
        debutReleves = l.values.map { $0.first!.date }.min()!
        finReleves = l.values.map { $0.last!.date }.max()!
        let noms = self.noms
        flux = ops.compactMap { o in
            guard let n = Livrets.vise(o.sc, o.note, noms) else { return nil }
            return (o.date, n, o.sc == "Livret" ? o.montant : -o.montant)
        }
    }

    /// Livret concerné par un virement du compte courant (nil si ce n'est pas un livret de la banque).
    static func vise(_ sc: String, _ note: String, _ noms: [String]) -> String? {
        let t = note.lowercased()
        guard !t.contains("boursobank"), sc == "Livret" || sc == "Retrait d'épargne" else { return nil }
        if let n = noms.first(where: { t.contains($0.lowercased()) }) { return n }
        if t.contains("livret") { return noms.first { $0.lowercased().contains("bleu") } ?? noms.first }   // « Depuis mon livret » : le compte tampon
        return nil
    }

    /// Solde d'un livret à la fin d'un jour.
    func solde(_ nom: String, le jour: String) -> Double {
        guard let l = lignes[nom], let premiere = l.first else { return 0 }
        var s = l.last { $0.date <= jour }?.solde ?? ((premiere.solde ?? 0) - premiere.montant)
        if jour > finReleves {
            s += flux.filter { $0.livret == nom && $0.jour > finReleves && $0.jour <= jour }.reduce(0) { $0 + $1.delta }
        }
        return s
    }

    /// Total de tous les livrets à la fin d'un jour.
    func total(le jour: String) -> Double {
        if jour >= debutReleves { return noms.reduce(0) { $0 + solde($1, le: jour) } }
        let depart = noms.reduce(0) { r, n in r + ((lignes[n]!.first!.solde ?? 0) - lignes[n]!.first!.montant) }
        let ensuite = flux.filter { $0.jour > jour && $0.jour < debutReleves }.reduce(0) { $0 + $1.delta }
        return depart - ensuite
    }

    /// Intérêts versés chaque année (lignes « INTERETS » des relevés).
    var interets: [(annee: Int, montant: Double)] {
        var m: [Int: Double] = [:]
        for l in lignes.values.joined() where l.libelle.uppercased().contains("INTERET") { m[Int(l.date.prefix(4)) ?? 0, default: 0] += l.montant }
        return m.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
