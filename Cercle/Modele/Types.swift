import Foundation

/// Une opération, telle que stockée dans la table `operations` de Supabase.
/// Les dates sont gardées en texte « AAAA-MM-JJ » : c'est le format de la base, et il se compare tel quel.
struct Operation: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var profilId: String
    var cat: Cat
    var sc: String
    var montant: Double
    var note: String
    var compte: String
    var vers: String?
    var source: String?
    var statut: String?
    var devise: String?
    var montantDevise: Double?
    var creeLe: String?
    /// Lien vers un groupe : seulement pour les opérations calculées à partir du Tricount (jamais stockées).
    var partage: LienPartage? = nil

    enum CodingKeys: String, CodingKey {
        case id, montant, compte, source, statut, devise
        case date = "date_operation", profilId = "profil_id", cat = "categorie", sc = "sous_categorie"
        case note = "description", vers = "vers_compte", montantDevise = "montant_devise", creeLe = "created_at"
    }
    static let colonnes = "id,date_operation,profil_id,categorie,sous_categorie,montant,description,compte,vers_compte,source,statut,devise,montant_devise,created_at"
}

struct LienPartage: Hashable {
    var groupe: String
    var depense: String?
    var reglement: String?
}

/// Le profil de la personne connectée (jamais le code PIN : la base ne le donne pas à l'app).
struct Profil: Codable, Hashable {
    var id: String
    var prenom: String
    var visibilite: String
    var budget: Double
    var objectifEpargne: Double
    /// Corrections retenues lors des imports sur le site : libellé nettoyé → [thème, note]
    var reglesImport: [String: [String]]?
    enum CodingKeys: String, CodingKey {
        case id, prenom, visibilite
        case budget = "budget_mensuel_max", objectifEpargne = "objectif_epargne", reglesImport = "regles_import"
    }
    static let colonnes = "id,prenom,visibilite,budget_mensuel_max,objectif_epargne,regles_import"
}

struct Membre: Codable, Hashable, Identifiable {
    var id: String
    var prenom: String
    var visibilite: String
}

struct Enveloppe: Codable, Hashable, Identifiable {
    var id: String
    var profilId: String
    var sc: String
    var montant: Double
    var report: Bool
    enum CodingKeys: String, CodingKey { case id, montant, report, profilId = "profil_id", sc = "sous_categorie" }
}

struct Objectif: Codable, Hashable, Identifiable {
    var id: String
    var profilId: String
    var nom: String
    var support: String
    var cible: Double
    var dateVisee: String?
    enum CodingKeys: String, CodingKey { case id, nom, support, cible, profilId = "profil_id", dateVisee = "date_visee" }
}

struct Planifiee: Codable, Hashable, Identifiable {
    var id: String
    var profilId: String
    var cat: Cat
    var sc: String
    var montant: Double
    var note: String
    var compte: String
    var vers: String?
    var jour: Int
    var depuis: String
    var actif: Bool
    enum CodingKeys: String, CodingKey {
        case id, montant, compte, jour, depuis, actif
        case profilId = "profil_id", cat = "categorie", sc = "sous_categorie", note = "description", vers = "vers_compte"
    }
}

struct Groupe: Codable, Hashable, Identifiable {
    var id: String
    var nom: String
    var creePar: String?
    enum CodingKeys: String, CodingKey { case id, nom, creePar = "cree_par" }
}

struct Participant: Codable, Hashable, Identifiable {
    var id: String
    var groupeId: String
    var nom: String
    var profilId: String?
    enum CodingKeys: String, CodingKey { case id, nom, groupeId = "groupe_id", profilId = "profil_id" }
}

struct DepensePartagee: Codable, Hashable, Identifiable {
    var id: String
    var groupeId: String
    var titre: String
    var montant: Double
    var payeur: String
    var parts: [String]
    var mode: String
    var valeurs: [String: Double]
    var sc: String
    var date: String
    var devise: String?
    var montantDevise: Double?
    enum CodingKeys: String, CodingKey {
        case id, titre, montant, payeur, parts, mode, valeurs, devise
        case groupeId = "groupe_id", sc = "sous_categorie", date = "date_depense", montantDevise = "montant_devise"
    }
}

struct Reglement: Codable, Hashable, Identifiable {
    var id: String
    var groupeId: String
    var de: String
    var a: String
    var montant: Double
    var date: String
    enum CodingKeys: String, CodingKey { case id, de, a, montant, groupeId = "groupe_id", date = "date_reglement" }
}

/// Un groupe avec tout son contenu, prêt pour les calculs.
struct GroupeComplet: Hashable, Identifiable {
    var groupe: Groupe
    var participants: [Participant]
    var depenses: [DepensePartagee]
    var reglements: [Reglement]
    var id: String { groupe.id }
    func nom(_ pid: String) -> String { participants.first { $0.id == pid }?.nom ?? "?" }
}

struct MouvementTitre: Codable, Hashable, Identifiable {
    var id: String
    var profilId: String
    var date: String
    var titre: String
    var enveloppe: String
    var sens: String
    var parts: Double
    var prix: Double?
    enum CodingKeys: String, CodingKey { case id, titre, enveloppe, sens, parts, prix, profilId = "profil_id", date = "date_mouvement" }
}

struct Cours: Codable, Hashable {
    var titre: String
    var date: String
    var prix: Double
    enum CodingKeys: String, CodingKey { case titre, prix, date = "date_cours" }
}

/// Tout ce que l'app garde en copie locale (pour s'ouvrir sans réseau).
struct Instantane: Codable {
    var profil: Profil?
    var membres: [Membre] = []
    var ops: [Operation] = []
    var enveloppes: [Enveloppe] = []
    var objectifs: [Objectif] = []
    var planifiees: [Planifiee] = []
    var groupes: [Groupe] = []
    var participants: [Participant] = []
    var depenses: [DepensePartagee] = []
    var reglements: [Reglement] = []
    var mouvements: [MouvementTitre] = []
    var cours: [Cours] = []
    var misAJour: Date?
}
