#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 5 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
mode=$1
jq_bin=$3
case "$mode" in
  empty) ;;
  malformed) /usr/bin/printf '{\n' ;;
  partial) /usr/bin/printf '%s\n' '{"case_id":"reject-partial","payloads":[],"phase":"producer","protocol_version":1}' ;;
  degraded) /usr/bin/printf '%s\n' '{"status":"degraded"}' ;;
  relabelled)
    "$jq_bin" -S -c -n '{case_id:"matrix-aa",payloads:[],phase:"forge",
      protocol_version:1,stage_result:{}}'
    ;;
  timeout) /bin/sleep 5 ;;
  transport) exit 9 ;;
  *) exit 64 ;;
esac
