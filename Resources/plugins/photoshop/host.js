// Photoshop : documents ouverts et événement d'ouverture.
const ps = require("photoshop");
window.HOST = {
  name: "Photoshop",
  documents() { return ps.app.documents.map((d) => d.path).filter((p) => typeof p === "string" && p.startsWith("/")); },
  listen(cb) { ps.action.addNotificationListener([{ event: "open" }, { event: "select" }], cb); },
};
