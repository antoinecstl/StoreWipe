# Parcours et écrans

Statuts : ✅ implémenté (logique testée hors Xcode) · 🟡 implémenté, interface non compilée dans cet environnement · ⬜ à faire (incrément indiqué).

## 1. Parcours

### Première ouverture
1. Écran d'accueil de bienvenue : trois principes (geste, traitement local, rien n'est supprimé sans vous). 🟡
2. « Commencer » déclenche la demande d'accès système — jamais avant. 🟡
3. Selon la réponse : accès complet → accueil ; accès limité → accueil avec bandeau « Accès limité » ; refus → écran explicatif avec « Ouvrir les Réglages » ; restreint → écran explicatif sans action possible. 🟡
4. L'indexation démarre en arrière-plan, les photos les plus récentes d'abord : le tri peut commencer dès le premier lot. ✅ (logique) 🟡 (interface)

Pas de questionnaire. Les catégories d'analyse auront des valeurs par défaut (incrément E).

### Session de tri
1. Accueil → « Commencer le tri » (ou « Reprendre le tri »). 🟡
2. La photo occupe l'écran ; date, indices factuels (favori, capture d'écran, Live Photo, rafale, « passée le… ») et progression sont affichés. 🟡
3. Swipe droite = conserver ; gauche = à supprimer ; boutons Conserver / À supprimer / Passer / Annuler en bas d'écran. ✅ / 🟡
4. Zoom par pincement ou double-tap ; tant que la photo est zoomée, un glissement déplace l'image et ne peut pas valider de décision. 🟡
5. « Terminer » met la session en pause (bilan, progression enregistrée) ; la fermeture de l'app aussi. ✅
6. Quand la pile est vide : bilan, « Revoir les photos passées », « Retour à l'accueil », « Annuler la dernière décision ». ✅ / 🟡

### Reprise
- « Reprendre le tri » rouvre la session active sur la photo exacte où elle s'était arrêtée, y compris après une fermeture forcée ; la pile d'annulation est restaurée. ✅
- Les photos ajoutées depuis sont proposées après celles qui restaient. ✅

### Tri par mois
- Liste des mois (photos, restant à trier, « Trié ») ; un mois = une session courte. ✅ / 🟡
- Appui long ou balayage : « Revoir les conservées » du mois. 🟡

### Permissions et changements
| Situation | Comportement |
|-----------|--------------|
| Accès limité | Bandeau + « Modifier la sélection » (sélecteur système) ; seules les photos autorisées sont indexées. 🟡 |
| Photo retirée de la sélection | Masquée des piles, décision **conservée** ; elle réapparaît si elle est de nouveau autorisée. ✅ |
| Passage limité → complet | Toutes les photos réapparaissent, décisions intactes. ✅ |
| Accès retiré dans Réglages | Écran d'accès refusé ; aucune donnée n'est effacée. ✅ / 🟡 |
| Autorisation modifiée pendant l'indexation | La passe est recommencée, aucune réconciliation n'est appliquée. ✅ |
| Photo supprimée dans Photos (accès complet) | Absence confirmée par PhotoKit → données locales effacées. ✅ |
| Photo masquée dans Photos | Traitée comme inaccessible, pas comme supprimée. ✅ |

### Sélection à supprimer (incrément C) ⬜
Grille des photos « À supprimer » ; ouverture de chaque photo ; retirer de la sélection (= conserver) ; groupes de doublons ; « Supprimer N photos » → explication iCloud → confirmation iOS → résultat réel (annulation, échec partiel, photos disparues entre-temps).

## 2. Écrans

| Écran | Rôle | Statut |
|-------|------|--------|
| Bienvenue | Principes + demande d'accès au bon moment | 🟡 |
| Accès refusé / restreint | Explication + Réglages | 🟡 |
| Accueil | Action principale, raccourcis, sélection en attente, progression discrète de l'indexation | 🟡 |
| Trier par mois | Sessions par période | 🟡 |
| Tri (swipe) | Photo, gestes, boutons, zoom, progression | 🟡 |
| Bilan de session | Compteurs réels, suites possibles | 🟡 |
| Réglages | Confidentialité, accès, iCloud, réinitialisation, version | 🟡 |
| Détails sur vos données | Flux de données en clair | 🟡 |
| Sélection à supprimer | Revue + suppression système | ⬜ C |
| Groupe de doublons | Exemplaires, choix visible de celui conservé | ⬜ D |
| Catégories de nettoyage | Piles par catégorie, raison affichée | ⬜ E |
| Suivi de l'analyse | Progression, pause, iCloud, réseau | ⬜ E |

## 3. Textes de référence (français)

Les textes sont dans le code source (clés extraites automatiquement par Xcode vers `Localizable.xcstrings`, langue source : français). Les accords de pluriel sont définis dans le catalogue.

| Contexte | Texte |
|----------|-------|
| Bienvenue | « Faites le tri dans vos photos » · « Un geste par photo » · « Tout reste sur votre iPhone » · « Rien n'est supprimé sans vous » |
| Demande d'accès (système) | « PhotoSwipe affiche vos photos pour vous aider à les trier et ne supprime que celles que vous avez sélectionnées, après votre confirmation. Les photos restent sur votre appareil. » |
| Accès refusé | « Pour trier votre photothèque, autorisez l'accès à toutes vos photos ou à une sélection dans Réglages > PhotoSwipe > Photos. » |
| Accès restreint | « L'accès aux photos est bloqué sur cet appareil (contrôle parental ou gestion par une organisation). » |
| Accès limité | « PhotoSwipe ne voit que les photos que vous avez autorisées. » |
| Accueil vide | « Aucune photo » / « Aucune photo autorisée » / « Tout est trié » |
| Indexation | « Lecture de la photothèque… N photos lues » |
| Photo iCloud | « Photo stockée dans iCloud — Elle n'est pas disponible sur cet iPhone. Le téléchargement peut utiliser des données mobiles. » |
| Photo disparue | « Photo introuvable — Elle a peut-être été supprimée ou n'est plus autorisée. » |
| Sauvegarde impossible | « La dernière décision n'a pas pu être enregistrée. La photo vous est de nouveau proposée. » |
| Bilan | « Rien n'a été supprimé : les photos à supprimer attendent votre confirmation dans la sélection. » |
| Réinitialiser | « Les photos conservées, passées et sélectionnées pour suppression redeviendront non triées. Vos photos ne sont pas modifiées. » |
| Effacer les données | « Décisions, progression, index et réglages seront effacés de cet iPhone. Aucune photo n'est supprimée. » |
| Suppression (C, prévu) | « Ces photos seront placées dans « Supprimés récemment » de Photos. Si Photos iCloud est activé, elles seront aussi supprimées de vos autres appareils. » |

## 4. Accessibilité (appliquée dès l'incrément B)

- Toutes les actions de swipe existent en boutons, en actions VoiceOver sur la photo et en raccourcis clavier (← → ↓ ⌘Z).
- Étiquettes de décision avec texte + icône (jamais la couleur seule) ; contraste du texte blanc ≥ 5:1 sur les couleurs de décision.
- Dynamic Type : boutons dimensionnés avec `@ScaledMetric`, plafonnés pour rester sur une ligne.
- Réduction des animations : pas de rotation ni d'envol de la carte, décision immédiate.
- Retours haptiques discrets : franchissement du seuil, décision validée.
