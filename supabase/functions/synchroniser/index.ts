// Fonction Supabase « synchroniser » : le bouton Synchroniser de l'app l'appelle ; elle lance la synchro des banques sur GitHub.
// La clé de la banque reste dans les secrets GitHub : ni l'app ni cette fonction ne la voient.
// Secrets de la fonction (Supabase > Edge Functions > Secrets) :
//   GITHUB_JETON     jeton GitHub limité à ce dépôt, droit « Actions : Read and write » seulement
//   GITHUB_DEPOT     arrhuridel/le-cercle-ios
//   EMAIL_AUTORISE   l'e-mail du compte qui a le droit de synchroniser (les autres membres du Cercle, non)
// SUPABASE_URL et SUPABASE_ANON_KEY sont fournis automatiquement par Supabase.
import { createClient } from "jsr:@supabase/supabase-js@2";

const entetes = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};
const reponse = (code: number, corps: Record<string, unknown>) => new Response(JSON.stringify(corps), { status: code, headers: entetes });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: entetes });

  // 1. Qui appelle ? Seul le compte autorisé peut lancer une synchro.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  const autorise = (Deno.env.get("EMAIL_AUTORISE") ?? "").toLowerCase();
  if (!user || !autorise || (user.email ?? "").toLowerCase() !== autorise) {
    return reponse(403, { erreur: "Ce compte ne peut pas lancer la synchronisation." });
  }

  // 2. Lancer la synchro sur GitHub (elle prend environ une minute)
  const r = await fetch(`https://api.github.com/repos/${Deno.env.get("GITHUB_DEPOT")}/actions/workflows/synchro-banque.yml/dispatches`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("GITHUB_JETON")}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "le-cercle",
    },
    body: JSON.stringify({ ref: "main" }),
  });
  if (r.status !== 204) {
    return reponse(502, { erreur: `GitHub a refusé (${r.status}). Vérifie le jeton GITHUB_JETON.` });
  }
  return reponse(200, { lance: true, message: "Synchronisation lancée : environ une minute." });
});
