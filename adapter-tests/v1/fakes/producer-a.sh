#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 4 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
request=$1 jq_bin=$2 contract=$3 modules=$4
"$jq_bin" -L "${contract%/*}" -L "$modules" -e --arg command request-envelope \
  -f "$contract" "$request" >/dev/null
"$jq_bin" -S -c '.stage_request' "$request" > "$HOME/stage-request.json"
"$jq_bin" -j '.payloads[] | select(.payload_id=="resolved-profile") | .data' \
  "$request" > "$HOME/resolved.json"
/usr/bin/printf '%s\n' \
  'diff --git a/source.txt b/source.txt' \
  '--- a/source.txt' \
  '+++ b/source.txt' \
  '@@ -1,2 +1,3 @@' \
  ' project = moon-garden' \
  ' feature = portable greeting' \
  '+result = portable candidate' > "$HOME/producer.patch"
patch_sha=$(/usr/bin/shasum -a 256 "$HOME/producer.patch" | /usr/bin/awk '{print $1}')
request_sha=$(/usr/bin/shasum -a 256 "$HOME/stage-request.json" | /usr/bin/awk '{print $1}')
resolved_sha=$(/usr/bin/shasum -a 256 "$HOME/resolved.json" | /usr/bin/awk '{print $1}')
"$jq_bin" -S -c -n --slurpfile stage_request "$HOME/stage-request.json" \
  --slurpfile resolved "$HOME/resolved.json" --arg case_id "$("$jq_bin" -r '.case_id' "$request")" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" --arg payload_sha "$patch_sha" \
  '{case_id:$case_id,phase:"producer",stage_request:$stage_request[0],request_sha:$request_sha,
    resolved_profile:$resolved[0],resolved_sha:$resolved_sha,output_id:"producer.patch",
    media_type:"text/x-diff",payload_sha:$payload_sha}' > "$HOME/result-context.json"
"$jq_bin" -L "${contract%/*}" -L "$modules" -S -c --arg command stage-result \
  -f "$contract" "$HOME/result-context.json" > "$HOME/stage-result.json"
"$jq_bin" -S -c -n --slurpfile result "$HOME/stage-result.json" \
  --rawfile patch "$HOME/producer.patch" --arg case_id "$("$jq_bin" -r '.case_id' "$request")" \
  --arg patch_sha "$patch_sha" '
  {case_id:$case_id,payloads:[{data:$patch,media_type:"text/x-diff",
    payload_id:"producer.patch",sha256:$patch_sha}],phase:"producer",protocol_version:1,
    stage_result:$result[0]}'
