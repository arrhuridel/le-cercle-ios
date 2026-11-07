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
    /// Vrai quand la session a expiré : l'app propose de se reconnecter au lieu d'afficher « pas de réseau ».
    var sessionExpiree = false

    var profil: Profil? { didSet { revision += 1 } }
    var membres: [Membre] = []
    var ops: [Operation] = [] { didSet { revision += 1 } }
    var enveloppes: [Enveloppe] = [] { didSet { revision += 1 } }
    var objectifs: [Objectif] = [] { didSet { revision += 1 } }
    var planifiees: [Planifiee] = []
    var groupes: [GroupeComplet] = [] { didSet { revision += 1 } }
    var mouvements: [MouvementTitre] = []
    var cours: [Cours] = []
    var regles: [Import.Regle] = []
    var ignores: Set<String> = []
    var soldesInitiaux: [String: Double] = [:] { didSet { revision += 1 } }   // seulement en démo

    /// Augmente à chaque changement de données : les calculs mis en cache sont refaits seulement à ce moment-là.
    private(set) var revision = 0
    @ObservationIgnored private var cacheToutes: (Int, [Operation])?
    @ObservationIgnored private var cacheLivrets: (Int, Livrets?)?
    @ObservationIgnored private var cacheTableau: (String, Tableau)?
    @ObservationIgnored private var rafraichissementEnCours = false

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

    // MARK: Calculs partagés (mis en cache : avec ~2 500 opérations, les refaire à chaque toucher ralentit l'app)

    /// Toutes les opérations, y compris celles calculées à partir des groupes.
    var toutes: [Operation] {
        if let c = cacheToutes, c.0 == revision { return c.1 }
        let t = Calc.marquerLoyers(ops + Tricount.operations(groupes, profil: profil?.id))
        cacheToutes = (revision, t)
        return t
    }
    var comptes: [String] { Calc.comptes(ops) }
    /// Livrets d'après les relevés enregistrés par le site (même calcul que le site).
    var livrets: Livrets? {
        if let c = cacheLivrets, c.0 == revision { return c.1 }
        let l = Livrets(avoirs: profil?.avoirs, ops: ops)
        cacheLivrets = (revision, l)
        return l
    }
    var totalLivrets: Double? { livrets?.total(le: J.auj) }
    func nomCompte(_ k: String?) -> String {
        guard let k, !k.isEmpty else { return "Compte courant" }
        if k.hasPrefix("cercle:") { let id = String(k.dropFirst(7)); return "Cercle · " + (groupes.first { $0.id == id }?.groupe.nom ?? "groupe") }
        return k
    }
    func solde(_ compte: String) -> Double { Calc.solde(toutes, compte, jusqua: J.auj, initial: soldesInitiaux[compte] ?? 0) }

    /// Période choisie (Résumé), partagée par tous les écrans : Conseiller, Score, notifications…
    var periodeChoisie: (mode: Calc.Mode, perso: (String, String)) {
        let d = UserDefaults.standard
        let mode = Calc.Mode(rawValue: d.string(forKey: "modePeriode") ?? "") ?? .paie
        return (mode, (d.string(forKey: "persoDebut") ?? J.iso(J.debutDuMois(J.aujourdhui)), d.string(forKey: "persoFin") ?? J.auj))
    }
    /// Le tableau du Résumé, calculé une seule fois par état des données et par période.
    func tableau(mode: Calc.Mode? = nil, perso: (String, String)? = nil) -> Tableau {
        let p = periodeChoisie, m = mode ?? p.mode, pe = perso ?? p.perso
        let cle = "\(revision)|\(m.rawValue)|\(pe.0)|\(pe.1)|\(J.auj)"
        if let c = cacheTableau, c.0 == cle { return c.1 }
        let t = Tableau(ops: toutes, mode: m, perso: pe, budgetMensuel: profil?.budget ?? 0, objectifEpargne: profil?.objectifEpargne ?? 0,
                        enveloppes: enveloppes, objectifs: objectifs, soldeInitial: soldesInitiaux[""] ?? 0, livret: totalLivrets)
        cacheTableau = (cle, t)
        return t
    }

    // MARK: Connexion

    func demarrer() async {
        guard let client else { etat = .deconnecte; return }
        // currentSession se lit sans réseau : on ouvre la copie locale tout de suite, même hors ligne,
        // puis on rafraîchit (le jeton est renouvelé à ce moment-là s'il a expiré).
        if client.auth.currentSession != nil {
            lireCopieLocale()
            etat = .connecte
            await rafraichir()
        } else {
            etat = .deconnecte
        }
    }

    /// Remet l'app à zéro (sortie du mode démo, déconnexion, nouvelle connexion) : rien ne doit passer d'un compte à l'autre.
    private func viderTout() {
        profil = nil; ops = []; groupes = []; enveloppes = []; objectifs = []; planifiees = []; mouvements = []; membres = []; cours = []
        soldesInitiaux = [:]; erreur = nil; horsLigne = false; sessionExpiree = false
    }

    func connecter(email: String, motDePasse: String) async {
        guard let client else { erreur = "L'app n'a pas l'adresse de ta base (secrets GitHub manquants)."; return }
        guard !chargement else { return }
        chargement = true; erreur = nil
        defer { chargement = false }
        do {
            try await client.auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: motDePasse)
            viderTout()
            etat = .connecte
            chargement = false
            await rafraichir()
        } catch {
            erreur = "Connexion impossible : vérifie l'e-mail et le mot de passe."
        }
    }

    func deconnecter() async {
        if etat == .connecte { try? await client?.auth.signOut() }
        try? FileManager.default.removeItem(at: Self.fichierCopie)
        viderTout()
        etat = .deconnecte
    }

    func ouvrirDemo() {
        viderTout()
        let d = Demo.generer()
        profil = d.profil; ops = d.ops; groupes = d.groupes; enveloppes = d.enveloppes; objectifs = d.objectifs
        mouvements = d.mouvements; membres = [Membre(id: d.profil.id, prenom: d.profil.prenom, visibilite: d.profil.visibilite)]
        soldesInitiaux = ["": 1450, "Revolut": 40]
        etat = .demo
    }

    // MARK: Lecture depuis Supabase

    func rafraichir() async {
        guard etat == .connecte, let client else { return }
        // Un seul rafraîchissement à la fois : deux en parallèle pouvaient recréer les saisies automatiques en double
        guard !rafraichissementEnCours else { return }
        rafraichissementEnCours = true; chargement = true; erreur = nil
        defer { rafraichissementEnCours = false; chargement = false }
        do {
            _ = try await client.auth.session   // renouvelle le jeton ; échoue si la session est révoquée ou expirée
        } catch {
            if (error as? URLError) != nil { horsLigne = true; erreur = "Pas de réseau : affichage de la dernière copie enregistrée sur l'iPhone." }
            else { sessionExpiree = true; erreur = "Ta session a expiré : reconnecte-toi." }
            return
        }
        do {
            let profils: [Profil] = try await client.from("profils").select(Profil.colonnes).limit(1).execute().value
            guard let p = profils.first else {
                erreur = "Ton compte n'est relié à aucun profil du site. Lance la ligne SQL du guide pour le relier."
                return
            }
            var toutes: [Operation] = []
            var debut = 0
            while true {   // PostgREST renvoie 1 000 lignes au plus par requête
                // Tri par date PUIS par identifiant : sans ordre unique, une même ligne pourrait tomber sur deux pages
                let page: [Operation] = try await client.from("operations").select(Operation.colonnes).eq("profil_id", value: p.id)
                    .order("date_operation", ascending: false).order("id").range(from: debut, to: debut + 999).execute().value
                toutes += page
                if page.count < 1000 { break }
                debut += 1000
            }
            var vues = Set<String>()
            toutes = toutes.filter { vues.insert($0.id).inserted }   // sécurité : jamais deux fois la même opération
            let env: [Enveloppe] = try await client.from("enveloppes").select().execute().value
            let obj: [Objectif] = try await client.from("objectifs").select().execute().value
            let pla: [Planifiee] = try await client.from("operations_planifiees").select().execute().value
            let mvt: [MouvementTitre] = try await client.from("mouvements_titres").select().execute().value
            let crs: [Cours] = try await client.from("cours").select().order("date_cours", ascending: false).limit(2000).execute().value
            let mbr: [Membre] = (try? await client.rpc("membres").execute().value) ?? []
            let gs: [Groupe] = try await client.from("groupes").select().execute().value
            var grp: [GroupeComplet] = []
            if !gs.isEmpty {
                let ids = gs.map(\.id)
                let parts: [Participant] = try await client.from("participants").select().in("groupe_id", values: ids).execute().value
                let deps: [DepensePartagee] = try await client.from("depenses_partagees").select().in("groupe_id", values: ids).execute().value
                let regs: [Reglement] = try await client.from("reglements").select().in("groupe_id", values: ids).execute().value
                grp = gs.map { g in GroupeComplet(groupe: g, participants: parts.filter { $0.groupeId == g.id },
                                                  depenses: deps.filter { $0.groupeId == g.id }, reglements: regs.filter { $0.groupeId == g.id }) }
            }
            // Tout est lu : on remplace d'un coup (jamais un état à moitié chargé)
            profil = p; ops = toutes; enveloppes = env; objectifs = obj; planifiees = pla; mouvements = mvt; cours = crs; membres = mbr; groupes = grp
            // Corrections déjà apprises sur le site : elles deviennent des règles de l'app
            for (cle, v) in p.reglesImport ?? [:] where v.count == 2 && !regles.contains(where: { $0.motif == cle }) {
                regles.append(Import.Regle(motif: cle, sc: v[0], note: v[1]))
            }
            horsLigne = false; sessionExpiree = false
            ecrireCopieLocale()
            await appliquerPlanifiees()
        } catch {
            if (error as? URLError) != nil { horsLigne = true; erreur = "Pas de réseau : affichage de la dernière copie enregistrée sur l'iPhone." }
            else { erreur = "Lecture de la base impossible : \(error.localizedDescription)" }
        }
    }

    // MARK: Écritures (base + copie locale ; en démo, en mémoire seulement)

    private func envoyer(_ action: @escaping (SupabaseClient) async throws -> Void) async -> Bool {
        guard etat == .connecte else { return true }
        guard let client else { return false }
        do { try await action(client); ecrireCopieLocale(); return true }
        catch {
            erreur = (error as? URLError) != nil ? "Pas de réseau : rien n'a été enregistré." : "Enregistrement impossible : \(error.localizedDescription)"
            return false
        }
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
    /// Ajoute plusieurs opérations ; en cas d'échec, rien ne reste affiché (et l'écran le dit).
    @discardableResult
    func ajouter(_ l: [Operation]) async -> Bool {
        guard !l.isEmpty else { return true }
        ops.insert(contentsOf: l, at: 0)
        if await envoyer({ try await $0.from("operations").insert(l).execute() }) { return true }
        let ids = Set(l.map(\.id))
        ops.removeAll { ids.contains($0.id) }
        return false
    }
    @discardableResult
    func modifier(_ o: Operation) async -> Bool {
        guard let i = ops.firstIndex(where: { $0.id == o.id }) else { return false }
        let avant = ops[i]
        ops[i] = o
        if await envoyer({ try await $0.from("operations").update(o).eq("id", value: o.id).execute() }) { return true }
        // On cherche la ligne à nouveau : la liste a pu être rechargée pendant l'envoi
        if let j = ops.firstIndex(where: { $0.id == o.id }) { ops[j] = avant }
        return false
    }
    @discardableResult
    func supprimer(_ o: Operation) async -> Bool {
        if let lien = o.partage {   // opération calculée : on retire l'élément du groupe
            if let d = lien.depense { return await supprimerDepense(groupe: lien.groupe, id: d) }
            if let r = lien.reglement { return await supprimerReglement(groupe: lien.groupe, id: r) }
            return false
        }
        guard let i = ops.firstIndex(where: { $0.id == o.id }) else { return false }
        let avant = ops.remove(at: i)
        if await envoyer({ try await $0.from("operations").delete().eq("id", value: o.id).execute() }) { return true }
        ops.insert(avant, at: min(i, ops.count))
        return false
    }
    func ignorer(_ id: String) { ignores.insert(id); UserDefaults.standard.set(Array(ignores), forKey: "ignores") }

    func majProfil(budget: Double? = nil, objectifEpargne: Double? = nil, visibilite: String? = nil) async {
        guard let avant = profil else { return }
        var p = avant
        var champs: [String: AnyJSON] = [:]
        if let budget { p.budget = budget; champs["budget_mensuel_max"] = .double(budget) }
        if let objectifEpargne { p.objectifEpargne = objectifEpargne; champs["objectif_epargne"] = .double(objectifEpargne) }
        if let visibilite { p.visibilite = visibilite; champs["visibilite"] = .string(visibilite) }
        profil = p
        if !(await envoyer({ try await $0.from("profils").update(champs).eq("id", value: p.id).execute() })) { profil = avant }
    }

    /// Enregistre un élément simple (remplace ou ajoute), et revient en arrière si la base refuse.
    private func enregistrerElement<T: Identifiable & Encodable>(_ x: T, dans liste: ReferenceWritableKeyPath<Magasin, [T]>, table: String) async -> Bool where T.ID == String {
        let avant = self[keyPath: liste]
        if let i = avant.firstIndex(where: { $0.id == x.id }) { self[keyPath: liste][i] = x } else { self[keyPath: liste].append(x) }
        if await envoyer({ try await $0.from(table).upsert(x).execute() }) { return true }
        self[keyPath: liste] = avant
        return false
    }
    private func supprimerElement<T: Identifiable>(_ id: String, dans liste: ReferenceWritableKeyPath<Magasin, [T]>, table: String) async -> Bool where T.ID == String {
        let avant = self[keyPath: liste]
        self[keyPath: liste].removeAll { $0.id == id }
        if await envoyer({ try await $0.from(table).delete().eq("id", value: id).execute() }) { return true }
        self[keyPath: liste] = avant
        return false
    }
    @discardableResult func enregistrer(_ e: Enveloppe) async -> Bool { await enregistrerElement(e, dans: \.enveloppes, table: "enveloppes") }
    @discardableResult func supprimer(enveloppe e: Enveloppe) async -> Bool { await supprimerElement(e.id, dans: \Magasin.enveloppes, table: "enveloppes") }
    @discardableResult func enregistrer(_ o: Objectif) async -> Bool { await enregistrerElement(o, dans: \.objectifs, table: "objectifs") }
    @discardableResult func supprimer(objectif o: Objectif) async -> Bool { await supprimerElement(o.id, dans: \Magasin.objectifs, table: "objectifs") }
    @discardableResult func enregistrer(_ p: Planifiee) async -> Bool {
        let ok = await enregistrerElement(p, dans: \.planifiees, table: "operations_planifiees")
        if ok { await appliquerPlanifiees() }
        return ok
    }
    @discardableResult func enregistrer(_ m: MouvementTitre) async -> Bool { await enregistrerElement(m, dans: \.mouvements, table: "mouvements_titres") }

    /// Crée les saisies automatiques arrivées à échéance (une par mois et par règle).
    /// Une saisie n'est pas recréée si le mois contient déjà une opération du même thème au montant proche (±20 %),
    /// par exemple la vraie ligne importée du relevé : sinon la facture serait comptée deux fois.
    func appliquerPlanifiees() async {
        var nouvelles: [Operation] = []
        for p in planifiees where p.actif {
            var d = J.date(p.depuis)
            var k = 0
            while J.iso(d) <= J.auj && k < 24 {
                let mois = String(J.iso(d).prefix(7))
                let existe = (ops + nouvelles).contains { $0.sc == p.sc && $0.date.hasPrefix(mois) && abs($0.montant - p.montant) <= max(p.montant * 0.2, 1) }
                if !existe { nouvelles.append(nouvelleOperation(date: J.iso(d), sc: p.sc, montant: p.montant, note: p.note, compte: p.compte, vers: p.vers, source: "auto")) }
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
    @discardableResult
    func ajouter(depense d: DepensePartagee) async -> Bool {
        guard let i = groupes.firstIndex(where: { $0.id == d.groupeId }), !groupes[i].depenses.contains(where: { $0.id == d.id }) else { return false }
        groupes[i].depenses.append(d)
        if await envoyer({ try await $0.from("depenses_partagees").insert(d).execute() }) { return true }
        if let j = groupes.firstIndex(where: { $0.id == d.groupeId }) { groupes[j].depenses.removeAll { $0.id == d.id } }
        return false
    }
    @discardableResult
    func ajouter(reglement r: Reglement) async -> Bool {
        guard let i = groupes.firstIndex(where: { $0.id == r.groupeId }) else { return false }
        groupes[i].reglements.append(r)
        if await envoyer({ try await $0.from("reglements").insert(r).execute() }) { return true }
        if let j = groupes.firstIndex(where: { $0.id == r.groupeId }) { groupes[j].reglements.removeAll { $0.id == r.id } }
        return false
    }
    @discardableResult
    func supprimerDepense(groupe: String, id: String) async -> Bool {
        guard let i = groupes.firstIndex(where: { $0.id == groupe }), let d = groupes[i].depenses.first(where: { $0.id == id }) else { return false }
        groupes[i].depenses.removeAll { $0.id == id }
        if await envoyer({ try await $0.from("depenses_partagees").delete().eq("id", value: id).execute() }) { return true }
        if let j = groupes.firstIndex(where: { $0.id == groupe }) { groupes[j].depenses.append(d) }
        return false
    }
    @discardableResult
    func supprimerReglement(groupe: String, id: String) async -> Bool {
        guard let i = groupes.firstIndex(where: { $0.id == groupe }), let r = groupes[i].reglements.first(where: { $0.id == id }) else { return false }
        groupes[i].reglements.removeAll { $0.id == id }
        if await envoyer({ try await $0.from("reglements").delete().eq("id", value: id).execute() }) { return true }
        if let j = groupes.firstIndex(where: { $0.id == groupe }) { groupes[j].reglements.append(r) }
        return false
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
    /// Tout le contenu, pour la copie locale et la sauvegarde.
    var instantane: Instantane {
        Instantane(profil: profil, membres: membres, ops: ops, enveloppes: enveloppes, objectifs: objectifs, planifiees: planifiees,
                   groupes: groupes.map(\.groupe), participants: groupes.flatMap(\.participants), depenses: groupes.flatMap(\.depenses),
                   reglements: groupes.flatMap(\.reglements), mouvements: mouvements, cours: cours, misAJour: Date())
    }
    private func ecrireCopieLocale() {
        guard etat == .connecte else { return }
        // Protection iOS : le fichier est chiffré et illisible tant que l'iPhone est verrouillé
        try? JSONEncoder().encode(instantane).write(to: Self.fichierCopie, options: [.atomic, .completeFileProtection])
    }
    private func lireCopieLocale() {
        guard let d = try? Data(contentsOf: Self.fichierCopie), let i = try? JSONDecoder().decode(Instantane.self, from: d) else { return }
        profil = i.profil; membres = i.membres; ops = i.ops; enveloppes = i.enveloppes; objectifs = i.objectifs; planifiees = i.planifiees
        mouvements = i.mouvements; cours = i.cours
        groupes = i.groupes.map { g in GroupeComplet(groupe: g, participants: i.participants.filter { $0.groupeId == g.id },
                                                     depenses: i.depenses.filter { $0.groupeId == g.id }, reglements: i.reglements.filter { $0.groupeId == g.id }) }
    }
}
