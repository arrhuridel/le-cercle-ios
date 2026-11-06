import Foundation
import Observation
import Supabase

/// Le magasin de données de l'app : connexion à Supabase (la même base que le site), copie locale pour le
/// hors-ligne, et mode démo (données inventées). Toutes les vues lisent et modifient les données par lui.
@MainActor @Observable
final class Magasin {
    enum Etat: Equatable { case demarrage, deconnecte, demo, connecte }

    var etat: Etat = .demarrage
    var chargement = false
    var erreur: String?
    var horsLigne = false

    var profil: Profil?
    var membres: [Membre] = []
    var ops: [Operation] = []
    var enveloppes: [Enveloppe] = []
    var objectifs: [Objectif] = []
    var planifiees: [Planifiee] = []
    var groupes: [GroupeComplet] = []
    var mouvements: [MouvementTitre] = []
    var cours: [Cours] = []
    var regles: [Import.Regle] = []
    var ignores: Set<String> = []
    var soldesInitiaux: [String: Double] = [:]   // seulement en démo : sur la vraie base, l'historique complet donne le solde

    private var client: SupabaseClient?
    let configure: Bool

    init() {
        let url = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String ?? ""
        let cle = Bundle.main.object(forInfoDictionaryKey: "SupabaseKey") as? String ?? ""
        if let u = URL(string: url), u.scheme == "https", !cle.isEmpty {
            client = SupabaseClient(supabaseURL: u, supabaseKey: cle)
            configure = true
        } else {
            configure = false
        }
        if let d = UserDefaults.standard.data(forKey: "regles"), let r = try? JSONDecoder().decode([Import.Regle].self, from: d) { regles = r }
        ignores = Set(UserDefaults.standard.stringArray(forKey: "ignores") ?? [])
    }

    // MARK: Calculs partagés

    /// Toutes les opérations, y compris celles calculées à partir des groupes.
    var toutes: [Operation] { ops + Tricount.operations(groupes, profil: profil?.id) }
    var comptes: [String] { Calc.comptes(ops) }
    func nomCompte(_ k: String?) -> String {
        guard let k, !k.isEmpty else { return "Compte courant" }
        if k.hasPrefix("cercle:") { let id = String(k.dropFirst(7)); return "Cercle · " + (groupes.first { $0.id == id }?.groupe.nom ?? "groupe") }
        return k
    }
    func solde(_ compte: String) -> Double { Calc.solde(toutes, compte, jusqua: J.auj, initial: soldesInitiaux[compte] ?? 0) }

    // MARK: Connexion

    func demarrer() async {
        guard let client else { etat = .deconnecte; return }
        if (try? await client.auth.session) != nil {
            lireCopieLocale()
            etat = .connecte
            await rafraichir()
        } else {
            etat = .deconnecte
        }
    }

    func connecter(email: String, motDePasse: String) async {
        guard let client else { erreur = "L'app n'a pas l'adresse de ta base (secrets GitHub manquants)."; return }
        chargement = true; erreur = nil
        defer { chargement = false }
        do {
            try await client.auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: motDePasse)
            etat = .connecte
            await rafraichir()
        } catch {
            erreur = "Connexion impossible : vérifie l'e-mail et le mot de passe."
        }
    }

    func deconnecter() async {
        if etat == .connecte { try? await client?.auth.signOut() }
        try? FileManager.default.removeItem(at: Self.fichierCopie)
        profil = nil; ops = []; groupes = []; enveloppes = []; objectifs = []; planifiees = []; mouvements = []; membres = []
        etat = .deconnecte
    }

    func ouvrirDemo() {
        let d = Demo.generer()
        profil = d.profil; ops = d.ops; groupes = d.groupes; enveloppes = d.enveloppes; objectifs = d.objectifs
        mouvements = d.mouvements; membres = [Membre(id: d.profil.id, prenom: d.profil.prenom, visibilite: d.profil.visibilite)]
        soldesInitiaux = ["": 1450, "Revolut": 40]
        etat = .demo
    }

    // MARK: Lecture depuis Supabase

    func rafraichir() async {
        guard etat == .connecte, let client else { return }
        chargement = true; erreur = nil
        defer { chargement = false }
        do {
            let profils: [Profil] = try await client.from("profils").select(Profil.colonnes).limit(1).execute().value
            guard let p = profils.first else {
                erreur = "Ton compte n'est relié à aucun profil du site. Lance la ligne SQL du guide pour le relier."
                return
            }
            profil = p
            var toutes: [Operation] = []
            var debut = 0
            while true {   // PostgREST renvoie 1 000 lignes au plus par requête
                let page: [Operation] = try await client.from("operations").select(Operation.colonnes).eq("profil_id", value: p.id)
                    .order("date_operation", ascending: false).range(from: debut, to: debut + 999).execute().value
                toutes += page
                if page.count < 1000 { break }
                debut += 1000
            }
            ops = toutes
            enveloppes = try await client.from("enveloppes").select().execute().value
            objectifs = try await client.from("objectifs").select().execute().value
            planifiees = try await client.from("operations_planifiees").select().execute().value
            mouvements = try await client.from("mouvements_titres").select().execute().value
            cours = try await client.from("cours").select().order("date_cours", ascending: false).limit(2000).execute().value
            membres = (try? await client.rpc("membres").execute().value) ?? []
            let gs: [Groupe] = try await client.from("groupes").select().execute().value
            if gs.isEmpty { groupes = [] } else {
                let ids = gs.map(\.id)
                let parts: [Participant] = try await client.from("participants").select().in("groupe_id", values: ids).execute().value
                let deps: [DepensePartagee] = try await client.from("depenses_partagees").select().in("groupe_id", values: ids).execute().value
                let regs: [Reglement] = try await client.from("reglements").select().in("groupe_id", values: ids).execute().value
                groupes = gs.map { g in GroupeComplet(groupe: g, participants: parts.filter { $0.groupeId == g.id },
                                                      depenses: deps.filter { $0.groupeId == g.id }, reglements: regs.filter { $0.groupeId == g.id }) }
            }
            // Corrections déjà apprises sur le site : elles deviennent des règles de l'app
            for (cle, v) in p.reglesImport ?? [:] where v.count == 2 && !regles.contains(where: { $0.motif == cle }) {
                regles.append(Import.Regle(motif: cle, sc: v[0], note: v[1]))
            }
            horsLigne = false
            ecrireCopieLocale()
            await appliquerPlanifiees()
        } catch {
            horsLigne = true
            erreur = "Pas de connexion à la base : affichage de la dernière copie enregistrée sur l'iPhone."
        }
    }

    // MARK: Écritures (base + copie locale ; en démo, en mémoire seulement)

    private func envoyer(_ action: @escaping (SupabaseClient) async throws -> Void) async -> Bool {
        guard etat == .connecte else { return true }
        guard let client else { return false }
        do { try await action(client); ecrireCopieLocale(); return true }
        catch { erreur = "Enregistrement impossible : \(error.localizedDescription)"; return false }
    }

    func nouvelleOperation(date: String, sc: String, montant: Double, note: String, compte: String, vers: String?,
                           source: String = "saisie", devise: String? = nil, montantDevise: Double? = nil) -> Operation {
        Operation(id: UUID().uuidString.lowercased(), date: date, profilId: profil?.id ?? "", cat: Ref.theme(sc).cat, sc: sc,
                  montant: montant, note: note, compte: compte, vers: vers, source: source, statut: "validee", devise: devise, montantDevise: montantDevise)
    }

    @discardableResult
    func ajouter(_ o: Operation) async -> Bool {
        ops.insert(o, at: 0)
        if await envoyer({ try await $0.from("operations").insert(o).execute() }) { return true }
        ops.removeAll { $0.id == o.id }
        return false
    }
    func ajouter(_ l: [Operation]) async {
        ops.insert(contentsOf: l, at: 0)
        _ = await envoyer({ try await $0.from("operations").insert(l).execute() })
    }
    func modifier(_ o: Operation) async {
        guard let i = ops.firstIndex(where: { $0.id == o.id }) else { return }
        let avant = ops[i]
        ops[i] = o
        if !(await envoyer({ try await $0.from("operations").update(o).eq("id", value: o.id).execute() })) { ops[i] = avant }
    }
    func supprimer(_ o: Operation) async {
        if let lien = o.partage {   // opération calculée : on retire l'élément du groupe
            if let d = lien.depense { await supprimerDepense(groupe: lien.groupe, id: d) }
            if let r = lien.reglement { await supprimerReglement(groupe: lien.groupe, id: r) }
            return
        }
        ops.removeAll { $0.id == o.id }
        _ = await envoyer({ try await $0.from("operations").delete().eq("id", value: o.id).execute() })
    }
    func ignorer(_ id: String) { ignores.insert(id); UserDefaults.standard.set(Array(ignores), forKey: "ignores") }

    func majProfil(budget: Double? = nil, objectifEpargne: Double? = nil, visibilite: String? = nil) async {
        guard var p = profil else { return }
        var champs: [String: AnyJSON] = [:]
        if let budget { p.budget = budget; champs["budget_mensuel_max"] = .double(budget) }
        if let objectifEpargne { p.objectifEpargne = objectifEpargne; champs["objectif_epargne"] = .double(objectifEpargne) }
        if let visibilite { p.visibilite = visibilite; champs["visibilite"] = .string(visibilite) }
        profil = p
        _ = await envoyer({ try await $0.from("profils").update(champs).eq("id", value: p.id).execute() })
    }

    func enregistrer(_ e: Enveloppe) async {
        if let i = enveloppes.firstIndex(where: { $0.id == e.id }) { enveloppes[i] = e } else { enveloppes.append(e) }
        _ = await envoyer({ try await $0.from("enveloppes").upsert(e).execute() })
    }
    func supprimer(enveloppe e: Enveloppe) async {
        enveloppes.removeAll { $0.id == e.id }
        _ = await envoyer({ try await $0.from("enveloppes").delete().eq("id", value: e.id).execute() })
    }
    func enregistrer(_ o: Objectif) async {
        if let i = objectifs.firstIndex(where: { $0.id == o.id }) { objectifs[i] = o } else { objectifs.append(o) }
        _ = await envoyer({ try await $0.from("objectifs").upsert(o).execute() })
    }
    func supprimer(objectif o: Objectif) async {
        objectifs.removeAll { $0.id == o.id }
        _ = await envoyer({ try await $0.from("objectifs").delete().eq("id", value: o.id).execute() })
    }
    func enregistrer(_ p: Planifiee) async {
        if let i = planifiees.firstIndex(where: { $0.id == p.id }) { planifiees[i] = p } else { planifiees.append(p) }
        _ = await envoyer({ try await $0.from("operations_planifiees").upsert(p).execute() })
        await appliquerPlanifiees()
    }
    func enregistrer(_ m: MouvementTitre) async {
        mouvements.append(m)
        _ = await envoyer({ try await $0.from("mouvements_titres").insert(m).execute() })
    }

    /// Crée les saisies automatiques arrivées à échéance (une par mois et par règle).
    func appliquerPlanifiees() async {
        var nouvelles: [Operation] = []
        for p in planifiees where p.actif {
            var d = J.date(p.depuis)
            var k = 0
            while J.iso(d) <= J.auj && k < 24 {
                let mois = String(J.iso(d).prefix(7)), note = p.note
                let existe = ops.contains { $0.sc == p.sc && $0.montant == p.montant && $0.note == note && $0.date.hasPrefix(mois) }
                if !existe { nouvelles.append(nouvelleOperation(date: J.iso(d), sc: p.sc, montant: p.montant, note: note, compte: p.compte, vers: p.vers, source: "auto")) }
                k += 1
                let c = J.comp(d)
                d = J.faire(c.a, c.m + 1, p.jour)
            }
        }
        if !nouvelles.isEmpty { await ajouter(nouvelles) }
    }

    // MARK: Groupes

    func creerGroupe(nom: String, amis: [String]) async -> String? {
        guard let p = profil else { return nil }
        let g = Groupe(id: UUID().uuidString.lowercased(), nom: nom, creePar: p.id)
        let moi = Participant(id: UUID().uuidString.lowercased(), groupeId: g.id, nom: p.prenom, profilId: p.id)
        let autres = amis.map { ami in
            Participant(id: UUID().uuidString.lowercased(), groupeId: g.id, nom: ami, profilId: membres.first { m in m.prenom == ami && m.id != p.id }?.id)
        }
        groupes.append(GroupeComplet(groupe: g, participants: [moi] + autres, depenses: [], reglements: []))
        let ok = await envoyer({ c in
            try await c.from("groupes").insert(g).execute()
            try await c.from("participants").insert([moi] + autres).execute()
        })
        if !ok { groupes.removeAll { $0.id == g.id }; return nil }
        return g.id
    }
    func ajouter(depense d: DepensePartagee) async {
        guard let i = groupes.firstIndex(where: { $0.id == d.groupeId }) else { return }
        groupes[i].depenses.append(d)
        _ = await envoyer({ try await $0.from("depenses_partagees").insert(d).execute() })
    }
    func ajouter(reglement r: Reglement) async {
        guard let i = groupes.firstIndex(where: { $0.id == r.groupeId }) else { return }
        groupes[i].reglements.append(r)
        _ = await envoyer({ try await $0.from("reglements").insert(r).execute() })
    }
    func supprimerDepense(groupe: String, id: String) async {
        guard let i = groupes.firstIndex(where: { $0.id == groupe }) else { return }
        groupes[i].depenses.removeAll { $0.id == id }
        _ = await envoyer({ try await $0.from("depenses_partagees").delete().eq("id", value: id).execute() })
    }
    func supprimerReglement(groupe: String, id: String) async {
        guard let i = groupes.firstIndex(where: { $0.id == groupe }) else { return }
        groupes[i].reglements.removeAll { $0.id == id }
        _ = await envoyer({ try await $0.from("reglements").delete().eq("id", value: id).execute() })
    }

    // MARK: Règles de catégorisation

    func ajouterRegle(_ r: Import.Regle) {
        regles.removeAll { $0.motif == r.motif }
        regles.append(r)
        if let d = try? JSONEncoder().encode(regles) { UserDefaults.standard.set(d, forKey: "regles") }
    }
    func supprimerRegle(_ r: Import.Regle) {
        regles.removeAll { $0.id == r.id }
        if let d = try? JSONEncoder().encode(regles) { UserDefaults.standard.set(d, forKey: "regles") }
    }

    // MARK: Copie locale

    private static var fichierCopie: URL {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier.appendingPathComponent("copie.json")
    }
    private func ecrireCopieLocale() {
        guard etat == .connecte else { return }
        let i = Instantane(profil: profil, membres: membres, ops: ops, enveloppes: enveloppes, objectifs: objectifs, planifiees: planifiees,
                           groupes: groupes.map(\.groupe), participants: groupes.flatMap(\.participants), depenses: groupes.flatMap(\.depenses),
                           reglements: groupes.flatMap(\.reglements), mouvements: mouvements, cours: cours, misAJour: Date())
        // Protection iOS : le fichier est chiffré et illisible tant que l'iPhone est verrouillé
        try? JSONEncoder().encode(i).write(to: Self.fichierCopie, options: [.atomic, .completeFileProtection])
    }
    private func lireCopieLocale() {
        guard let d = try? Data(contentsOf: Self.fichierCopie), let i = try? JSONDecoder().decode(Instantane.self, from: d) else { return }
        profil = i.profil; membres = i.membres; ops = i.ops; enveloppes = i.enveloppes; objectifs = i.objectifs; planifiees = i.planifiees
        mouvements = i.mouvements; cours = i.cours
        groupes = i.groupes.map { g in GroupeComplet(groupe: g, participants: i.participants.filter { $0.groupeId == g.id },
                                                     depenses: i.depenses.filter { $0.groupeId == g.id }, reglements: i.reglements.filter { $0.groupeId == g.id }) }
    }

    /// Sauvegarde complète en JSON (bouton de Mon espace).
    func exportJSON() -> Data {
        let i = Instantane(profil: profil, membres: membres, ops: ops, enveloppes: enveloppes, objectifs: objectifs, planifiees: planifiees,
                           groupes: groupes.map(\.groupe), participants: groupes.flatMap(\.participants), depenses: groupes.flatMap(\.depenses),
                           reglements: groupes.flatMap(\.reglements), mouvements: mouvements, cours: cours, misAJour: Date())
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(i)) ?? Data()
    }
}
