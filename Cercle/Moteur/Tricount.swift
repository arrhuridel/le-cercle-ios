import Foundation

/// Partage façon Tricount. Chaque groupe a un compte caché « cercle:<id> » : ce qu'on te doit (positif) ou ce que tu dois.
/// Ta part = dépense ; l'argent avancé pour les autres = virement vers ce compte ; un remboursement = virement inverse.
/// Le budget ne voit donc que ta part, et le compte courant bouge du montant réel.
enum Tricount {
    static func compte(_ g: String) -> String { "cercle:\(g)" }

    /// Parts au centime près. Modes : egal, montants (dans la devise de la dépense), pourcent, parts (poids).
    static func parts(_ d: DepensePartagee) -> [String: Double] {
        let ids = d.parts
        guard !ids.isEmpty else { return [:] }
        let cents = Int((d.montant * 100).rounded())
        var poids: [Double]
        switch d.mode {
        case "montants":
            let taux = (d.montantDevise ?? 0) > 0 ? d.montant / d.montantDevise! : 1
            poids = ids.map { max((d.valeurs[$0] ?? 0) * taux, 0) }
        case "pourcent", "parts": poids = ids.map { max(d.valeurs[$0] ?? 0, 0) }
        default: poids = ids.map { _ in 1 }
        }
        if !poids.contains(where: { $0 > 0 }) { poids = ids.map { _ in 1 } }
        let somme = poids.reduce(0, +)
        let bruts = poids.map { Double(cents) * $0 / somme }
        var ent = bruts.map { Int($0.rounded(.down)) }
        var reste = cents - ent.reduce(0, +)
        for i in bruts.indices.sorted(by: { bruts[$0] - Double(ent[$0]) > bruts[$1] - Double(ent[$1]) }) where reste > 0 { ent[i] += 1; reste -= 1 }
        return Dictionary(uniqueKeysWithValues: zip(ids, ent.map { Double($0) / 100 }))
    }

    static func soldes(_ g: GroupeComplet) -> [String: Double] {
        var s = Dictionary(uniqueKeysWithValues: g.participants.map { ($0.id, 0.0) })
        for d in g.depenses {
            s[d.payeur, default: 0] += d.montant
            for (p, m) in parts(d) { s[p, default: 0] -= m }
        }
        for r in g.reglements { s[r.de, default: 0] += r.montant; s[r.a, default: 0] -= r.montant }
        return s.mapValues { ($0 * 100).rounded() / 100 }
    }

    struct Virement: Hashable { var de: String; var a: String; var montant: Double }
    /// « Qui doit quoi à qui » : le plus gros débiteur rembourse le plus gros créancier, et ainsi de suite.
    static func remboursements(_ g: GroupeComplet) -> [Virement] {
        let s = soldes(g)
        var cred = s.filter { $0.value > 0.004 }.map { ($0.key, Int(($0.value * 100).rounded())) }
        var deb = s.filter { $0.value < -0.004 }.map { ($0.key, Int((-$0.value * 100).rounded())) }
        var l: [Virement] = []
        while !cred.isEmpty && !deb.isEmpty {
            cred.sort { $0.1 > $1.1 }; deb.sort { $0.1 > $1.1 }
            let m = min(cred[0].1, deb[0].1)
            l.append(Virement(de: deb[0].0, a: cred[0].0, montant: Double(m) / 100))
            cred[0].1 -= m; deb[0].1 -= m
            if cred[0].1 == 0 { cred.removeFirst() }
            if deb[0].1 == 0 { deb.removeFirst() }
        }
        return l
    }

    /// Le participant qui me représente dans le groupe.
    static func moi(_ g: GroupeComplet, profil: String?) -> String? {
        g.participants.first { $0.profilId != nil && $0.profilId == profil }?.id
    }

    /// Opérations comptables créées par les groupes (calculées, jamais stockées en double).
    static func operations(_ groupes: [GroupeComplet], profil: String?) -> [Operation] {
        var l: [Operation] = []
        for g in groupes {
            guard let moi = moi(g, profil: profil) else { continue }
            let cpt = compte(g.id)
            func op(_ id: String, _ date: String, _ sc: String, _ m: Double, _ note: String, _ c: String, _ v: String?, _ lien: LienPartage) -> Operation {
                Operation(id: id, date: date, profilId: profil ?? "", cat: Ref.theme(sc).cat, sc: sc, montant: m, note: note, compte: c, vers: v, partage: lien)
            }
            for d in g.depenses {
                let mienne = parts(d)[moi] ?? 0, lien = LienPartage(groupe: g.id, depense: d.id)
                if d.payeur == moi {
                    if mienne > 0 { l.append(op("\(d.id):part", d.date, d.sc, mienne, d.titre, "", nil, lien)) }
                    let avance = ((d.montant - mienne) * 100).rounded() / 100
                    if avance > 0 { l.append(op("\(d.id):avance", d.date, "Virement interne", avance, "Avance · \(d.titre)", "", cpt, lien)) }
                } else if mienne > 0 {
                    l.append(op("\(d.id):part", d.date, d.sc, mienne, "\(d.titre) · payé par \(g.nom(d.payeur))", cpt, nil, lien))
                }
            }
            for r in g.reglements {
                let lien = LienPartage(groupe: g.id, reglement: r.id)
                if r.de == moi { l.append(op(r.id, r.date, "Virement interne", r.montant, "Remboursement à \(g.nom(r.a))", "", cpt, lien)) }
                else if r.a == moi { l.append(op(r.id, r.date, "Virement interne", r.montant, "Remboursement de \(g.nom(r.de))", cpt, "", lien)) }
            }
        }
        return l
    }
}
