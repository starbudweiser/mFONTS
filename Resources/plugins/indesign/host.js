// InDesign : documents ouverts et événements d'ouverture.
const idd = require("indesign");
function pathOf(d) {
  try {
    const f = d.fullName;
    if (typeof f === "string") return f;
    if (f && (f.nativePath || f.fsName)) return f.nativePath || f.fsName;
    if (d.filePath) return String(d.filePath);
  } catch (e) { /* document jamais enregistré */ }
  return "";
}
window.HOST = {
  name: "InDesign",
  documents() { const out = []; for (const d of idd.app.documents) { const p = pathOf(d); if (p.startsWith("/")) out.push(p); } return out; },
  listen(cb) { idd.app.addEventListener("afterOpen", cb); idd.app.addEventListener("afterActivate", cb); },
};
