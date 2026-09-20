#!/command/with-contenv sh
set -e

echo "[rtorrent-init] attente du port forwarded..."
until [ -s /tmp/gluetun/forwarded_port ]; do
  sleep 2
done

PORT=$(cat /tmp/gluetun/forwarded_port)
BASEDIR="/home/download/.local/share/rtorrent"
SESSION="$BASEDIR/.session"
echo "[rtorrent-init] port trouvé: $PORT"

# fs.mkdir.recursive/fs.mkdir n'existent plus côté rakshasa (namespace fs.*
# retiré) : on crée les répertoires nous-mêmes avant de lancer rtorrent.
mkdir -p "$BASEDIR/download" "$BASEDIR/log" "$SESSION" "$BASEDIR/watch/load" "$BASEDIR/watch/start"

grep -q "network.listen.port.range.set" /etc/rtorrent/rtorrent.rc || {
  echo "[rtorrent-init] ERREUR: pattern non trouvé dans rtorrent.rc"
  exit 1
}

# Écrire dans /tmp puis réinjecter par redirection (cp busybox échoue avec
# "File exists" sur un fichier bind-monté : il tente un create/rename là où
# GNU cp se contente d'ouvrir+tronquer. La redirection shell fait toujours
# un open(O_TRUNC), donc marche identiquement sur les deux.
cp /etc/rtorrent/rtorrent.rc /tmp/rtorrent.rc.tmp
sed "s/^network.listen.port.range.set.*/network.listen.port.range.set = $PORT-$PORT/" /tmp/rtorrent.rc.tmp > /tmp/rtorrent.rc.new
cat /tmp/rtorrent.rc.new > /etc/rtorrent/rtorrent.rc
rm /tmp/rtorrent.rc.tmp /tmp/rtorrent.rc.new

if [ -d "$SESSION" ]; then
  find "$SESSION" -type f \( -name "*.lock" -o -name "*.lck" -o -name "*.pid" \) -delete
fi

echo "[rtorrent-init] session nettoyée"