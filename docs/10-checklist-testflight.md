# Checklist TestFlight puis App Store

À dérouler avant chaque envoi. Les points cochés ([x]) sont déjà couverts par le dépôt ; les autres demandent une action sur Mac, sur appareil ou dans App Store Connect.

## Projet et signature
- [x] Aucun certificat, profil, clé ni identifiant d'équipe dans le dépôt (`Config/Local.xcconfig` ignoré).
- [ ] `Config/Local.xcconfig` créé avec `DEVELOPMENT_TEAM` et `PHOTOSWIPE_BUNDLE_ID_PREFIX`.
- [ ] Identifiant de bundle réservé dans le portail développeur ; nom d'app disponible dans App Store Connect (le nom « PhotoSwipe » est provisoire et non vérifié).
- [ ] Compilation avec la version de Xcode/SDK exigée par Apple au moment de l'envoi.
- [ ] `MARKETING_VERSION` et `CURRENT_PROJECT_VERSION` incrémentés.
- [ ] Archive Release sans avertissement de concurrence non traité.

## Contenu et métadonnées
- [x] Icône 1024 × 1024 sans transparence (provisoire, à remplacer par un visuel définitif).
- [x] Texte d'autorisation Photos explicite (`NSPhotoLibraryUsageDescription`).
- [x] `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` (l'app propose sa propre gestion de la sélection).
- [x] Manifeste de confidentialité (`PrivacyInfo.xcprivacy`).
- [x] `ITSAppUsesNonExemptEncryption = false`.
- [ ] Questionnaire App Privacy : « Données non collectées ».
- [ ] URL de politique de confidentialité publiée (reprendre [confidentialité](08-confidentialite.md)).
- [ ] Captures d'écran iPhone (tailles exigées) — utiliser le mode démonstration pour ne montrer aucune photo personnelle.
- [ ] Description sans promesse non mesurée (pas de « libère X Go », pas de taux de précision non publié).

## Notes pour la revue App Review
- [ ] Expliquer : l'app ne supprime rien par swipe ; la suppression passe par la sélection, une confirmation dans l'app puis l'alerte système iOS ; les photos vont dans « Supprimés récemment ».
- [ ] Préciser que tout le traitement est local et qu'aucun compte n'est requis.
- [ ] Indiquer comment tester avec peu de photos (le simulateur ou un appareil de test avec quelques photos suffit).

## Tests obligatoires sur appareil réel (iPhone 12 ou 13 minimum)
- [ ] Première ouverture : accès complet, limité, refusé ; changement dans Réglages puis retour dans l'app.
- [ ] Session : swipe, boutons, annulation, zoom sans décision accidentelle, fermeture forcée puis reprise sur la même photo.
- [ ] Photothèque de plusieurs milliers de photos : durée d'indexation, fluidité pendant l'indexation, mémoire (Instruments).
- [ ] Photos uniquement iCloud : affichage avec réseau, sans réseau, réglage désactivé.
- [ ] Suppression (dès l'incrément C) : annulation dans l'alerte iOS, suppression partielle, photo supprimée entre-temps.
- [ ] VoiceOver, Dynamic Type maximal, mode sombre, réduction des animations, Contrôle de sélection.
- [ ] Mode avion : aucune fonction de tri ne dépend du réseau.

## TestFlight
- [ ] Groupe de testeurs internes, puis externes (revue bêta).
- [ ] Questionnaire testeurs : compréhension du swipe (« le swipe supprime-t-il la photo ? »), confiance, temps passé, catégories utiles.
- [ ] Collecte des retours via TestFlight uniquement (pas de SDK d'analyse).
