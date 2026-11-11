-- =====================================================================
-- Budget entre amis — schéma Supabase (profils, opérations, comptes)
-- À exécuter dans : Supabase > SQL Editor > New query > Run
-- Sans danger : le script ne crée que ce qui manque et NE SUPPRIME AUCUNE donnée.
-- Il peut être relancé autant de fois que nécessaire.
-- =====================================================================

-- 0) Tables de la toute première version (v1), devenues inutiles
drop table if exists public.depenses          cascade;
drop table if exists public.objectifs_limites cascade;

-- 1) Profils : un par ami, protégé par un code PIN (stocké haché, jamais en clair)
create table if not exists public.profils (
    id                  uuid          primary key default gen_random_uuid(),
    created_at          timestamptz   not null default now(),
    prenom              text          not null check (length(trim(prenom)) between 2 and 30),
    pin_hash            text          not null,
    visibilite          text          not null default 'prive'
                                      check (visibilite in ('prive', 'resume', 'tout')),
    budget_mensuel_max  numeric(12,2) not null default 0 check (budget_mensuel_max >= 0),
    objectif_epargne    numeric(12,2) not null default 0 check (objectif_epargne >= 0)
);

-- Un prénom ne peut exister qu'une fois (insensible à la casse : "Léa" = "léa")
create unique index if not exists profils_prenom_unique on public.profils (lower(prenom));

-- Objectifs par catégorie d'épargne, ex. {"Livret": 3000, "Projet": 800} (ajout v13, sans perte de données)
alter table public.profils add column if not exists objectifs_epargne jsonb not null default '{}'::jsonb;

-- Corrections retenues lors des imports de relevé : libellé bancaire -> [catégorie, note] (ajout v15)
alter table public.profils add column if not exists regles_import jsonb not null default '{}'::jsonb;

-- Relevés des livrets (lignes : date, montant, solde, libellé) pour afficher les vrais soldes et les intérêts (ajout v17)
alter table public.profils add column if not exists avoirs jsonb not null default '{}'::jsonb;

-- 2) Opérations : revenus, dépenses (besoins / envies) et épargne
create table if not exists public.operations (
    id              uuid          primary key default gen_random_uuid(),
    created_at      timestamptz   not null default now(),
    date_operation  date          not null default current_date,
    profil_id       uuid          not null references public.profils (id) on delete cascade,
    categorie       text          not null check (
                        categorie in ('Revenu', '50% - Besoins', '30% - Envies', '20% - Épargne', 'Virement')
                    ),
    sous_categorie  text          not null default 'Autre',
    montant         numeric(12,2) not null check (montant > 0),
    description     text          not null default ''
);

create index if not exists operations_profil_date_idx on public.operations (profil_id, date_operation desc);

-- Plusieurs comptes (ajout v18, sans perte de données) : chaque opération appartient à un compte
-- ('' = le compte courant, sinon son nom : « Revolut », « Trade Republic »…). Un virement entre deux de
-- ses comptes (catégorie 'Virement') part de `compte` et arrive sur `vers_compte` : ni revenu ni dépense.
alter table public.operations add column if not exists compte      text not null default '';
alter table public.operations add column if not exists vers_compte text;
alter table public.operations drop constraint if exists operations_categorie_check;
alter table public.operations add constraint operations_categorie_check check (
    categorie in ('Revenu', '50% - Besoins', '30% - Envies', '20% - Épargne', 'Virement'));

-- 3) Accès applicatif : c'est l'application (côté serveur) qui contrôle qui voit / modifie quoi.
--    La clé Supabase reste sur le serveur Streamlit, elle n'est jamais envoyée au navigateur.
--    Certains projets Supabase réactivent automatiquement le RLS sur les nouvelles tables :
--    on le laisse donc actif et on ajoute une politique qui autorise tout à l'application.
alter table public.profils    enable row level security;
alter table public.operations enable row level security;

drop policy if exists "acces_application" on public.profils;
create policy "acces_application" on public.profils
    for all to anon, authenticated using (true) with check (true);

drop policy if exists "acces_application" on public.operations;
create policy "acces_application" on public.operations
    for all to anon, authenticated using (true) with check (true);

-- 4) Droits pour l'API (rôles utilisés par la Publishable / anon key)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.profils    to anon, authenticated;
grant select, insert, update, delete on public.operations to anon, authenticated;
