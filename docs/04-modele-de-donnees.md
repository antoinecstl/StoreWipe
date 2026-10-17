# Modèle de données et transitions d'état

Les **décisions de l'utilisateur** et les **états d'analyse** sont stockés séparément : une analyse ne modifie jamais une décision, et une décision n'invalide jamais une analyse.

## 1. Schéma v1 (implémenté — `Schema.swift`)

### `assets` — index minimal de la photothèque
| Colonne | Rôle |
|---------|------|
| `local_id` (PK) | `PHAsset.localIdentifier` (propre à l'appareil) |
| `sort_date` | date de création, ou 0 si inconnue (les photos sans date passent en dernier) |
| `creation_date`, `modification_date` | dates PhotoKit |
| `month_key` | `AAAAMM` calculé dans le calendrier de l'utilisateur ; `NULL` = sans date |
| `pixel_width`, `pixel_height`, `subtypes`, `burst_id`, `is_favorite` | métadonnées utiles au tri et aux indices affichés |
| `fingerprint` | empreinte de **modification** (date de modification, dimensions, sous-types) ; sert à invalider les analyses, ce n'est pas une preuve d'identité |
| `visibility` | 0 = accessible, 1 = inaccessible (masquée, retirée de l'accès limité, absence non confirmée) |
| `last_seen_generation` | numéro de la dernière passe d'indexation où la photo a été vue |
| `first_seen_at`, `inaccessible_since` | horodatages techniques |

### `decisions` — décision courante
Une ligne par photo décidée. **Absence de ligne = non examinée.** `decision` ∈ {1 conservée, 2 à supprimer, 3 reportée}, `decided_at`, `session_id`.

### `decision_events` — journal des changements
`previous_decision`, `previous_decided_at`, `new_decision`, `created_at`, `session_id`, `undone`. Sert à l'annulation (y compris après redémarrage) et aux compteurs de session.

### `sessions`
`scope` (représentation textuelle stable, ex. `standard|month:202403`), `started_at`, `ended_at` (`NULL` = active), curseur de reprise (`cursor_sort_date`, `cursor_local_id`).

### `meta`
Paires clé/valeur techniques (`sync_generation`).

### Prévu
| Version | Table | Contenu | Incrément |
|---------|-------|---------|-----------|
| v2 | `resource_digests` | photo, type et UTI de ressource, taille, SHA-256 (partiel et complet), version de la méthode, empreinte de modification au moment du calcul, statut (calculé / iCloud requis / échec) | D |
| v2 | `deletion_log` | lot, nombre demandé, nombre réellement supprimé, date (sans identifiant après purge) | C |
| v3 | `analyses` | photo, type d'analyse, état, version du modèle et de la taxonomie, scores internes, motifs, tentatives, dernière erreur, empreinte au moment de l'analyse | E |

## 2. Décisions

```
                 conserver                    à supprimer
   ┌──────────────────────────► CONSERVÉE ◄────────────────┐
   │                              │  ▲                      │
   │                   à supprimer│  │conserver             │
   │                              ▼  │                      │
NON EXAMINÉE ───── à supprimer ──► À SUPPRIMER ◄──────────── REPORTÉE
   │   ▲                                                    ▲   │
   │   └──────────── annulation (rétablit l'état précédent) ┘   │
   └───────────────────────── passer ───────────────────────────┘
```

Règles :
- **Annuler** rétablit exactement l'état précédent, date comprise (une photo reportée retrouve sa place dans la file des reportées). L'annulation n'est possible que si le changement est toujours le plus récent pour cette photo ; sinon elle est refusée sans rien modifier et l'utilisateur est prévenu.
- La pile d'annulation (50 actions) est reconstruite au redémarrage à partir du journal.
- **Passer** (`reportée`) : la photo est exclue de la session en cours, puis reproposée dans une session ultérieure, après les photos jamais examinées, de la plus anciennement passée à la plus récente.
- **Revue des conservées** : « Passer » ne change rien ; « À supprimer » change la décision ; « Conserver » reconfirme.
- **Aucune décision ne supprime une photo.** La suppression réelle (incrément C) passera par la sélection, la confirmation iOS, puis la purge des lignes des photos dont l'absence est constatée.
- **Réinitialiser les décisions** : efface `decisions`, `decision_events` et `sessions` ; conserve l'index (et, plus tard, les analyses).
- **Effacer les données** : vide toutes les tables, compacte le fichier (`VACUUM`, `wal_checkpoint(TRUNCATE)`), efface les réglages et les caches, revient à l'écran de bienvenue.

## 3. Sessions et piles

| Périmètre (`pool`) | Phases | Ordre |
|--------------------|--------|-------|
| `standard` | 1. non examinées 2. reportées lors de sessions précédentes | date décroissante ; puis date de report croissante |
| `deferredOnly` | reportées | date de report croissante |
| `keptReview` | conservées | date décroissante |

Filtre : tout, un mois, ou « sans date ».

- **Une seule session active.** En ouvrir une autre clôt la précédente. « Commencer » reprend la session active de même périmètre s'il lui reste des photos ; sinon en crée une nouvelle.
- **Curseur** : clé (date, identifiant) de la photo affichée, persistée après chaque action. À la reprise, la pile repart de ce curseur (inclus) ; les photos plus récentes arrivées entre-temps sont proposées ensuite.
- Les phases « reportées » et « conservées » excluent les photos déjà traitées pendant la session (via le journal), ce qui garantit qu'une session se termine.

## 4. Index et réconciliation

| Événement | Effet |
|-----------|-------|
| Photo vue pendant une passe | insérée ou mise à jour ; redevient accessible ; décision intacte |
| Empreinte modifiée (retouche, recadrage…) | signalée (`contentChanged`) ; **décision conservée** ; les analyses seront invalidées (E). Règle justifiée : une retouche ne dit rien de l'intention de garder ou non la photo. Une photo « à supprimer » modifiée depuis la décision sera signalée dans la sélection (C). |
| Absente, accès complet, introuvable par identifiant | purge des lignes (asset, décision, journal) |
| Absente, accès complet, retrouvée (photo masquée) | inaccessible |
| Absente, accès limité | inaccessible (jamais purgée) |
| Purge massive suspecte | suspendue, photos inaccessibles, message |
| Passe interrompue | aucune réconciliation |

## 5. États d'analyse (prévus, incréments D/E)

```
À ANALYSER ──► EN COURS ──► ANALYSÉE
    ▲              │  │
    │              │  └──► EN ATTENTE DE RESSOURCE (iCloud non autorisé / hors ligne)
    │              ▼
    └──────── ÉCHEC RÉCUPÉRABLE (tentatives bornées, nouvel essai à l'ouverture suivante)
```

- Une modification de l'image (empreinte) ou un changement de version du modèle/taxonomie remet l'analyse « à analyser ».
- Une photo en échec ou incertaine reste disponible dans le tri manuel et n'apparaît dans aucune catégorie.
