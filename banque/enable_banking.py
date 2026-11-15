"""Client Enable Banking (lecture des comptes, PSD2), sans bibliothèque spéciale : requests + PyJWT.

Chaque appel est signé par un jeton (JWT) fabriqué avec la clé privée de l'application « Le Cercle ».
La clé n'est JAMAIS dans le code ni dans le dépôt : son chemin vient de la variable EB_CLE (fichier .pem)
ou son contenu de EB_CLE_TEXTE (secret GitHub). L'identifiant de l'application vient de EB_APP_ID.
"""
from __future__ import annotations

import os
import time
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import jwt
import requests

API = "https://api.enablebanking.com"
APP_ID_DEFAUT = "9828774e-ab1a-473d-a62e-2669a6401b55"   # identifiant public de l'application (pas un secret)
REDIRECTION = "https://le-cercle-rvon.onrender.com/"

# Banque (nom Enable Banking, pays) -> compte dans la base du Cercle ("" = compte courant Crédit Mutuel)
BANQUES = {
    "Crédit Mutuel": ("Crédit Mutuel", "FR", ""),
    "BoursoBank": ("Boursorama Banque", "FR", "Boursobank"),
    "Revolut": ("Revolut", "FR", "Revolut"),
    "Trade Republic": ("Trade Republic", "FR", "Trade Republic"),
}


class ErreurBanque(RuntimeError):
    """Réponse d'Enable Banking qui n'est pas un succès (message lisible)."""


def _cle_privee() -> str:
    texte = os.environ.get("EB_CLE_TEXTE")
    if texte:
        return texte
    chemin = os.environ.get("EB_CLE")
    if not chemin:
        raise ErreurBanque("Clé introuvable : indique le chemin du fichier .pem dans la variable EB_CLE.")
    return Path(chemin).read_text(encoding="utf-8")


def _jeton() -> str:
    maintenant = int(time.time())
    app_id = os.environ.get("EB_APP_ID", APP_ID_DEFAUT)
    return jwt.encode({"iss": "enablebanking.com", "aud": "api.enablebanking.com", "iat": maintenant, "exp": maintenant + 3600},
                      _cle_privee(), algorithm="RS256", headers={"kid": app_id})


def appel(methode: str, chemin: str, **kw) -> dict:
    r = requests.request(methode, API + chemin, headers={"Authorization": f"Bearer {_jeton()}"}, timeout=60, **kw)
    if r.status_code >= 400:
        try:
            detail = r.json()
        except ValueError:
            detail = r.text[:300]
        raise ErreurBanque(f"{methode} {chemin} : erreur {r.status_code} · {detail}")
    return r.json() if r.content else {}


def application() -> dict:
    """Informations sur l'application (sert à vérifier que la clé est acceptée)."""
    return appel("GET", "/application")


def duree_max(banque: str) -> int:
    """Durée maximale de l'accès accordée par la banque, en jours (180 en général, 90 pour Trade Republic)."""
    nom, pays, _ = BANQUES[banque]
    for a in appel("GET", "/aspsps", params={"country": pays, "psu_type": "personal", "service": "AIS"}).get("aspsps", []):
        if a["name"] == nom and a.get("maximum_consent_validity"):
            return int(a["maximum_consent_validity"]) // 86400
    return 90


def debut_connexion(banque: str, jours: int | None = None) -> str:
    """Ouvre l'accès à une banque : renvoie l'adresse de la page de la banque où Arthur se connecte."""
    nom, pays, _ = BANQUES[banque]
    jours = jours or duree_max(banque)
    fin = (datetime.now(timezone.utc) + timedelta(days=jours) - timedelta(minutes=5)).isoformat(timespec="seconds")
    r = appel("POST", "/auth", json={"access": {"valid_until": fin}, "aspsp": {"name": nom, "country": pays},
                                     "state": str(uuid.uuid4()), "redirect_url": REDIRECTION, "psu_type": "personal"})
    return r["url"]


def fin_connexion(code: str) -> dict:
    """Échange le code reçu au retour de la banque contre une session (valable 90 à 180 jours selon la banque)."""
    return appel("POST", "/sessions", json={"code": code})


def session(session_id: str) -> dict:
    return appel("GET", f"/sessions/{session_id}")


def soldes(compte_uid: str) -> list[dict]:
    return appel("GET", f"/accounts/{compte_uid}/balances").get("balances", [])


def operations(compte_uid: str, depuis: date) -> list[dict]:
    """Toutes les opérations d'un compte depuis une date (les pages suivantes sont lues aussi)."""
    tout, suite = [], None
    while True:
        params = {"date_from": depuis.isoformat()}
        if suite:
            params["continuation_key"] = suite
        r = appel("GET", f"/accounts/{compte_uid}/transactions", params=params)
        tout += r.get("transactions", [])
        suite = r.get("continuation_key")
        if not suite:
            return tout
