#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
umask 077

assembly_error() {
  case "$1" in
    E_USAGE|E_RUNTIME) printf '%s\n' "$1" >&2 ;;
    *) printf '%s\n' E_RUNTIME >&2 ;;
  esac
  return 1
}

assembly_accounted=false
assembly_scratch_root=''
assembly_byte_budget=0
assembly_finalizing=false
assembly_receipt_emitted=false
assembly_finalization_signal=''

assembly_emit_receipt() {
  local receipt_status=0
  [ "$assembly_accounted" = true ] || return 0
  [ "$assembly_receipt_emitted" = false ] || return 0
  assembly_finalizing=true
  printf 'written-bytes:%s\n' \
    "${PORTABLE_CORE_INGRESS_WRITTEN_BYTES:-0}" \
    2>/dev/null >&3 || receipt_status=$?
  if [ "$receipt_status" -eq 0 ]; then
    assembly_receipt_emitted=true
  fi
  assembly_finalizing=false
  [ "$receipt_status" -eq 0 ] || return 1
  [ -z "$assembly_finalization_signal" ] || return 2
}

assembly_cleanup() {
  local status=$?
  local receipt_status=0
  trap - EXIT
  if [ "$(type -t portable_core_ingress_close 2>/dev/null)" = function ]; then
    portable_core_ingress_close >/dev/null 2>&1 || :
  fi
  assembly_emit_receipt || receipt_status=$?
  [ "$receipt_status" -eq 0 ] || status=1
  [ -z "$assembly_finalization_signal" ] || status=1
  trap - HUP INT TERM
  exit "$status"
}

assembly_signal() {
  if [ -n "${PORTABLE_CORE_INGRESS_RESERVED_BYTES:-}" ]; then
    # shellcheck disable=SC2034
    PORTABLE_CORE_INGRESS_DEFERRED_SIGNAL="$1"
    return 0
  fi
  if [ "$assembly_finalizing" = true ]; then
    assembly_finalization_signal="$1"
    return 0
  fi
  exit 1
}

if [ "${1:-}" = --accounted-validation ]; then
  if [ "$#" -lt 4 ] ||
     [[ ! "${3:-}" =~ ^(0|[1-9][0-9]*)$ ]] ||
     [ "${#3}" -gt 9 ] || [ "$3" -gt 536870912 ] ||
     ! { : >&3; } 2>/dev/null; then
    assembly_error E_USAGE
    exit 1
  fi
  assembly_accounted=true
  assembly_scratch_root="$2"
  assembly_byte_budget="$3"
  shift 3
  trap assembly_cleanup EXIT
  trap 'assembly_signal HUP' HUP
  trap 'assembly_signal INT' INT
  trap 'assembly_signal TERM' TERM
fi

case "${1:-}" in
  validate-document)
    [ "$#" -eq 2 ] || { assembly_error E_USAGE; exit 1; }
    assembly_mode=document
    ;;
  validate-profile-set)
    [ "$#" -ge 4 ] && [ "$#" -le 11 ] || {
      assembly_error E_USAGE
      exit 1
    }
    assembly_mode=profile-set
    ;;
  validate-stage-run)
    [ "$#" -eq 4 ] || { assembly_error E_USAGE; exit 1; }
    assembly_mode=stage-run
    ;;
  *)
    assembly_error E_USAGE
    exit 1
    ;;
esac
shift
assembly_inputs=("$@")

PORTABLE_CORE_GENERATION='g-71433a31f52f37041a41b5a8812f79c4c0f5f26c79265788c8d625a9c6f9686b'
assembly_source="${BASH_SOURCE[0]}"
case "$assembly_source" in
  /*) ;;
  *)
    assembly_cwd="$(pwd -P 2>/dev/null)" || {
      assembly_error E_RUNTIME
      exit 1
    }
    assembly_source="$assembly_cwd/$assembly_source"
    ;;
esac
assembly_name="${assembly_source##*/}"
assembly_parent="${assembly_source%/*}"
assembly_dir="$(CDPATH='' cd -P -- "$assembly_parent" 2>/dev/null && pwd -P)" || {
  assembly_error E_RUNTIME
  exit 1
}
assembly_source="$assembly_dir/$assembly_name"
assembly_repo="$(CDPATH='' cd -P -- "$assembly_dir/.." 2>/dev/null && pwd -P)" || {
  assembly_error E_RUNTIME
  exit 1
}
if [ "$assembly_source" != "$assembly_repo/scripts/core-contract.sh" ] ||
   [ ! -f "$assembly_source" ] || [ -L "$assembly_source" ]; then
  assembly_error E_RUNTIME
  exit 1
fi

assembly_generation_root="$assembly_repo/core/v1/generations/$PORTABLE_CORE_GENERATION"
assembly_ingress="$assembly_generation_root/core-ingress.sh"
assembly_program="$assembly_generation_root/contracts.jq"
assembly_modules="$assembly_generation_root/modules"
for assembly_required_dir in \
  "$assembly_repo" "$assembly_repo/core" "$assembly_repo/core/v1" \
  "$assembly_repo/core/v1/generations" "$assembly_generation_root" \
  "$assembly_modules"; do
  if [ ! -d "$assembly_required_dir" ] || [ -L "$assembly_required_dir" ]; then
    assembly_error E_RUNTIME
    exit 1
  fi
done
for assembly_required_file in \
  "$assembly_ingress" "$assembly_program" \
  "$assembly_modules/schema.jq" "$assembly_modules/profile_graph.jq" \
  "$assembly_modules/stage_request.jq" "$assembly_modules/result_facts.jq" \
  "$assembly_modules/result_truth.jq"; do
  if [ ! -f "$assembly_required_file" ] || [ -L "$assembly_required_file" ]; then
    assembly_error E_RUNTIME
    exit 1
  fi
done

trap assembly_cleanup EXIT
trap 'assembly_signal HUP' HUP
trap 'assembly_signal INT' INT
trap 'assembly_signal TERM' TERM

# shellcheck source=/dev/null
if ! source "$assembly_ingress" 2>/dev/null; then
  assembly_error E_RUNTIME
  exit 1
fi

if [ "$assembly_accounted" = true ]; then
  portable_core_ingress_open "$assembly_scratch_root" \
    "$assembly_byte_budget" || exit 1
else
  portable_core_ingress_open || exit 1
fi
if [ "$PORTABLE_CORE_INGRESS_GENERATION" != "$PORTABLE_CORE_GENERATION" ] ||
   [ "$PORTABLE_CORE_INGRESS_ROOT" != "$assembly_program" ] ||
   [ "$PORTABLE_CORE_INGRESS_MODULE_DIR" != "$assembly_modules" ]; then
  assembly_error E_RUNTIME
  exit 1
fi
portable_core_ingress_begin "$assembly_mode" || exit 1
for assembly_input in "${assembly_inputs[@]}"; do
  portable_core_ingress_snapshot "$assembly_input" || exit 1
done
portable_core_ingress_finish_driver || exit 1
portable_core_ingress_validate || exit 1
portable_core_ingress_close || exit 1
assembly_receipt_status=0
assembly_emit_receipt || assembly_receipt_status=$?
case "$assembly_receipt_status" in
  0) ;;
  1)
    assembly_error E_RUNTIME
    exit 1
    ;;
  2) exit 1 ;;
esac
trap - EXIT HUP INT TERM
