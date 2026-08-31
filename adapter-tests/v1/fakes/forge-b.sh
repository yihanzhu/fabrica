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
"$jq_bin" -j '.payloads[] | select(.payload_id=="source") | .data' "$request" > "$HOME/source.txt"
"$jq_bin" -j '.payloads[] | select(.payload_id=="producer.patch") | .data' "$request" > "$HOME/producer.patch"
patch_sha=$(/usr/bin/shasum -a 256 "$HOME/producer.patch" | /usr/bin/awk '{print $1}')
candidate="$HOME/candidate"
/bin/mkdir -m 700 "$candidate"
/usr/bin/git init -q "$candidate"
/bin/cp "$HOME/source.txt" "$candidate/source.txt"
/usr/bin/git -C "$candidate" add source.txt
/usr/bin/git -C "$candidate" commit -q -m source
/usr/bin/git -C "$candidate" apply --index "$HOME/producer.patch"
/usr/bin/git -C "$candidate" commit -q -m candidate
commit_id=$(/usr/bin/git -C "$candidate" rev-parse HEAD)
tree_id=$(/usr/bin/git -C "$candidate" rev-parse 'HEAD^{tree}')
object_id=$(/usr/bin/git -C "$candidate" rev-parse HEAD:source.txt)
source_tree=$("$jq_bin" -r '.stage_request.body.inputs[] | select(.input_id=="input.source-tree") | .value.value.value.object_id' "$request")
"$jq_bin" -S -c -n --arg source_tree "$source_tree" --arg patch "$patch_sha" \
  --arg commit "$commit_id" --arg tree "$tree_id" --arg object "$object_id" '
  {candidate_commit_id:$commit,candidate_object_id:$object,candidate_tree_id:$tree,
   patch_sha256:$patch,source_tree_id:$source_tree}' > "$HOME/receipt.json"
receipt_sha=$(/usr/bin/shasum -a 256 "$HOME/receipt.json" | /usr/bin/awk '{print $1}')
request_sha=$(/usr/bin/shasum -a 256 "$HOME/stage-request.json" | /usr/bin/awk '{print $1}')
resolved_sha=$(/usr/bin/shasum -a 256 "$HOME/resolved.json" | /usr/bin/awk '{print $1}')
"$jq_bin" -S -c -n --slurpfile stage_request "$HOME/stage-request.json" \
  --slurpfile resolved "$HOME/resolved.json" --arg case_id "$("$jq_bin" -r '.case_id' "$request")" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" --arg payload_sha "$receipt_sha" \
  '{case_id:$case_id,phase:"forge",stage_request:$stage_request[0],request_sha:$request_sha,
    resolved_profile:$resolved[0],resolved_sha:$resolved_sha,output_id:"candidate.repository",
    media_type:"application/json",payload_sha:$payload_sha}' > "$HOME/result-context.json"
"$jq_bin" -L "${contract%/*}" -L "$modules" -S -c --arg command stage-result \
  -f "$contract" "$HOME/result-context.json" > "$HOME/stage-result.json"
"$jq_bin" -S -c -n --slurpfile result "$HOME/stage-result.json" --rawfile receipt "$HOME/receipt.json" \
  --arg case_id "$("$jq_bin" -r '.case_id' "$request")" --arg receipt_sha "$receipt_sha" '
  {case_id:$case_id,payloads:[{data:$receipt,media_type:"application/json",
    payload_id:"candidate.repository",sha256:$receipt_sha}],phase:"forge",protocol_version:1,
    stage_result:$result[0]}'
