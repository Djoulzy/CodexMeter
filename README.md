# Codex Meter

Application macOS native en SwiftUI pour suivre les tokens des sessions Codex locales, les attribuer à des clients et exporter les événements en CSV.

## Utilisation

Ouvrir **Codex Meter.app**. Le premier lancement lit les sessions existantes ; les suivants reprennent depuis le cache.

1. Dans **Clients**, associer un dossier de projet à un client. Les règles s’appliquent aussi à l’historique ; la règle dont le chemin est le plus précis gagne.
2. Dans **Vue d’ensemble**, choisir une période et une répartition par client, dépôt/dossier ou modèle. La recherche filtre également l’export.
3. Facultativement, dans **Réglages**, ajouter les modèles détectés et saisir une grille en euros par million de tokens, puis enregistrer les tarifs. Zéro est une valeur explicite ; l’absence de tarif affiche un tiret.
4. **Exporter CSV** enregistre les événements de la sélection, avec dates UTC, client, dossier, dépôt, modèle, identifiants et compteurs. Les jours du graphique utilisent le fuseau horaire du Mac.

Le suivi continue tant que l’application est ouverte. Il peut être suspendu dans la barre latérale. Il n’installe ni agent de démarrage ni service en arrière-plan.

## Compilation

Pré-requis : macOS 14 ou supérieur, Xcode avec Swift 6. Aucune dépendance tierce, aucun accès réseau requis.

Ouvrir `Package.swift` avec Xcode pour développer, ou exécuter dans le dossier du projet :

```sh
bash build-app.sh
```

Le script produit `Codex Meter.app`, pour l’architecture du Mac qui compile. La version livrée est compilée pour Apple Silicon et signée localement (signature ad hoc), sans notarisation de distribution.

Pour les tests :

```sh
swift test
```

Les tests couvrent les différences de cumuls, répétitions, remises à zéro, double représentation d’une réponse, règles de dossiers, calcul hors cache, export CSV, lignes partielles, redémarrage, copies de fichiers et troncature.

Test facultatif sur les sessions du Mac, en lecture seule ; le cache de test est temporaire :

```sh
CODEXMETER_VERIFY_HOME="$HOME/.codex" swift test
```

## Lecture et stockage

Sources lues : `sessions/**/*.jsonl` et `archived_sessions/**/*.jsonl` sous le dossier `.codex` choisi. `CODEX_HOME` est pris en compte au premier lancement s’il existe dans l’environnement. L’app ne lit pas `auth.json`, les cookies, les bases d’authentification, les logs de VS Code ni les conversations via une API.

Le parseur traverse nécessairement les lignes des fichiers de session, mais ne conserve que les métadonnées autorisées. Aucun contenu de conversation n’est enregistré dans le cache ou exporté.

L’app écrit exclusivement ses propres données dans `~/Library/Application Support/CodexMeter/` :

- `settings.json` : source, règles clients et tarifs.
- `ledger-v1.json` : événements de consommation, métadonnées et positions de lecture ; aucun secret ni contenu de message.

La variable facultative `CODEXMETER_DATA_DIR` permet de placer ces fichiers dans un autre dossier (utile pour les essais).

Le scan tourne hors du thread de l’interface, toutes les deux secondes après le scan précédent. Seules les nouvelles lignes terminées sont interprétées. Les positions et événements sont sauvegardés ensemble, de façon atomique. Un fichier tronqué ou remplacé provoque une reconstruction ; une session supprimée reste dans le cache jusqu’à une relecture complète demandée dans les réglages.

## Comptabilisation

- Événements modernes `token_usage_record` : somme de `usage`, avec déduplication globale par `response_id`.
- Événements anciens `event_msg/token_count` : différences de `total_token_usage`, répétitions ignorées. Lors d’une baisse, `last_token_usage` sert d’estimation du nouvel apport ; à défaut, le nouveau cumul est utilisé.
- Les miroirs anciens qui suivent un événement moderne sont ignorés après mise à jour du cumul de référence. La comparaison utilise le cumul moderne et, à défaut, soustrait les consommations modernes déjà enregistrées.
- Les anciens événements sont dédupliqués par horodatage, identifiant de tour (ou session si absent) et cumul. Les copies d’historiques dépourvues d’identifiants stables peuvent nécessiter une vérification manuelle.
- `input_tokens` inclut `cached_input_tokens`. `total = input + output`. Le raisonnement est conservé séparément et n’est pas ajouté à nouveau au total.
- Coût estimé : `(entrée − cache) × tarif entrée + cache × tarif cache + sortie × tarif sortie`, divisé par un million. `cache_write_input_tokens` est conservé et exporté, sans tarification spécifique dans cette version.
- L’app rattache chaque événement au modèle et au dossier du contexte courant. Le dépôt est trouvé par remontée vers `.git`. Les worktrees sont regroupés via `commondir`, sans lire les URL distantes ni lancer de commande Git.
- Les sous-agents sont identifiés dans `session_meta.source` et exclus par défaut ; ils peuvent être inclus explicitement.

## Limites

Ces formats locaux internes peuvent évoluer. Le suivi est actualisé après l’écriture des compteurs par Codex ; il ne mesure pas les tokens en cours de génération avant leur enregistrement. Les lignes invalides sont signalées ; une dernière ligne incomplète est attendue au passage suivant.

L’app ne garantit pas une équivalence avec les crédits ou factures ChatGPT Business. Les compteurs anciens, les remises à zéro, les copies sans identifiants et les sessions absentes de ce Mac peuvent rendre le résultat incomplet. Les modèles sont attribués à partir du contexte enregistré ; une tarification officielle peut utiliser d’autres critères. Les formats futurs et les sessions exécutées sur une autre machine exigent une adaptation ou un import.

En cas d’erreur d’enregistrement des réglages ou du cache, l’interface l’indique. Une relecture complète remplace le cache uniquement, jamais les données Codex.
