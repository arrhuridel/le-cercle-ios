"""
Lecture et catégorisation automatique d'un relevé bancaire CSV (export Crédit Mutuel / CIC :
« Date;Date de valeur;Débit;Crédit;Libellé;Solde », ou toute variante avec ces colonnes).

Règles génériques uniquement (enseignes, prélèvements courants, virements). Aucune donnée
personnelle ici : ce qui est propre à chacun est appris par l'application à partir de son
historique et de ses corrections (voir app.py, « import du relevé »).
"""

from __future__ import annotations

import csv
import io
import re
import unicodedata
from dataclasses import dataclass
from datetime import date, datetime


@dataclass
class LigneReleve:
    numero: int          # n° de ligne dans le fichier (2 = première opération)
    compta: date         # date de comptabilisation
    montant: float       # signé : + crédit, − débit
    libelle: str
    solde: float | None


class ReleveIllisible(ValueError):
    """Fichier qui ne ressemble pas à un relevé exploitable (message lisible par l'utilisateur)."""


def sans_accents(texte: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", texte) if not unicodedata.combining(c))


def cle_texte(texte: str) -> str:
    """Clé de comparaison : minuscules, sans accents ni ponctuation. « McDonald's » -> « mcdonald s »."""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", sans_accents(texte).lower()).split())


def _montant(texte: str) -> float | None:
    texte = (texte or "").replace(" ", "").replace(" ", "").replace("€", "").strip()
    if not texte:
        return None
    if "," in texte:
        texte = texte.replace(".", "").replace(",", ".")
    try:
        return float(texte)
    except ValueError:
        return None


def _date(texte: str) -> date | None:
    for fmt in ("%d/%m/%Y", "%d/%m/%y", "%Y-%m-%d", "%d-%m-%Y", "%d.%m.%Y"):
        try:
            return datetime.strptime(texte.strip(), fmt).date()
        except ValueError:
            continue
    return None


def lire_releve(contenu: bytes, garder_zero: bool = False) -> list[LigneReleve]:
    """Lit le fichier exporté par la banque (encodage et séparateur détectés).

    `garder_zero` conserve les lignes à 0 € (sur un livret : « NOUVEAU TAUX DU LIVRET … »)."""
    for encodage in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            texte = contenu.decode(encodage)
            break
        except UnicodeDecodeError:
            continue
    separateur = ";" if texte.count(";") >= texte.count(",") else ","
    lignes = list(csv.reader(io.StringIO(texte), delimiter=separateur))
    entete_i = next((i for i, l in enumerate(lignes[:15])
                     if any("date" in cle_texte(c) for c in l) and any("libell" in cle_texte(c) for c in l)), None)
    if entete_i is None:
        raise ReleveIllisible("Colonnes « Date » et « Libellé » introuvables : est-ce bien l'export CSV de la banque ?")
    entete = [cle_texte(c) for c in lignes[entete_i]]

    def colonne(*mots: str, sauf: str = "") -> int | None:
        for i, nom in enumerate(entete):
            if any(m in nom for m in mots) and not (sauf and sauf in nom):
                return i
        return None

    i_date, i_lib = colonne("date", sauf="valeur"), colonne("libell")
    i_debit, i_credit, i_montant, i_solde = colonne("debit"), colonne("credit"), colonne("montant"), colonne("solde")
    if i_debit is None and i_montant is None:
        raise ReleveIllisible("Colonne des montants (« Débit / Crédit » ou « Montant ») introuvable.")
    sortie = []
    for numero, l in enumerate(lignes[entete_i + 1:], start=entete_i + 2):
        if len(l) <= max(i for i in (i_date, i_lib) if i is not None):
            continue
        jour = _date(l[i_date])
        if jour is None:
            continue
        if i_montant is not None and i_montant < len(l) and _montant(l[i_montant]) is not None:
            montant = _montant(l[i_montant])
        else:
            debit = _montant(l[i_debit]) if i_debit is not None and i_debit < len(l) else None
            credit = _montant(l[i_credit]) if i_credit is not None and i_credit < len(l) else None
            montant = -abs(debit) if debit else (abs(credit) if credit else None)
            if montant is None and garder_zero and (debit is not None or credit is not None):
                montant = 0.0
        if montant is None or (not montant and not garder_zero):
            continue
        solde = _montant(l[i_solde]) if i_solde is not None and i_solde < len(l) else None
        sortie.append(LigneReleve(numero, jour, round(montant, 2), " ".join(l[i_lib].split()), solde))
    if not sortie:
        raise ReleveIllisible("Aucune opération lisible dans ce fichier.")
    return sortie


# ---------------------------------------------------------------------------------------------
# Paiements carte : date d'achat, ville, marchand
# ---------------------------------------------------------------------------------------------

RE_CARTE = re.compile(r"^(?:(\d+) )?PAIEMENTS?(?: CB| PSC)? (\d{2})(\d{2}) (.*?)(?: CARTE \*?\*?\d{4}.*)?$")

# Préfixes de ville tels qu'ils apparaissent dans les libellés (tronqués à 13 caractères)
VILLES = {
    "OLIVET CEDEX": "Olivet", "OLIVET": "Olivet", "45 ORLEANS": "Orléans", "ORLEANS CEDEX": "Orléans",
    "ORLEANS": "Orléans", "NANTES CEDEX": "Nantes", "44 NANTES": "Nantes", "44 /NANTES": "Nantes",
    "NANTES": "Nantes", "REZE": "Rezé", "SAINT HERBLAI": "Saint-Herblain", "ST HERBLAIN": "Saint-Herblain",
    "BASSE GOULAIN": "Basse-Goulaine", "PIRIAC SUR ME": "Piriac-sur-Mer", "LA TRANCHE SU": "La Tranche-sur-Mer",
    "85 LA TRANCHE": "La Tranche-sur-Mer", "LES SABLES D'": "Les Sables-d'Olonne",
    "LES SABLES D": "Les Sables-d'Olonne", "85 LES SABLES": "Les Sables-d'Olonne",
    "PONT SAINT MA": "Pont-Saint-Martin", "PONT ST MARTI": "Pont-Saint-Martin", "PONT ST MART": "Pont-Saint-Martin",
    "ST SEBASTIEN": "Saint-Sébastien", "SAINT SEBASTI": "Saint-Sébastien", "SAINT-SEBASTI": "Saint-Sébastien",
    "MILANO": "Milan", "STOCKHOLM": "Stockholm", "37 /TOURS": "Tours", "TOURS": "Tours",
    "GUERANDE CEDE": "Guérande", "GUERANDE": "Guérande", "MONTPELLIER": "Montpellier", "LA BAULE": "La Baule",
    "SOORTS HOSSEG": "Hossegor", "CAPBRETON": "Capbreton", "ST JEAN DE BR": "Saint-Jean-de-Braye",
    "PERIGNY": "Périgny", "ST ETIENNE DE": "Saint-Étienne-de-Montluc", "SAINT NAZAIRE": "Saint-Nazaire",
    "ST NAZAIRE": "Saint-Nazaire", "TRIGNAC": "Trignac", "PORNIC": "Pornic", "VERTOU": "Vertou",
    "INGRE": "Ingré", "SARAN": "Saran", "LA ROCHELLE": "La Rochelle", "LA ROCHE SUR": "La Roche-sur-Yon",
    "ANGERS": "Angers", "35 RENNES": "Rennes", "RENNES": "Rennes", "DIJON": "Dijon", "LYON": "Lyon",
    "LE VIGEANT": "Le Vigeant", "TALMONT SAINT": "Talmont-Saint-Hilaire", "TALMONTSAINTH": "Talmont-Saint-Hilaire",
    "L'ILE-D'OLONN": "L'Île-d'Olonne", "L ILE D OLONN": "L'Île-d'Olonne", "CHATEAU D OLO": "Château-d'Olonne",
    "MONTBERT": "Montbert", "GENESTON": "Geneston", "BOUAYE": "Bouaye", "ORVAULT": "Orvault", "BLAIN": "Blain",
    "MESQUER": "Mesquer", "SAINT GILDAS": "Saint-Gildas", "ARZON": "Arzon", "LONGEVILLE SU": "Longeville-sur-Mer",
    "LE BERNARD": "Le Bernard", "THOUARE SUR": "Thouaré-sur-Loire", "MONTAIGU": "Montaigu",
    "SAINT-CHAFFRE": "Serre Chevalier", "SAINT CHAFFRE": "Serre Chevalier", "HUEZ": "L'Alpe d'Huez",
    "LES ADRETS": "Les Adrets", "MOIRANS": "Moirans", "BRATISLAVA": "Bratislava", "WIEN": "Vienne",
    "ARLES": "Arles", "34 AGDE": "Agde", "0017 PEROLS/": "Pérols", "SETE": "Sète", "BERGAMO": "Bergame",
    "CHARTRES DE B": "Chartres-de-Bretagne", "POITIERS": "Poitiers", "SAUMUR": "Saumur", "BOURGUEIL": "Bourgueil",
    "SAINTE PAZANN": "Sainte-Pazanne", "SAINTE ANNE S": "Sainte-Anne-sur-Brivet", "LA TURBALLE": "La Turballe",
    "PARIS 10": "Paris", "PARIS 9": "Paris", "PARIS 7": "Paris", "75 PARIS": "Paris", "75011 PARIS": "Paris",
    "75009 PARIS": "Paris", "PARIS": "Paris", "AIGREFEUILLE": "Aigrefeuille", "SAINT AUBIN D": "Saint-Aubin",
    "LA FERRIERE": "La Ferrière", "SAINT HILAIRE": "Saint-Hilaire", "ST HILAIRE DE": "Saint-Hilaire-de-Riez",
    "FLEURY LES AU": "Fleury-les-Aubrais", "CROIX": "Croix", "ST PRYVE": "Saint-Pryvé",
    "ST PHILBERT D": "Saint-Philbert-de-Grand-Lieu", "SAINT VIAUD": "Saint-Viaud", "SAINT JEAN": "Saint-Jean",
    "LESPERON": "Lesperon", "LABENNE": "Labenne", "SAUGON": "Saugon", "LES SORINIERE": "Les Sorinières",
    "LA MONTAGNE": "La Montagne", "MERIEUX": "Mérieux", "TILLE": "Tillé", "DRUYE": "Druye",
    "NOYAL CHATILL": "Noyal-Châtillon", "SAINT MARTIN": "Saint-Martin", "SAINTAUNES": "Saint-Aunès",
    "BARBAZAN DEBA": "Barbazan-Debat", "LOHEAC": "Lohéac", "RUAUDIN": "Ruaudin", "ECHIROLLES": "Échirolles",
    "VERRIERES EN": "Verrières", "SAINT-ANDRE-D": "Saint-André", "SARGE LES LE": "Sargé-lès-le-Mans",
    "MEUNE": "Meung", "LES ESSARTS-L": "Les Essarts", "VERNEUIL D AV": "Verneuil", "LONGUE JUMELL": "Longué-Jumelles",
    "LA ROCHE": "La Roche-sur-Yon", "MARSEILLE": "Marseille", "LILLE": "Lille", "BORDEAUX": "Bordeaux",
    "TOULOUSE": "Toulouse", "NICE": "Nice", "STRASBOURG": "Strasbourg",
}
VILLES_TRIEES = sorted(VILLES, key=len, reverse=True)
# Villes des sièges de services en ligne : ce n'est pas là que l'achat a eu lieu
SIEGES = {"Bordeaux", "Strasbourg"}


def separer_ville(texte: str) -> tuple[str | None, str]:
    for prefixe in VILLES_TRIEES:
        if texte == prefixe or texte.startswith(prefixe + " "):
            return VILLES[prefixe], texte[len(prefixe):].strip()
    return None, texte


def date_achat(jour: str, mois: str, compta: date) -> date:
    """« 0610 » -> 06/10 ; l'année est celle de la comptabilisation (ou la précédente en janvier)."""
    j, m = int(jour), int(mois)
    annee = compta.year - (1 if m > compta.month + 1 else 0)
    try:
        d = date(annee, m, j)
    except ValueError:
        return compta
    return d if d <= compta else compta


# Enseignes connues : (motif, sous-catégorie, nom affiché, en ligne ?)
# « en ligne » = la ville du libellé est celle du siège (Cork, Dublin…) : on ne l'affiche pas.
MARCHANDS: list[tuple[str, str, str | None, bool]] = [
    (r"AMAZON PRIME", "Abonnements", "Amazon Prime", True),
    (r"AMAZON|AMZ", "Shopping", "Amazon", True),
    (r"ANTHROPIC|CLAUDE AI", "Abonnements", "Claude", True),
    (r"OPENAI|CHATGPT", "Abonnements", "ChatGPT", True),
    (r"GOOGLE ONE", "Abonnements", "Google One", True),
    (r"NETFLIX", "Abonnements", "Netflix", True),
    (r"DISNEY", "Abonnements", "Disney+", True),
    (r"DEEZER", "Abonnements", "Deezer", True),
    (r"SPOTIFY", "Abonnements", "Spotify", True),
    (r"AUDIBLE", "Abonnements", "Audible", True),
    (r"SHARESUB", "Abonnements", "Sharesub", True),
    (r"UBER \*ONE", "Abonnements", "Uber One", True),
    (r"UBER \* ?EATS", "Restos & sorties", "Uber Eats", True),
    (r"DELIVEROO", "Restos & sorties", "Deliveroo", True),
    (r"UBR\*|UBER", "Transport", "Uber", True),
    (r"BOLT", "Transport", "Bolt", True),
    (r"RUNPOD", "Abonnements", "RunPod", True),
    (r"FITNESS|BASIC FIT|SPORT OCEANE", "Abonnements", "Salle de sport", False),
    (r"BITSTACK", "Investissement", "Bitstack", True),
    (r"TRADE REPUBLIC", "Investissement", "Trade Republic", True),
    (r"BOURSORAMA", "Livret", "Vers Boursobank", True),
    (r"IZLY|CROUS", "Courses", "Izly · Crous", True),
    (r"LYDIA", "Autre envie", "Lydia", True),
    (r"LEETCHI", "Cadeaux offerts", "Leetchi", True),
    (r"VINTED", "Shopping", "Vinted", True),
    (r"EBAY", "Shopping", "eBay", True),
    (r"ALIEXPRESS", "Shopping", "AliExpress", True),
    (r"SHEIN", "Shopping", "Shein", True),
    (r"CDISCOUNT", "Shopping", "Cdiscount", True),
    (r"ZALANDO", "Shopping", "Zalando", True),
    (r"OPODO", "Voyages", "Opodo", True),
    (r"BKG\*|BOOKING", "Voyages", "Booking.com", True),
    (r"AIRBNB", "Voyages", "Airbnb", True),
    (r"RYANAIR|EASYJET|AIR FRANCE|TRANSAVIA|VUELING", "Voyages", None, True),
    (r"SNCF|OUIGO|TRAINLINE", "Transport", "SNCF", True),
    (r"SERVICE NAVIGO|RATP", "Transport", "Navigo", True),
    (r"BLABLACAR", "Transport", "BlaBlaCar", True),
    (r"LYFPAY|LYF PAY", "Autre envie", "Lyf Pay", True),
    (r"REVOLUT", "Autre envie", "Revolut", True),
    (r"PLUXEE\*SUPER U", "Courses", "Super U (Pluxee)", True),
    (r"PLUXEE|SWILE|EDENRED", "Restos & sorties", "Titre-restaurant", True),
    (r"OSCARO", "Voiture", "Oscaro", True),
    (r"AMENDE", "Autre besoin", "Amende", True),
    (r"WEEZEVENT|YURPLAN|SHOTGUN|TICKETMASTER|FNAC SPECTACLES", "Loisirs", "Billetterie", True),
    (r"HELLO ?ASSO", "Loisirs", "HelloAsso", True),
    (r"STEAM|PLAYSTATION|NINTENDO|XBOX", "Loisirs", None, True),
    (r"APPLE COM/FR", "Shopping", "Apple Store", True),
    (r"BETCLIC", "Jeux d'argent", "Betclic", True),
    (r"WINAMAX", "Jeux d'argent", "Winamax", True),
    (r"UNIBET|PARIONS|ZEBET", "Jeux d'argent", None, True),
    (r"\bFDJ\b", "Jeux d'argent", "FDJ", True),
    (r"\bPMU\b", "Jeux d'argent", "PMU", False),
    (r"CASINO (?!SHOP|SUPERMARCHE)", "Jeux d'argent", "Casino", False),
    (r"MAGASIN U STATIO|STATION HYPER U|LECLERC STATION|CARREFOUR CONTAC|STATION SERVICE", "Transport",
     "Carburant", False),
    (r"MAGASIN U|HYPER U|SUPER U|SUBERDI", "Courses", "Super U", False),
    (r"E LECLERC WEB|LECLERC WEB|PAYWEL LECLERC|LECLERC DRIVE", "Courses", "Leclerc Drive", False),
    (r"LECLERC", "Courses", "Leclerc", False),
    (r"AUCHAN", "Courses", "Auchan", False),
    (r"CARREFOUR|CRF MKT", "Courses", "Carrefour", False),
    (r"INTERMARCHE|JUMADIS", "Courses", "Intermarché", False),
    (r"\bLIDL\b", "Courses", "Lidl", False),
    (r"\bALDI\b", "Courses", "Aldi", False),
    (r"MONOPRIX|FRANPRIX|\bSPAR\b|CASINO SHOP|PICARD|BIOCOOP", "Courses", None, False),
    (r"\bCOOP\b", "Courses", "Coop", False),
    (r"COCCIMARKET|SARL TIM|SUPERMAR", "Courses", None, False),
    (r"BOULANGERIE|FOURNIL|PATISSERIE|BRIOCHE DOREE|PAUL\b", "Courses", None, False),
    (r"IUT CAFET|EUREST|RESTAURANT UNIV", "Courses", "Restauration universitaire", False),
    (r"PETRO-OUEST", "Transport", "Carburant", False),
    (r"\bTOTAL\b|\bSHELL\b|\bESSO\b|\bAVIA\b|\bBP\b|RELAIS DE REZE", "Transport", "Carburant", False),
    (r"NAOLIB|SEMITAN|SGO MTICK|\bTAO\b|FIL BLEU|\bTCL\b|\bTISSEO\b", "Transport", None, False),
    (r"BICLOO|VELIB|VELO", "Abonnements", None, False),
    (r"LIME\*|PONY SA|COOLTRA|DOTT|TIER", "Transport", None, True),
    (r"WOP M TICKET|ALEOP|REGION PDL", "Transport", "Aléop", True),
    (r"COFIROUTE|VINCI AUTOROUTE|APRR|SANEF|BORNES BARRIERE|PEAGE", "Transport", "Péage", False),
    (r"PARKING|PKG |STATIONNE|HORODATEUR|HOR-FPS|CITEDIA|INDIGO|EFFIA|FORF P STAT", "Transport", "Stationnement", False),
    (r"TELEPHERIQUES|ALPINRESORTS|DOMAINE SKIA|FORFAIT SKI", "Loisirs", "Ski", False),
    (r"NORAUTO|SPEEDY|MIDAS|FEU VERT|POINT S|GARAGE|MECAMAX|MOTOREP|ADTYRES|LAVAGE|CONTROLE TECH", "Voiture",
     None, False),
    (r"AUTO.?ECOLE|CONDUITE", "Voiture", "Auto-école", False),
    (r"DOCTEUR|MEDECIN|DR ", "Santé", "Médecin", False),
    (r"PHARMA|DENTIST|OPTIC|LABORATOIRE|KINE", "Santé", None, False),
    (r"COIFFURE|COIFFEUR|POP CUT|BARBER|BELLE COUPE", "Autre besoin", "Coiffeur", False),
    (r"CORDO\b|PRESSING|LA POSTE", "Autre besoin", None, False),
    (r"UNIV|AGENT COMPTABLE|LIBRAIRIE|PAPETERIE", "Études", None, False),
    (r"\bZARA\b|\bH&M\b|HETM\d|PRIMARK|KIABI|CELIO|JULES|BERSHKA|PULL ?AND ?BEAR|UNIQLO|LA HALLE", "Shopping", None,
     False),
    (r"DECATHLON|INTERSPORT|INTERPSPORT|GO SPORT|NIKE|ADIDAS|COLUMBIA|JD SPORTS|FOOT LOCKER", "Shopping", None, False),
    (r"\bGIFI\b|ACTION \d|FOIR'FOUILLE|\bIKEA\b|LEROY MERLIN|WELDOM|CASTORAMA|\bBUT\b|CONFORAMA", "Shopping", None,
     False),
    (r"\bFNAC\b|DARTY|BOULANGER|LOUIS PION|SEPHORA|NOCIBE|MARIONNAUD", "Shopping", None, False),
    (r"\bCINE\b|CINEMA|PATHE|GAUMONT|MEGARAMA|UGC", "Loisirs", "Cinéma", False),
    (r"BOWLING|EUROBOWL|PATINOIRE|TRAMPOLINE|SOCCER|PISCINE|AQUATIQ|KARTING|LASER|ESCAPE|MUSEE|GLISS|TELESKI",
     "Loisirs", None, False),
    (r"VAPOT|CLOPINETTE|E-THIK|TABAC", "Autre envie", None, False),
    (r"BURGER KING|\bBK\b|K1061|K0182", "Restos & sorties", "Burger King", False),
    (r"MC ?DONALD|MCDO|MC DO|MCDSTHLM", "Restos & sorties", "McDonald's", False),
    (r"\bKFC\b", "Restos & sorties", "KFC", False),
    (r"\bQUICK\b", "Restos & sorties", "Quick", False),
    (r"FIVE GUYS", "Restos & sorties", "Five Guys", False),
    (r"SUBWAY", "Restos & sorties", "Subway", False),
    (r"O ?TACOS", "Restos & sorties", "O'Tacos", False),
    (r"STARBUCKS", "Restos & sorties", "Starbucks", False),
    (r"BUFFALO", "Restos & sorties", "Buffalo Grill", False),
    (r"DISTRI CAFE|PAUSE CAFE VEND|MAXICOFFEE|ASSOC CAFETERIA|2H ENCAS|DASHINE|SELECTA", "Restos & sorties",
     "Distributeur café", False),
]
MARCHANDS_RE = [(re.compile(m), sc, nom, enligne) for m, sc, nom, enligne in MARCHANDS]

# Mots qui trahissent un restaurant, un bar ou un café
RE_RESTO = re.compile(
    r"\bBAR\b|\bPUB\b|CAFE|RESTO|RESTAU|BRASSERIE|PIZZ|BURGER|KEBA[BP]|TACOS|SNACK|GRILL|SUSHI|CREPERIE|"
    r"TAVERNE|BISTRO|BODEGA|GLACE|GELAT|BUBBLE|\bTEA\b|\bCLUB\b|SAVEURS|DELICES|FOOD|KITCHEN|TRAITEUR|WOK|"
    r"BOUCHON|CANTINE|BRUNCH|COCKTAIL|DISCOTHEQUE|LOUNGE|ZETTLE|SUMUP"
)


def regle_apple(montant: float) -> tuple[str, str]:
    """Apple : 5,99 € (Apple Music) et 9,99 € (iCloud+) sont des abonnements, le reste des achats d'apps."""
    if abs(montant) in (5.99, 9.99):
        return "Abonnements", "Apple Music" if abs(montant) == 5.99 else "iCloud+"
    return "Loisirs", "App Store"


PETITS_MOTS = {"DE", "DU", "DES", "LA", "LE", "LES", "ET", "EN", "SUR", "AU", "AUX", "A", "L", "D", "ON"}
SIGLES = {"BK", "BM", "BP", "CB", "FR", "PDL", "SNCF", "TAN", "CAF", "KFC", "PMU", "FDJ", "V", "B", "IT"}


def joli(texte: str) -> str:
    """« LE PETIT VAPOTEU » -> « Le Petit Vapoteu », « CHEZ MIMI ET VIN » -> « Chez Mimi et Vin »."""
    texte = re.sub(r"^(?:[A-Z]{3,6}\d{3,}\s*/|\d{3,}\S*/?|SP|SQ|NYX|MOL|SNC|SAS|SARL|EURL|SC-|SNP)\s*\*?", "",
                   texte).strip(" */-")
    texte = re.sub(r"\s+(?:\d{3,}|S A S|SAS|SARL|SC)$", "", texte)
    mots = []
    for i, mot in enumerate(texte.split()):
        if mot in SIGLES:
            mots.append(mot)
        elif i > 0 and mot in PETITS_MOTS:
            mots.append(mot.lower())
        else:
            mots.append("-".join(m.capitalize() for m in mot.split("-")))
    return " ".join(mots) or texte


def phrase(texte: str) -> str:
    """Libellé libre en majuscules -> phrase : « REMB ESSENCE MAMAN » -> « Remb essence maman »."""
    texte = re.sub(r"\s+(?:VU|CU3|VG|VK)\w+.*$|\s+\d{8,}.*$", "", texte).strip().lower()
    texte = re.sub(r"\bnoel\b", "Noël", texte).replace("electricite", "électricité")
    return texte[:1].upper() + texte[1:]


TITRES = re.compile(r"\b(?:M|MR|MME|MLLE|MLE|MADAME|MONSIEUR|DE|ET|OU)\b")


def nom_personne(texte: str) -> str:
    """« VIR INST WERO M PIERRE MARTIN 6286… » -> « Pierre Martin »."""
    texte = re.sub(r"^VIR(?:EMENT)?(?: INST)?(?: SEPA)?(?: WERO)?(?: DE)?\s+", "", texte)
    texte = re.split(r"\s+(?:VIREMENT|VIR|WERO|ENVOYE|PAYLIB)\b", texte)[0]
    texte = re.sub(r"\b[0-9A-F]{16,}\b.*$|\b(?:VU|CU3|WRU|WS|BE)\w*\d\w*\b.*$|\b[\d-]{6,}\b.*$", "", texte)
    mots = list(dict.fromkeys(m for m in TITRES.sub(" ", texte).split() if m))[:3]
    return " ".join("-".join(p.capitalize() for p in m.split("-")) for m in mots) or "inconnu"


def cle_libelle(libelle: str) -> str:
    """Clé stable d'un libellé bancaire, sans dates, références ni montants (pour retenir les corrections)."""
    texte = libelle.upper()
    texte = re.sub(r"^(?:\d+ )?PAIEMENTS?(?: CB| PSC)? \d{4} ", "CB ", texte)
    texte = re.sub(r"^RETRAIT DAB \d{4}", "RETRAIT DAB", texte)
    texte = re.sub(r" CARTE \*?\*?\d{4}.*$", "", texte)
    texte = re.sub(r"\b(?:VU|CU3|UI[A-Z]|VG|VK|WS|ZZ|BE)[A-Z0-9]*\d[A-Z0-9]*\b", " ", texte)
    texte = re.sub(r"\b\d[\d-]{5,}\b|\b[0-9A-F]{16,}\b|\bREF\w*", " ", texte)
    texte = re.sub(r"^CB \d+ \d{2} [A-Z]{3} ", "CB ", texte)  # montant en devise
    return " ".join(texte.split())


ENTRANTS: list[tuple[str, str, str | None]] = [
    (r"\bSALAIRE\b|\bPAIE\b|\bPAYES\b|REMUNER", "Salaire", None),
    (r"VIR CAF\b|ALLOCATION|\bCROUS\b|BOURSE|FRANCE TRAVAIL|POLE EMPLOI", "Bourse & aides", None),
    (r"WINAMAX", "Gains de jeux", "Retrait Winamax"),
    (r"BETCLIC", "Gains de jeux", "Retrait Betclic"),
    (r"PARI MUTUEL|\bPMU\b", "Gains de jeux", "Gain PMU"),
    (r"UNIBET|FDJ|B PLAY PAYOUT", "Gains de jeux", None),
    (r"^VRST|VERSEMENT ESPECES|DEPOT ESPECES", "Dépôt espèces", "Dépôt d'espèces"),
    (r"DEPUIS BITSTACK|TRADE REPUBLIC", "Vente placement", None),
    (r"LIVRET|DEPUIS BOURSOBANK", "Retrait d'épargne", None),
    (r"^F RETRO", "Remboursement", "Frais bancaires remboursés"),
    (r"^CARTE \d{4} \d{4} SNCF", "Remboursement", "Remboursement SNCF"),
    (r"^REMBT|^REMB |^CARTE \d{4}|REMBOURSEMENT", "Remboursement", None),
    (r"^LYF |CAGNOTTE", "Remboursement", "Cagnotte"),
    (r"^REM CHQ|REMISE CHEQUE", "Autre revenu", "Remise de chèque"),
    (r"PAYPAL", "Autre revenu", "PayPal"),
    (r"MANGOPAY", "Autre revenu", "Mangopay"),
    (r"NOEL|ANNIV|CADEAU", "Cadeau reçu", None),
    (r"\bLOYER\b", "Remboursement loyer", None),
]
ENTRANTS_RE = [(re.compile(m), sc, nom) for m, sc, nom in ENTRANTS]

SORTANTS: list[tuple[str, str, str | None]] = [
    (r"VIR LIVRET BLEU", "Livret", "Livret Bleu"),
    (r"VIR LIVRET JEUNE", "Livret", "Livret Jeune"),
    (r"VIR LIVRET|LDDS|LIVRET A\b|\bPEL\b|\bCEL\b", "Livret", "Livret"),
    (r"TRADE REPUBLIC|BOURSE DIRECT|DEGIRO|\bPEA\b|ASSURANCE VIE", "Investissement", None),
    (r"F COTIS|COTISATION|^COMPTE JEUNE|COMMISSION|AGIOS|FRAIS PAIE CB|FRAIS", "Frais bancaires", None),
    (r"\bLOYER\b|FONCIA|NEXITY|CAP RESIDENTIEL|QUITTANCE", "Loyer", None),
    (r"ALTERNA|\bEDF\b|ENGIE|TOTALENERGIES|EKWATEUR|VEOLIA|SUEZ|EAU DE", "Factures", None),
    (r"BOUYGUES|ORANGE|\bSFR\b|FREE MOBILE|FREE TELECOM|\bRED\b|SOSH", None, None),  # forfait ou box
    (r"GMF|MAIF|MACIF|MATMUT|\bAXA\b|ALLIANZ|GROUPAMA|MAAF|LEOCARE|ASSURANCE", "Assurances", None),
    (r"MUTUELLE|HARMONIE|ALAN\b", "Santé", None),
    (r"FITNESS|BASIC FIT|SALLE DE SPORT", "Abonnements", None),
    (r"NAOLIB|SEMITAN|NAVIGO|TRANSPORTS", "Transport", None),
    (r"DGFIP|IMPOT|TRESOR PUBLIC", "Autre besoin", "Impôts"),
    (r"IZLY", "Courses", "Recharge Izly"),
    (r"KDO|CADEAU|ANNIV", "Cadeaux offerts", None),
    (r"AIRBNB|LOGEMENT|HOTEL", "Voyages", None),
    (r"ESSENCE|PEAGE|LOCATION DE VOITURE", "Transport", None),
    (r"DEMENAGEMENT", "Autre besoin", "Déménagement"),
    (r"POKER", "Jeux d'argent", None),
    (r"COIFFEUR", "Autre besoin", "Coiffeur"),
    (r"PIZZA|RESTO|APERO|BAR\b|SOIREE", "Restos & sorties", None),
]
SORTANTS_RE = [(re.compile(m), sc, nom) for m, sc, nom in SORTANTS]
RE_ORGANISME = re.compile(r"GROUPEMENT|INTERET|SARL|SAS|EURL|SA|SOCIETE|ASSOCIATION|ETABLISSEMENT|"
                          r"MAIRIE|REGION|DEPARTEMENT|UNIVERSITE|DDFIP|ENTREPRISE|GIE|HOPITAL|CHU")


def libelle_virement(texte: str) -> str:
    """Partie lisible d'un libellé de virement (sans le préfixe ni les références)."""
    texte = re.sub(r"^(VIR(?:EMENTS?)?( INST| SEPA)?( DE)?|VIR|PRLV SEPA|PRLV)\s+", "", texte)
    texte = re.sub(r"\s+(?:VU|CU3|VG|VK)\w+.*$|\s+\d{8,}.*$|\s+ZZ\w+", "", texte)
    return joli(texte)


def _carte(l: LigneReleve) -> dict | None:
    m = RE_CARTE.match(l.libelle)
    if not m:
        return None
    nb, jour, mois, reste = m.groups()
    ville, marchand = separer_ville(reste)
    devise = re.match(r"^\d+ \d{2} ([A-Z]{3}) (.*)$", marchand)  # « 21 60 EUR ANTHROPIC », « 389 00 SEK ZARA »
    if devise:
        marchand = devise.group(2)
        ville = ville or {"SEK": "Stockholm"}.get(devise.group(1))
    return {"date": date_achat(jour, mois, l.compta), "ville": ville, "marchand": marchand,
            "groupe": int(nb) if nb else 1}


def _proposer_carte(l: LigneReleve, carte: dict) -> dict:
    marchand, ville = carte["marchand"], carte["ville"]
    sc, nom, enligne, sur = None, None, False, True
    if "APPLE" in marchand or "ITUNES" in marchand:
        if "APPLE COM/FR" in marchand:
            sc, nom, enligne = "Shopping", "Apple Store", True
        else:
            (sc, nom), enligne = regle_apple(l.montant), True
    else:
        for motif, s, n, e in MARCHANDS_RE:
            if motif.search(marchand):
                sc, nom, enligne = s, n, e
                break
    if sc is None and RE_RESTO.search(marchand):
        sc = "Restos & sorties"
    if sc is None:
        sc, sur = "Autre envie", False
    nom = nom or joli(marchand)
    if carte["groupe"] > 1:
        nom += f" ({carte['groupe']} achats)"
    description = nom if (enligne or not ville or ville in nom or ville in SIEGES) else f"{nom} · {ville}"
    if l.montant > 0:
        return {"date": carte["date"], "sous_categorie": "Remboursement", "description": f"Remboursement {nom}",
                "sur": sur}
    return {"date": carte["date"], "sous_categorie": sc, "description": description, "sur": sur}


def proposer(l: LigneReleve, prenom: str = "") -> dict:
    """Catégorie proposée pour une ligne : {date, sous_categorie, description, sur}.

    `sur` vaut False quand aucune règle ne s'applique vraiment (catégorie par défaut) : l'historique
    du membre a alors le dernier mot. `prenom` sert à reconnaître les virements entre ses propres comptes.
    """
    lib = l.libelle
    carte = _carte(l)
    if carte:
        return _proposer_carte(l, carte)
    moi = cle_texte(prenom).upper() if prenom else ""
    vers_moi = bool(moi) and re.match(r"^VIR", lib) and f" {moi} " in f" {cle_texte(nom_personne(lib)).upper()} "

    if l.montant > 0:
        if vers_moi:
            if "REVOLUT" in lib:
                return {"date": l.compta, "sous_categorie": "Autre revenu", "description": "Depuis Revolut", "sur": True}
            if re.match(r"^VIR DE M", lib):  # virement interne à la banque : retrait du livret
                return {"date": l.compta, "sous_categorie": "Retrait d'épargne", "description": "Depuis mon livret",
                        "sur": True}
            source = re.search(r"DEPUIS (\w+)", lib)
            return {"date": l.compta, "sous_categorie": "Retrait d'épargne",
                    "description": f"Depuis {source.group(1).capitalize()}" if source else "Depuis mon compte",
                    "sur": False}
        for motif, sc, nom in ENTRANTS_RE:
            if motif.search(lib):
                return {"date": l.compta, "sous_categorie": sc, "description": nom or phrase(libelle_virement(lib)),
                        "sur": True}
        if re.match(r"^VIR", lib) and l.montant >= 250 and RE_ORGANISME.search(lib):
            return {"date": l.compta, "sous_categorie": "Salaire", "description": phrase(libelle_virement(lib)),
                    "sur": False}  # virement important d'une entreprise ou d'un organisme : sans doute une paie
        if re.match(r"^VIR", lib):
            return {"date": l.compta, "sous_categorie": "Remboursement", "description": f"De {nom_personne(lib)}",
                    "sur": False}
        return {"date": l.compta, "sous_categorie": "Autre revenu", "description": joli(lib), "sur": False}

    retrait = re.match(r"^RETRAIT DAB (\d{2})(\d{2})(?: (.*?))?(?: CARTE .*)?$", lib)
    if retrait:
        jour, mois, lieu = retrait.groups()
        ville = next((VILLES[v] for v in VILLES_TRIEES if lieu and v in lieu), None)
        return {"date": date_achat(jour, mois, l.compta), "sous_categorie": "Espèces",
                "description": "Retrait d'espèces" + (f" · {ville}" if ville else ""), "sur": True}
    if vers_moi:
        return {"date": l.compta, "sous_categorie": "Autre épargne",
                "description": f"Vers mon compte · {nom_personne(lib)}", "sur": False}
    for motif, sc, nom in SORTANTS_RE:
        if motif.search(lib):
            if sc is None:  # opérateur télécom : petit montant = forfait, gros = box
                sc = "Factures" if abs(l.montant) >= 40 else "Abonnements"
                nom = ("Box " if sc == "Factures" else "Forfait ") + joli(motif.search(lib).group(0))
            return {"date": l.compta, "sous_categorie": sc, "description": nom or phrase(libelle_virement(lib)),
                    "sur": True}
    if re.match(r"^VIR", lib):
        return {"date": l.compta, "sous_categorie": "Autre envie", "description": f"Virement à {nom_personne(lib)}",
                "sur": False}
    if re.match(r"^PRLV", lib):
        return {"date": l.compta, "sous_categorie": "Factures", "description": libelle_virement(lib), "sur": False}
    # Paiement listé sans préfixe (détail d'un paiement groupé) : traité comme un achat par carte
    return _proposer_carte(l, {"date": l.compta, "ville": None, "marchand": lib, "groupe": 1})
