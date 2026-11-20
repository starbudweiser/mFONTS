// mFONTS — cœur commun des extensions Adobe (UXP) : envoie à mFONTS le document qui vient de s'ouvrir.
// mFONTS écrit un fichier « pont » (port + jeton) et écoute sur 127.0.0.1 ; l'extension ne parle qu'à lui.
const storage = require("uxp").storage;
const sent = new Map();                       // chemin → nombre de polices déjà traitées (un envoi par document)
const log = (m) => { const e = document.getElementById("log"); if (e) e.textContent = m; };

async function bridge() {
  const fs = storage.localFileSystem;
  const home = require("os").homedir();
  const out = [];
  for (const name of ["mFONTS", "mFONTS dev"]) {
    try {
      const f = await fs.getEntryWithUrl("file://" + encodeURI(home + "/Library/Application Support/" + name + "/bridge.json"));
      out.push(JSON.parse(await f.read()));
    } catch (e) { /* suivant */ }
  }
  return out;
}

async function activate(path) {
  let last = "mFONTS n'est pas lancé.";
  for (const info of await bridge()) {
    try {
      const r = await fetch(`http://127.0.0.1:${info.port}/v1/activate`, {
        method: "POST",
        headers: { Authorization: `Bearer ${info.token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ path, app: window.HOST.name }),
      });
      if (r.ok) return await r.json();
      last = "mFONTS a répondu " + r.status;
    } catch (e) { last = "mFONTS ne répond pas."; }
  }
  throw new Error(last);
}

async function check(force) {
  let paths = [];
  try { paths = window.HOST.documents(); } catch (e) { log("Documents illisibles : " + e.message); return; }
  for (const p of paths) {
    if (!p || (!force && sent.has(p))) continue;
    sent.set(p, 0);
    try {
      const r = await activate(p);
      sent.set(p, r.activated);
      log(r.activated > 0 ? `${r.activated} police(s) activée(s) pour ${p.split("/").pop()}.` : `Polices déjà disponibles pour ${p.split("/").pop()}.`
        + (r.missing && r.missing.length ? "\nIntrouvables : " + r.missing.slice(0, 4).join(", ") : ""));
    } catch (e) { sent.delete(p); log(e.message); }
  }
}

window.mfontsCheck = check;
try { window.HOST.listen(() => check(false)); } catch (e) { log("Événements indisponibles : " + e.message); }
setInterval(() => check(false), 3000);        // filet de sécurité si un événement d'ouverture manque
check(false);
document.addEventListener("DOMContentLoaded", () => {
  const b = document.getElementById("go"); if (b) b.onclick = () => check(true);
});
