# Spécification — doublons exacts (incrément D)

Statut : **spécifiée, non implémentée.** Cette définition est fixée avant le développement, conformément au principe 7.

## 1. Définition V1 (stricte)

Deux photos A et B sont des **doublons exacts** si et seulement si :

1. ce sont deux assets PhotoKit distincts de type image ;
2. chacun est **éligible** (§2) ;
3. leurs ressources principales (`PHAssetResource` de type `.photo`) ont le **même identifiant de type (UTI)** ;
4. ces ressources ont **exactement la même taille en octets** ;
5. leurs **empreintes SHA-256 complètes** sont identiques, calculées en lecture progressive sur la totalité des octets ;
6. l'empreinte de modification de chaque photo n'a pas changé depuis le calcul (sinon : recalcul avant toute présentation).

La comparaison porte sur les **octets du fichier original**, métadonnées comprises. Conséquences assumées :
- même image en HEIC et en JPEG → **pas** un doublon exact ;
- mêmes pixels avec des métadonnées différentes (date, localisation retirée, logiciel) → **pas** un doublon exact ;
- recadrage, recompression, capture d'écran d'une photo, rafale, photo « similaire » → **pas** un doublon exact.

Aucun hash perceptuel, aucune distance d'embeddings, aucune miniature n'intervient dans cette détection.

## 2. Éligibilité (V1)

| Cas | V1 | Raison |
|-----|----|--------|
| Photo simple, une seule ressource `.photo` | éligible | identité complète démontrable |
| Photo modifiée (ressources `.fullSizePhoto` / `.adjustmentData` présentes) | **exclue** | l'image affichée n'est pas l'original comparé ; identité complète non démontrée |
| Live Photo (ressource vidéo associée) | **exclue** | asset composite : il faudrait comparer aussi la vidéo et le lien entre les deux |
| Photo de rafale | **exclue** | composite (série) |
| Photo RAW + JPEG | **exclue** | plusieurs ressources principales |
| Ressource uniquement dans iCloud | « non vérifiable » tant que l'utilisateur n'a pas autorisé le téléchargement pour la vérification | pas de téléchargement silencieux |

L'éligibilité est déterminée à partir de `PHAssetResource.assetResources(for:)` (API documentée), à confirmer sur appareil pour chaque type.

## 3. Algorithme

1. **Regroupement peu coûteux** : (largeur, hauteur, UTI de la ressource principale). Les groupes d'un seul élément sont écartés sans lecture.
2. **Empreinte partielle** : SHA-256 des 64 premiers Kio (`PHAssetResourceManager.requestData`, réseau selon le réglage dédié ; lecture interrompue au-delà de 64 Kio). Sert uniquement à réduire les candidats.
3. **Empreinte complète** : SHA-256 de la totalité (CryptoKit, mise à jour incrémentale par blocs) + nombre exact d'octets. Le nombre d'octets mesuré alimente aussi l'estimation du volume.
4. **Confirmation** : groupe = même (UTI, taille, SHA-256). Avant d'afficher un groupe comme « doublons exacts », vérifier que l'empreinte de modification de chaque photo est inchangée depuis le calcul ; sinon recalculer.
5. **Persistance** : résultats dans `resource_digests` avec la version de la méthode (`exact-sha256-v1`) ; tout changement de méthode invalide les résultats.

Les lectures se font hors du fil principal, avec une concurrence limitée (2 lectures simultanées au plus, à ajuster après mesure), en pause si l'app passe en arrière-plan.

## 4. Présentation et exemplaire conservé

- Un groupe propose toujours de **conserver au moins un exemplaire** ; il est impossible de sélectionner tous les exemplaires d'un groupe depuis l'écran de groupe.
- L'exemplaire suggéré pour la conservation est choisi par une règle **affichée** : favori d'abord, puis celui qui appartient au plus grand nombre d'albums, puis la date de création la plus ancienne. L'utilisateur peut changer ce choix.
- Pour chaque exemplaire : favori, albums d'appartenance (nombre), date. Avertissement : supprimer un exemplaire le retire de ses albums, même si un fichier identique est conservé.
- Les doublons ne sont jamais supprimés automatiquement : ils rejoignent la sélection « À supprimer » comme toute autre décision.

## 5. Réglage iCloud

Deux réglages distincts :
- « Télécharger depuis iCloud pour analyser » (classement, E) ;
- « Télécharger depuis iCloud pour vérifier les doublons » (D), désactivé par défaut, avec mention de la consommation de données.

## 6. Tests prévus

- Unitaires (paquet, Linux) : regroupement, éligibilité, confirmation, invalidation sur changement d'empreinte, règle de suggestion.
- Sur appareil : deux imports identiques d'un même fichier (doivent être groupés) ; même photo en HEIC et JPEG (non) ; photo et sa copie retouchée (non) ; Live Photo dupliquée (exclue) ; photo uniquement iCloud (non vérifiable sans autorisation).
