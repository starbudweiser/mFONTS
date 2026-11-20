# mFONTS — architecture proposée (à valider avant code)

Gestionnaire de polices personnel pour macOS, inspiré de Right Fonts, avec import des bibliothèques, collections et préférences de Right Fonts. Appli du **DESKTOP MAC TOOLKIT**, design **Flat Round** (arrondis 8, « m » #2C9ED6), langues FR/EN/ES/IT.

## Ce qui a été constaté dans Right Fonts (à importer)
- **Bibliothèques** (`…/FONTS/Libraries/*.rightfontlibrary`, 10) : `manifest.rightfontmetadata` (JSON : uuid, nom), `fonts/<Lettre>/<Police>/fichier.otf|ttf` (6 642 fichiers), `metadata/fonts/<id>.rightfontmetadata` (JSON par police : famille, style, designer, licence, langues, poids, largeur, notes, étiquettes, favori…). `metadata/fontlists` et `metadata/tags` sont vides.
- **Collections / étiquettes / états** : base SQLite `~/Library/Application Support/RightFont/Data/core-v10.db` (tables `library`, `collection` : 9 collections, `fontCollection`, `tag` : 7, `fontTag`, `font` : 14 820 dont 1 780 actives).
- **Préférences** : `defaults com.rightfontapp.RightFont5` (activation auto pour 38 applis, taille d'aperçu 110, vue grille, lancement à la session…).
- Google Fonts (6 556) et Icons : bibliothèques en ligne de Right Fonts ; non importées par défaut.

## Pile technique
Swift / SwiftUI + AppKit (comme mBACKUP), SQLite (SQLite3 natif), CoreText. Dossier `Sources/`, `build_app.sh` (signature `_tools/sign_app.sh`, install dans `~/Applications/Applications Personnelles`), version de dev `….dev`, entrée dans la liste APPS de `build_all.sh`. Dépôt privé GitHub `starbudweiser/mFONTS`, `release.sh` + notarisation à la demande.

## Modules
| Module | Rôle |
|---|---|
| `Model` / `Store` | Catalogue SQLite `~/Library/Application Support/mFONTS/mfonts.db` : bibliothèques, polices (nom PostScript, famille, style, chemin **référencé**, métadonnées), collections, listes intelligentes (règles), étiquettes, états |
| `Scanner` | Lit les fichiers OTF/TTF/TTC (CoreText : noms, styles, langues, glyphes, licence) ; détecte ajouts/suppressions, doublons (nom PostScript) |
| `RightFontImporter` | 1) lit manifests + `metadata/fonts/*.rightfontmetadata` ; 2) copie en **lecture seule** collections/étiquettes/états depuis `core-v10.db` (ouverte en `immutable`) ; 3) lit les préférences ; rapport d'import (compte, erreurs, doublons). Ne modifie jamais Right Fonts |
| `Activation` | `CTFontManagerRegisterFontURLs` / `Unregister`, portée session ou persistante ; activation par famille ; mémorise l'état |
| `AutoActivation` (v2) | Activation par application surveillée (liste importée de Right Fonts) via un agent léger ; hors v1 |
| `Preview` | Grille/liste, texte d'aperçu partagé, taille, glyphes, styles (vraies polices, chargement paresseux) |
| `MenuBar` | Icône monochrome `isTemplate`, menu ouvert sous l'icône (jamais `statusItem.menu`), préférence Dock / barre / les deux |
| `Updater` | Modèle mBACKUP (recherche quotidienne GitHub, signature Developer ID, relance) ; réglage « installer automatiquement » + bouton manuel |
| `L10n` / `About` / `Socle` | 4 langues (clés `upd.*`…), fenêtre « À propos » (collection DESKTOP MAC TOOLKIT), thème Flat Round |

## Flux d'import
Écran Import → détection du dossier Libraries → choix bibliothèques / collections / étiquettes / favoris / états / préférences → aperçu → import (référencement, aucune copie) → rapport → activation optionnelle des polices qui étaient actives.

## Livraison par étapes
1. Catalogue + import Right Fonts + grille d'aperçu + inspecteur.
2. Activation manuelle, collections, listes intelligentes, doublons.
3. Barre de menus, réglages, mise à jour, langues, À propos.
4. Activation automatique par application (v2).

## Points d'attention
- Les chemins des polices pointent vers `/Volumes/OWC 6To/RESSOURCES/…` : gestion du volume absent (polices grisées, pas d'erreur).
- Licences : champ affiché par police (« usage personnel » repéré depuis le texte de licence).
- Build de test = premier lancement vierge (bundle et dossier de données distincts).
