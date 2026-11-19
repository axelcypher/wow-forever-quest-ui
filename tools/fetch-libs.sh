#!/usr/bin/env bash
# Holt die Bibliotheken für das Minimap-Symbol nach ForeverQuestUI/Libs (wie tools/fetch-libs.ps1).
# Entspricht den externals in .pkgmeta; alle drei Stellen zusammen ändern.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
libs="$root/ForeverQuestUI/Libs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ace3_url="https://github.com/WoWUIDev/Ace3"
ldb_url="https://github.com/tekkub/libdatabroker-1-1"
dbicon_url="https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0"

# Neuester Tag eines Git-Repos (wie "tag: latest" im Packager)
latest_tag() {
	# sed liest alles bis zum Ende, damit git nicht an SIGPIPE scheitert (pipefail).
	git ls-remote --tags --refs --sort=-v:refname "$1" "$2" | sed -n '1s#.*refs/tags/##p'
}

fresh() {
	rm -rf "$libs/$1"
	mkdir -p "$libs/$1"
}

# LibStub und CallbackHandler-1.0 aus Ace3, mit Lizenz
tag="$(latest_tag "$ace3_url" 'Release-r*')"
[ -n "$tag" ] || { echo "Konnte keinen Ace3-Release-Tag finden." >&2; exit 1; }
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$ace3_url" "$tmp/Ace3"
for name in LibStub CallbackHandler-1.0; do
	fresh "$name"
	cp -R "$tmp/Ace3/$name/." "$libs/$name/"
	cp "$tmp/Ace3/LICENSE.txt" "$libs/$name/"
done
echo "Ace3 $tag -> Libs/LibStub, Libs/CallbackHandler-1.0"

# LibDataBroker-1.1 (keine eigene Lizenzdatei, die README geht mit)
tag="$(latest_tag "$ldb_url" 'v*')"
[ -n "$tag" ] || { echo "Konnte keinen LibDataBroker-Tag finden." >&2; exit 1; }
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$ldb_url" "$tmp/ldb"
fresh LibDataBroker-1.1
cp "$tmp/ldb/LibDataBroker-1.1.lua" "$tmp/ldb/README.textile" "$libs/LibDataBroker-1.1/"
echo "LibDataBroker-1.1 $tag -> Libs/LibDataBroker-1.1"

# LibDBIcon-1.0: der SVN-Server liefert einzelne Dateien auch per HTTP aus, svn ist also nicht nötig.
fresh LibDBIcon-1.0
for file in LibDBIcon-1.0.lua lib.xml; do
	curl -fsSL "$dbicon_url/$file" -o "$libs/LibDBIcon-1.0/$file"
done
rev="$(curl -fsSL "$dbicon_url/" | sed -n 's/.*Revision \([0-9]*\).*/r\1/p' | head -n 1)"
minor="$(sed -n 's/.*DBICON10_MINOR = \([0-9]*\).*/\1/p' "$libs/LibDBIcon-1.0/LibDBIcon-1.0.lua" | head -n 1)"
echo "LibDBIcon-1.0 ${rev:-trunk} (MINOR ${minor:-?}) -> Libs/LibDBIcon-1.0"
