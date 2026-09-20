# rtorrent-flood

Image Docker combinée "tout en un" (rTorrent + Flood UI), sur le modèle de l'ancienne
`jesec/rtorrent-flood` — mais **maintenue ici**, basée sur `rakshasa/rtorrent`+`libtorrent`
(l'upstream d'origine, **activement maintenu**), au lieu du fork `jesec/rtorrent` (gelé depuis
juillet 2023, cf. [jesec/flood#1139](https://github.com/jesec/flood/issues/1139)).

`jesec` a abandonné la publication de l'image combinée en juin 2026
([jesec/flood#1138](https://github.com/jesec/flood/pull/1138)) — `jesec/rtorrent-flood:4.14.2`
restera pour toujours la dernière version. Ce dépôt reprend ce rôle, mais avec un cœur rTorrent
qui continue de recevoir des correctifs.

## Build

```sh
docker build -t rtorrent-flood:<rtorrent-version>-<flood-version> \
  --build-arg RTORRENT_VERSION=v0.16.23 --build-arg FLOOD_VERSION=4.16.2 .
```

Un seul `docker build` fait tout : clone rakshasa/rtorrent + rakshasa/libtorrent au tag donné,
build autotools, assemblage avec l'image officielle `jesec/flood:<version>`. Pas d'étape
préalable côté hôte — pensé pour tourner tel quel en CI.

**`RTORRENT_VERSION` doit être le même tag pour rtorrent et libtorrent** (contrainte dure,
`configure.ac` de rtorrent vérifie `libtorrent >= <version>` au build). Voir les tags disponibles :
`git ls-remote --tags https://github.com/rakshasa/rtorrent.git`.

**`FLOOD_VERSION`** : tags semver précis sur Docker Hub (`jesec/flood`) et ghcr.io, ex `4.16.2`.

## Comment ça marche

Flood a un mécanisme **intégré à l'app** (pas un hack Docker) qui spawn `rtorrent` comme process
enfant quand `FLOOD_OPTION_RTORRENT=true` est actif (`config.ts`,
`spawn('rtorrent', ['-o', 'system.daemon.set=true'])` sur le `PATH`) — `FLOOD_OPTION_RTCONFIG`
pointe vers le `rtorrent.rc` à importer. C'est exactement ce que faisait l'ancien
`Dockerfile.rtorrent` de jesec, avec le binaire rakshasa à la place du binaire jesec.

`cleanup-rtorrent.sh` (à bind-monter en entrypoint custom, voir déploiement) injecte le port
forwardé par gluetun/ProtonVPN dans `rtorrent.rc` avant chaque démarrage, et crée les répertoires
de travail (le namespace `fs.*` n'existe plus côté rakshasa, cf. plus bas).

## rTorrent : rakshasa vs jesec — ce qui a changé

Le cœur a divergé significativement depuis le gel de jesec en 2023 (grosse refonte
polling/threading fin 2025 côté rakshasa). Renommages/suppressions de commandes RPC identifiés en
portant `rtorrent.rc` (liste probablement non exhaustive — à enrichir si un nouveau cas apparaît) :

| jesec (ancien) | rakshasa (actuel) | Note |
|---|---|---|
| `network.port_range.set` | `network.listen.port.range.set` | pas d'alias de rétrocompat |
| `network.port_random.set` | `network.listen.port.random.set` | idem |
| `network.http.max_open.set` | `network.http.max_total_connections.set` | l'ancien nom existe mais seulement derrière `-D` (deprecated), inutilisable ici car Flood spawn rtorrent sans ce flag |
| `schedule2 = name, first, interval, cmd` | `schedule = name, first, interval, cmd` | même signature 4 arguments, juste renommé |
| `dht.add_bootstrap = host:port` | `dht.add_node = host:port` | même signature |
| `fs.homedir` | `(system.env,HOME)` | namespace `fs.*` retiré entièrement |
| `fs.mkdir` / `fs.mkdir.recursive` | *(rien)* | créer les dossiers côté shell (`cleanup-rtorrent.sh`) |
| `encoding.add = utf8` | *(rien)* | aucun remplaçant trouvé dans le code — UTF-8 semble natif désormais |

Tout le reste (`session.path.set`, `directory.default.set`, `dht.mode.set`, `dht.port.set`,
`network.scgi.open_port`, `system.daemon.set`, `throttle.*`, `network.max_open_files.set`,
`network.max_open_sockets.set`, `pieces.memory.max.set`, `protocol.pex.set`,
`network.bind_address.set`, `log.*`, `print`, `trackers.numwant.set`, `session.use_lock.set`) est
**identique**, vérifié dans le code source (`src/command_*.cc`).

**Flag `-D` (« Enable deprecated commands »)** : restaure `schedule2`, `port_random`, `dht`
(alias court) et quelques autres — **mais inutilisable ici**, Flood spawn rtorrent avec des
arguments fixes (`-o system.daemon.set=true`) qui n'incluent pas `-D`. D'où la nécessité de
corriger chaque directive plutôt que de compter dessus.

### Nouveau comportement (pas un renommage) : annonces tracker en double pile IPv4+IPv6

Contrairement à jesec (qui n'a aucune logique de sélection de famille d'adresse dans son code
tracker HTTP), rakshasa tente par défaut **IPv4 puis IPv6 en repli** pour chaque annonce tracker
(`TrackerHttp::request_families()`, `src/tracker/tracker_http.cc`), sauf si l'un des deux est
explicitement bloqué. Dans un environnement où IPv6 est coupé au niveau noyau (ex. conteneur VPN
avec `sysctl net.ipv6.conf.all.disable_ipv6=1`, cas de ce déploiement derrière gluetun), ce repli
échoue systématiquement avec `Bind address for requested IP protocol(s) not available.` — visible
dans le statut tracker de Flood sous la forme `v6 : ...`. **Inoffensif en soi** (l'annonce IPv4
reste tentée en priorité), mais bruyant et trompeur si on ne sait pas que c'est nouveau. Pour le
supprimer si IPv6 n'est de toute façon pas disponible :

```
network.block.ipv6.set = yes
```

(commande absente de jesec — nouvelle avec la refonte réseau 2025 de rakshasa, cf aussi
`network.block.ipv4`/`network.block.ipv4in6`/`network.prefer.ipv6`).

## Patches

**Aucun.** Contrairement à l'ancien chantier de patch sur le fork jesec (2 correctifs manuels :
SIGILL, bug DHT `get_random_id`), rakshasa n'a besoin d'aucun des deux : le bug DHT n'y a jamais
existé (l'algo cassé est une "optimisation" jesec de 2022 jamais mergée en amont), et la zone du
SIGILL a été entièrement réécrite (le pattern fautif n'existe plus structurellement).
