#!/usr/bin/env bash
# check-upstream.sh - staleness guard for RFTDLifestyleCompanion.
#
# The Companion SHADOWS three files from "Lifestyle: Hobbies" (it ships corrected
# copies that load instead of the originals). Shadowed copies do NOT auto-update
# when the author changes the upstream mod, so before publishing a Companion
# update - or after Lifestyle updates on the Workshop - run this to see whether
# any ported file changed upstream and needs a re-port.
#
# Usage:
#   ./check-upstream.sh [path-to-Lifestyle-mod-lua-root]
#
# Default upstream path is the local Workshop copy. Override with $1 or $LS_LUA.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="$HERE/upstream-snapshot.sha256"

LS_LUA="${1:-${LS_LUA:-d:/Steam/steamapps/workshop/content/108600/3403870858/mods/Lifestyle/common/media/lua}}"

if [[ ! -d "$LS_LUA" ]]; then
    echo "ERROR: Lifestyle lua root not found: $LS_LUA"
    echo "Pass the correct path as the first argument."
    exit 2
fi
if [[ ! -f "$SNAP" ]]; then
    echo "ERROR: snapshot missing: $SNAP"
    exit 2
fi

echo "Upstream: $LS_LUA"
echo "Snapshot: $SNAP"
echo

changed=0
while read -r want file; do
    file="${file#\*}"                       # strip sha256sum's binary marker
    have="$(cd "$LS_LUA" && sha256sum "$file" 2>/dev/null | awk '{print $1}')"
    if [[ -z "$have" ]]; then
        echo "MISSING upstream file: $file  (author removed/renamed it? re-port needed)"
        changed=1
    elif [[ "$have" != "$want" ]]; then
        echo "CHANGED  $file"
        echo "         ported-against: $want"
        echo "         current:        $have"
        changed=1
    else
        echo "OK       $file"
    fi
done < "$SNAP"

echo
if [[ "$changed" -eq 0 ]]; then
    echo "All ported files are current. No action needed."
else
    echo "!! One or more upstream files changed. Re-port the Companion shadow(s),"
    echo "   then refresh the snapshot:"
    echo "     (cd \"$LS_LUA\" && sha256sum server/LSservercommands.lua shared/TimedActions/hooks/Read.lua shared/Helper/TransferHelper.lua) > \"$SNAP\""
    echo "   and bump RDLSShared.UPSTREAM_MODVERSION."
    exit 1
fi
