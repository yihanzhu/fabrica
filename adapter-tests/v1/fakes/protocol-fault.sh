#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 6 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
mode=$1
request=$2
jq_bin=$3
contract=$4
modules=$5
producer_snapshot=$6
case "$mode" in
  empty) ;;
  malformed) /usr/bin/printf '{\n' ;;
  partial) /usr/bin/printf '%s\n' \
    '{"case_id":"matrix-aa","payloads":[],"phase":"producer","protocol_version":1}' ;;
  degraded) /usr/bin/printf '%s\n' '{"status":"degraded"}' ;;
  timeout)
    marker_parent=${TMPDIR%/*}
    marker="${marker_parent%/*}/timeout-survived"
    (trap '' TERM; /bin/sleep 2; /usr/bin/printf survived > "$marker") &
    trap '' TERM
    wait
    ;;
  transport) exit 9 ;;
  relabelled|multiple|unlinked|duplicate|descendant)
    /bin/bash "$producer_snapshot" "$request" "$jq_bin" \
      "$contract" "$modules" > "$HOME/base-response.json"
    case "$mode" in
      relabelled) "$jq_bin" -S -c '.phase="forge"' "$HOME/base-response.json" ;;
      multiple) /bin/cat "$HOME/base-response.json" "$HOME/base-response.json" ;;
      unlinked)
        "$jq_bin" -S -c '.payloads += [{data:"extra",media_type:"text/plain",
          payload_id:"unlinked",sha256:("0"*64)}]' "$HOME/base-response.json"
        ;;
      duplicate) "$jq_bin" -S -c '.payloads += [.payloads[0]]' "$HOME/base-response.json" ;;
      descendant)
        marker_parent=${TMPDIR%/*}
        marker="${marker_parent%/*}/descendant-survived"
        (trap '' TERM; /bin/sleep 2; /usr/bin/printf survived > "$marker") &
        /bin/cat "$HOME/base-response.json"
        ;;
    esac
    ;;
  *) exit 64 ;;
esac
