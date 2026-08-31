#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 5 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
mode=$1
request=$2
jq_bin=$3
contract=$4
modules=$5
case "$mode" in
  empty) ;;
  malformed) /usr/bin/printf '{\n' ;;
  partial) /usr/bin/printf '%s\n' \
    '{"case_id":"matrix-aa","payloads":[],"phase":"producer","protocol_version":1}' ;;
  degraded) /usr/bin/printf '%s\n' '{"status":"degraded"}' ;;
  timeout) /bin/sleep 5 ;;
  transport) exit 9 ;;
  relabelled|multiple|unlinked|duplicate)
    /bin/bash "${BASH_SOURCE[0]%/*}/producer-a.sh" "$request" "$jq_bin" \
      "$contract" "$modules" > "$HOME/base-response.json"
    case "$mode" in
      relabelled) "$jq_bin" -S -c '.phase="forge"' "$HOME/base-response.json" ;;
      multiple) /bin/cat "$HOME/base-response.json" "$HOME/base-response.json" ;;
      unlinked)
        "$jq_bin" -S -c '.payloads += [{data:"extra",media_type:"text/plain",
          payload_id:"unlinked",sha256:("0"*64)}]' "$HOME/base-response.json"
        ;;
      duplicate) "$jq_bin" -S -c '.payloads += [.payloads[0]]' "$HOME/base-response.json" ;;
    esac
    ;;
  *) exit 64 ;;
esac
