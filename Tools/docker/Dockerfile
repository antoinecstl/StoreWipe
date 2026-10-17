# Image de test du paquet PhotoSwipeKit sous Linux (aucun Xcode requis).
# Swift 6.2 officiel + en-têtes SQLite (le module CSQLite remplace SQLite3 hors plateformes Apple).
FROM swift:6.2-noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
