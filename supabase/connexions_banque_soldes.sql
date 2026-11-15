-- Contrôle des soldes après chaque synchronisation des banques (15/11/2026).
-- Ajoute 3 colonnes à la table connexions_banque (déjà créée par schema_v19_securite.sql, déjà protégée :
-- chacun ne lit que ses propres lignes). Rien n'est supprimé ni modifié dans les données existantes.
-- À lancer une fois dans Supabase : SQL Editor > New query > coller > Run.
alter table public.connexions_banque add column if not exists solde_base   numeric;   -- solde calculé par l'app
alter table public.connexions_banque add column if not exists solde_banque numeric;   -- solde donné par la banque
alter table public.connexions_banque add column if not exists alerte       text;      -- écart à signaler (vide si tout va bien)
