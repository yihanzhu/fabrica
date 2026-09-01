#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_RELATION|E_DUTY)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

[ "$#" -eq 7 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-credential-policy.sh" ] ||
  emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
policy="$source_dir/credential-policy.json"
decision="$source_dir/credential-policy-decision.json"
program="$source_dir/credential-policy.jq"
duty_policy="$source_dir/duty-separation-policy.json"
duty_decision="$source_dir/duty-separation-decision.json"
duty_program="$source_dir/duty-separation.jq"
duty_driver="$source_dir/evaluate-duty.sh"
policy_validator="$source_dir/validate.sh"
validator_program="$source_dir/policy-set.jq"
core_driver="$repo/scripts/core-contract.sh"

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

PINNED_PATHS=()
PINNED_IDENTITIES=()
path_identity() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
      use strict; use warnings;
      my ($path,$limit)=@ARGV;
      my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($parent) && defined($name);
      my $resolved=abs_path($parent);
      exit 2 unless defined($resolved) && $resolved eq $parent;
      my @directory=lstat($parent);
      exit 2 unless @directory && S_ISDIR($directory[2]);
      chdir($parent) or exit 2;
      my @cwd=stat(".");
      my @leaf=lstat($name);
      exit 2 unless @leaf && S_ISREG($leaf[2]);
      sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
      binmode($input);
      my @opened=stat($input);
      exit 2 unless @opened && S_ISREG($opened[2]) &&
        $leaf[0]==$opened[0] && $leaf[1]==$opened[1] &&
        $leaf[7]==$opened[7] && $leaf[9]==$opened[9] && $leaf[10]==$opened[10];
      my $sha=Digest::SHA->new(256);
      my $total=0;
      while (1) {
        my $read=sysread($input,my $buffer,65536);
        exit 2 unless defined $read;
        last if $read==0;
        $total += $read;
        exit 3 if $total > $limit;
        $sha->add($buffer);
      }
      my $digest=$sha->hexdigest;
      my @leaf_after=lstat($name);
      my @opened_after=stat($input);
      my @directory_after=lstat($parent);
      my $resolved_after=abs_path($parent);
      exit 2 unless @cwd && @leaf_after && @opened_after && @directory_after &&
        defined($resolved_after) && $resolved_after eq $parent &&
        S_ISREG($leaf_after[2]) && S_ISDIR($directory_after[2]) &&
        $directory[0]==$cwd[0] && $directory[1]==$cwd[1] &&
        $cwd[0]==$directory_after[0] && $cwd[1]==$directory_after[1] &&
        $opened[0]==$opened_after[0] && $opened[1]==$opened_after[1] &&
        $opened[7]==$opened_after[7] && $opened[9]==$opened_after[9] &&
        $opened[10]==$opened_after[10] &&
        $opened_after[0]==$leaf_after[0] && $opened_after[1]==$leaf_after[1];
      print $directory[0],":",$directory[1],":",$leaf[0],":",$leaf[1],":",
        $leaf[7],":",$leaf[9],":",$leaf[10],":",$digest,"\n";
    ' "$1" "$2"
}
pin_path() {
  local candidate=$1 limit=${2:-1048576} candidate_identity identity_status=0
  local pin_index=0
  physical_regular "$candidate" || return 1
  candidate_identity=$(path_identity "$candidate" "$limit") || identity_status=$?
  case "$identity_status" in
    0) ;;
    3) emit_error E_LIMIT ;;
    *) return 1 ;;
  esac
  while [ "$pin_index" -lt "${#PINNED_PATHS[@]}" ]; do
    if [ "${PINNED_PATHS[$pin_index]}" = "$candidate" ]; then
      [ "${PINNED_IDENTITIES[$pin_index]}" = "$candidate_identity" ]
      return
    fi
    pin_index=$((pin_index + 1))
  done
  PINNED_PATHS[${#PINNED_PATHS[@]}]=$candidate
  PINNED_IDENTITIES[${#PINNED_IDENTITIES[@]}]=$candidate_identity
}
pinned_identity() {
  local candidate=$1 pin_index=0
  while [ "$pin_index" -lt "${#PINNED_PATHS[@]}" ]; do
    if [ "${PINNED_PATHS[$pin_index]}" = "$candidate" ]; then
      /usr/bin/printf '%s\n' "${PINNED_IDENTITIES[$pin_index]}"
      return 0
    fi
    pin_index=$((pin_index + 1))
  done
  return 1
}

for required in "$source_path" "$policy" "$decision" "$program" "$duty_policy" \
  "$duty_decision" "$duty_program" "$duty_driver" "$policy_validator" \
  "$validator_program" "$core_driver" "$@"; do
  pin_path "$required" || emit_error E_RUNTIME
done

live_jq=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$live_jq" in /*) ;; *) emit_error E_RUNTIME ;; esac
physical_regular "$live_jq" && [ -x "$live_jq" ] || emit_error E_RUNTIME
pin_path "$live_jq" 16777216 || emit_error E_RUNTIME
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
sha256_path() {
  local expected_identity
  expected_identity=$(pinned_identity "$1") || return 1
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
    use strict; use warnings;
    my ($path,$expected_identity)=@ARGV;
    my ($expected_parent_dev,$expected_parent_ino,$expected_leaf_dev,
      $expected_leaf_ino,$expected_size,$expected_mtime,$expected_ctime,
      $expected_digest)=split(/:/,$expected_identity,8);
    my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
    exit 2 unless defined($parent) && defined($name);
    my $resolved_parent=abs_path($parent);
    exit 2 unless defined($resolved_parent) && $resolved_parent eq $parent;
    my @parent_before=lstat($parent);
    exit 2 unless @parent_before && S_ISDIR($parent_before[2]) &&
      $parent_before[0]==$expected_parent_dev &&
      $parent_before[1]==$expected_parent_ino;
    chdir($parent) or exit 2;
    my @cwd=stat(".");
    exit 2 unless @cwd && $parent_before[0]==$cwd[0] && $parent_before[1]==$cwd[1];
    my @before=lstat($name);
    exit 2 unless @before && S_ISREG($before[2]) &&
      $before[0]==$expected_leaf_dev && $before[1]==$expected_leaf_ino &&
      $before[7]==$expected_size && $before[9]==$expected_mtime &&
      $before[10]==$expected_ctime;
    sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
    binmode($input);
    my @opened=stat($input);
    exit 2 unless @opened && S_ISREG($opened[2]) &&
      $before[0]==$opened[0] && $before[1]==$opened[1] &&
      $opened[7]==$expected_size && $opened[9]==$expected_mtime &&
      $opened[10]==$expected_ctime;
    my $digest=Digest::SHA->new(256);
    $digest->addfile($input);
    my @after=stat($input);
    my @path_after=lstat($name);
    my @parent_after=lstat($parent);
    my $resolved_after=abs_path($parent);
    exit 2 unless @after && @path_after && @parent_after &&
      defined($resolved_after) && $resolved_after eq $parent &&
      S_ISREG($path_after[2]) && S_ISDIR($parent_after[2]) &&
      $opened[0]==$after[0] && $opened[1]==$after[1] &&
      $opened[7]==$after[7] && $opened[9]==$after[9] && $opened[10]==$after[10] &&
      $after[0]==$path_after[0] && $after[1]==$path_after[1] &&
      $cwd[0]==$parent_after[0] && $cwd[1]==$parent_after[1] &&
      $parent_after[0]==$expected_parent_dev &&
      $parent_after[1]==$expected_parent_ino &&
      $path_after[0]==$expected_leaf_dev && $path_after[1]==$expected_leaf_ino &&
      $path_after[7]==$expected_size && $path_after[9]==$expected_mtime &&
      $path_after[10]==$expected_ctime;
    my $actual_digest=$digest->hexdigest;
    exit 2 unless $actual_digest eq $expected_digest;
    print $actual_digest,"\n";
  ' "$1" "$expected_identity"
}
[ "$(sha256_path "$live_jq")" = "$jq_sha" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-credential-policy.XXXXXX" \
  2>/dev/null) || emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
/bin/chmod 0700 "$scratch" || emit_error E_RUNTIME
ACTIVE_PID=
ACTIVE_PGID=
SIGNAL_DEFER=0
SIGNAL_EXITING=0
PENDING_SIGNAL_STATUS=0
SELF_PGID=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ') ||
  emit_error E_RUNTIME
[[ "$SELF_PGID" =~ ^[1-9][0-9]*$ ]] || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
group_alive() {
  [ -n "${1:-}" ] && /bin/kill -0 -- "-$1" 2>/dev/null
}
terminate_active() {
  local attempt=0 group=${ACTIVE_PGID:-} leader=${ACTIVE_PID:-}
  [[ "$group" =~ ^[1-9][0-9]*$ ]] && [[ "$leader" =~ ^[1-9][0-9]*$ ]] ||
    return 1
  /bin/kill -TERM -- "-$group" 2>/dev/null || :
  while group_alive "$group" && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  if group_alive "$group"; then
    /bin/kill -KILL -- "-$group" 2>/dev/null || :
    attempt=0
    while group_alive "$group" && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      /bin/sleep 0.01
    done
  fi
  group_alive "$group" && return 1
  wait "$leader" 2>/dev/null || :
  ACTIVE_PID=
  ACTIVE_PGID=
  ! group_alive "$group"
}
signal_exit() {
  trap - EXIT
  exec >/dev/null 2>&1
  if [ -n "${ACTIVE_PGID:-}" ]; then terminate_active || :; fi
  cleanup
  exit "${1:-1}"
}
handle_signal() {
  local exit_status=${1:-1}
  [ "${SIGNAL_EXITING:-0}" -eq 0 ] || return 0
  [ "${PENDING_SIGNAL_STATUS:-0}" -ne 0 ] ||
    PENDING_SIGNAL_STATUS=$exit_status
  [ "${SIGNAL_DEFER:-0}" -eq 0 ] || return 0
  SIGNAL_EXITING=1
  signal_exit "$PENDING_SIGNAL_STATUS"
}
replay_pending_signal() {
  local pending
  SIGNAL_DEFER=0
  pending=${PENDING_SIGNAL_STATUS:-0}
  PENDING_SIGNAL_STATUS=0
  if [ "$pending" -ne 0 ]; then
    SIGNAL_EXITING=1
    signal_exit "$pending"
  fi
}
run_child() {
  local child child_status=0 gate pgid wait_status
  [ -z "${ACTIVE_PID:-}" ] && [ -z "${ACTIVE_PGID:-}" ] || return 125
  gate="$scratch/child-gate"
  PENDING_SIGNAL_STATUS=0
  SIGNAL_DEFER=1
  /usr/bin/mkfifo "$gate" || { replay_pending_signal; return 125; }
  exec 9<>"$gate" || { /bin/rm -f -- "$gate"; replay_pending_signal; return 125; }
  /bin/rm -f -- "$gate" || { exec 9>&-; replay_pending_signal; return 125; }
  : >"$scratch/child-launching" || { exec 9>&-; replay_pending_signal; return 125; }
  if [ "$(sha256_path "$jq_bin")" != "$jq_sha" ]; then
    exec 9>&-
    /bin/rm -f -- "$scratch/child-launching"
    replay_pending_signal
    return 125
  fi
  if [ "${PENDING_SIGNAL_STATUS:-0}" -ne 0 ]; then
    exec 9>&-
    /bin/rm -f -- "$scratch/child-launching"
    replay_pending_signal
  fi
  set -m
  /bin/bash -c '
    IFS= read -r token <&9 || exit 125
    exec 9>&-
    [ "$token" = go ] || exit 125
    exec "$@"
  ' credential-child "$@" &
  child=$!
  set +m
  pgid=$(/bin/ps -o pgid= -p "$child" 2>/dev/null | /usr/bin/tr -d ' ') || pgid=
  if ! [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$child" ] ||
     [ "$pgid" = "$SELF_PGID" ]; then
    /usr/bin/printf 'abort\n' >&9 || :
    exec 9>&-
    /bin/rm -f -- "$scratch/child-launching"
    wait "$child" 2>/dev/null || :
    replay_pending_signal
    return 125
  fi
  ACTIVE_PID=$child
  ACTIVE_PGID=$pgid
  /usr/bin/printf 'go\n' >&9 || {
    exec 9>&-
    /bin/rm -f -- "$scratch/child-launching"
    terminate_active || :
    replay_pending_signal
    return 125
  }
  exec 9>&-
  /bin/rm -f -- "$scratch/child-launching" || {
    terminate_active || :
    replay_pending_signal
    return 125
  }
  replay_pending_signal
  while :; do
    wait_status=0
    wait "$child" || wait_status=$?
    case "$wait_status" in
      129|130|143) /bin/kill -0 "$child" 2>/dev/null && continue ;;
    esac
    child_status=$wait_status
    break
  done
  SIGNAL_DEFER=1
  : >"$scratch/child-teardown" || {
    terminate_active || :
    replay_pending_signal
    return 125
  }
  if group_alive "$ACTIVE_PGID"; then
    terminate_active || :
    /bin/rm -f -- "$scratch/child-teardown"
    replay_pending_signal
    return 125
  fi
  ACTIVE_PID=
  ACTIVE_PGID=
  /bin/rm -f -- "$scratch/child-teardown" || {
    replay_pending_signal
    return 125
  }
  replay_pending_signal
  return "$child_status"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

snapshot_nofollow() {
  local source=$1 target=$2 limit=$3 copy_status expected_identity
  expected_identity=$(pinned_identity "$source") || emit_error E_RUNTIME
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
    use strict; use warnings;
    my ($source,$target,$limit,$expected_identity)=@ARGV;
    my ($expected_parent_dev,$expected_parent_ino,$expected_leaf_dev,
      $expected_leaf_ino,$expected_size,$expected_mtime,$expected_ctime,
      $expected_digest)=split(/:/,$expected_identity,8);
    my ($parent,$name)=$source =~ m{\A(.+)/([^/]+)\z};
    exit 2 unless defined($parent) && defined($name);
    my $resolved_parent=abs_path($parent);
    exit 2 unless defined($resolved_parent) && $resolved_parent eq $parent;
    my @parent_before=lstat($parent);
    exit 2 unless @parent_before && S_ISDIR($parent_before[2]) &&
      $parent_before[0]==$expected_parent_dev &&
      $parent_before[1]==$expected_parent_ino;
    chdir($parent) or exit 2;
    my @cwd=stat(".");
    exit 2 unless @cwd && $parent_before[0]==$cwd[0] && $parent_before[1]==$cwd[1];
    my @before=lstat($name);
    exit 2 unless @before && S_ISREG($before[2]) &&
      $before[0]==$expected_leaf_dev && $before[1]==$expected_leaf_ino &&
      $before[7]==$expected_size && $before[9]==$expected_mtime &&
      $before[10]==$expected_ctime;
    sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
    binmode($input);
    my @opened=stat($input);
    exit 2 unless @opened && S_ISREG($opened[2]) &&
      $before[0]==$opened[0] && $before[1]==$opened[1] &&
      $opened[7]==$expected_size && $opened[9]==$expected_mtime &&
      $opened[10]==$expected_ctime;
    sysopen(my $output,$target,O_WRONLY|O_CREAT|O_EXCL,0600) or exit 2;
    binmode($output);
    my $total=0;
    my $sha=Digest::SHA->new(256);
    while (1) {
      my $read=sysread($input,my $buffer,65536);
      exit 2 unless defined $read;
      last if $read==0;
      $total += $read;
      exit 3 if $total > $limit;
      $sha->add($buffer);
      my $offset=0;
      while ($offset < $read) {
        my $written=syswrite($output,$buffer,$read-$offset,$offset);
        exit 2 unless defined $written && $written > 0;
        $offset += $written;
      }
    }
    my @after=stat($input);
    my @path_after=lstat($name);
    my @parent_after=lstat($parent);
    my $resolved_after=abs_path($parent);
    exit 2 unless @after && @path_after && @parent_after &&
      defined($resolved_after) && $resolved_after eq $parent &&
      S_ISREG($path_after[2]) && S_ISDIR($parent_after[2]) &&
      $opened[0]==$after[0] && $opened[1]==$after[1] &&
      $opened[7]==$after[7] && $opened[9]==$after[9] && $opened[10]==$after[10] &&
      $after[0]==$path_after[0] && $after[1]==$path_after[1] &&
      $cwd[0]==$parent_after[0] && $cwd[1]==$parent_after[1] &&
      $parent_after[0]==$expected_parent_dev &&
      $parent_after[1]==$expected_parent_ino &&
      $path_after[0]==$expected_leaf_dev && $path_after[1]==$expected_leaf_ino &&
      $path_after[7]==$expected_size && $path_after[9]==$expected_mtime &&
      $path_after[10]==$expected_ctime;
    exit 2 unless $sha->hexdigest eq $expected_digest;
  ' "$source" "$target" "$limit" "$expected_identity"
  copy_status=$?
  case "$copy_status" in
    0) ;;
    3) emit_error E_LIMIT ;;
    *) emit_error E_RUNTIME ;;
  esac
  pin_path "$target" "$limit" || emit_error E_RUNTIME
}
snapshot_fixed() {
  local source=$1 target=$2 size
  snapshot_nofollow "$source" "$target" 1048576
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
}
snapshot_executable() {
  local source=$1 target=$2 size
  snapshot_nofollow "$source" "$target" 16777216
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 16777216 ] || emit_error E_LIMIT
  /bin/chmod 0500 "$target" || emit_error E_RUNTIME
}
canonical_json() {
  local raw=$1 canonical=$2 bom roots
  bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
  roots=$("$jq_bin" -s 'length' "$raw" 2>/dev/null) || emit_error E_PARSE
  [ "$roots" -eq 1 ] || emit_error E_PARSE
  "$jq_bin" -S -c . "$raw" >"$canonical" 2>/dev/null || emit_error E_PARSE
  /usr/bin/cmp -s "$raw" "$canonical" || emit_error E_CANONICAL
  "$jq_bin" -e '
    def depth:
      if type=="array" then if length==0 then 1 else 1+([.[]|depth]|max) end
      elif type=="object" then if length==0 then 1 else 1+([.[]|depth]|max) end
      else 1 end;
    def members:
      if type=="array" then length+([.[]|members]|add//0)
      elif type=="object" then (keys_unsorted|length)+([.[]|members]|add//0)
      else 0 end;
    def strings_ok:
      if type=="array" then all(.[];strings_ok)
      elif type=="object" then
        all(keys_unsorted[];utf8bytelength<=8192) and all(.[];strings_ok)
      elif type=="string" then utf8bytelength<=8192 else true end;
    depth<=32 and members<=4096 and strings_ok
  ' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT
}
sha256_text() {
  /usr/bin/printf '%s' "$1" |
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}
unchanged() {
  local live_digest snapshot_digest
  live_digest=$(sha256_path "$1") || return 1
  snapshot_digest=$(sha256_path "$2") || return 1
  [ "$live_digest" = "$snapshot_digest" ]
}

/bin/mkdir -m 0700 "$scratch/bin" || emit_error E_RUNTIME
jq_bin="$scratch/bin/jq"
snapshot_executable "$live_jq" "$jq_bin"
physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

selected_core_generation() {
  local wrapper=$1 tag=$2 selected assignment_count snapshot
  snapshot="$scratch/core-wrapper-$tag.sh"
  snapshot_fixed "$wrapper" "$snapshot"
  assignment_count=$(/usr/bin/grep -Ec \
    '^[[:space:]]*PORTABLE_CORE_GENERATION=' "$snapshot") || return 1
  [ "$assignment_count" -eq 1 ] || return 1
  selected=$(/usr/bin/sed -n \
    "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
    "$snapshot") || return 1
  [[ "$selected" =~ ^g-[0-9a-f]{64}$ ]] || return 1
  /usr/bin/printf '%s\n' "$selected"
}
runtime_paths() {
  local selected=$1
  /usr/bin/printf '%s\n' \
    control/v1/duty-separation-policy.json \
    control/v1/duty-separation-decision.json \
    control/v1/duty-separation.jq \
    control/v1/evaluate-duty.sh \
    control/v1/policy-set.jq \
    control/v1/validate.sh \
    scripts/core-contract.sh \
    core/v2/generation-registry.json \
    "core/v2/generations/$selected/contracts.jq" \
    "core/v2/generations/$selected/core-ingress.sh" \
    "core/v2/generations/$selected/modules/profile_graph.jq" \
    "core/v2/generations/$selected/modules/result_facts.jq" \
    "core/v2/generations/$selected/modules/result_truth.jq" \
    "core/v2/generations/$selected/modules/schema.jq" \
    "core/v2/generations/$selected/modules/stage_request.jq"
}
runtime_closure_sha() {
  local root=$1 selected=$2 tag=$3 relative file digest descriptor members
  local required_dir physical selected_at_root
  for required_dir in "$root" "$root/control" "$root/control/v1" "$root/scripts" \
    "$root/core" "$root/core/v2" "$root/core/v2/generations" \
    "$root/core/v2/generations/$selected" \
    "$root/core/v2/generations/$selected/modules"; do
    [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || return 1
    physical=$(CDPATH='' cd -P -- "$required_dir" 2>/dev/null && pwd -P) || return 1
    [ "$physical" = "$required_dir" ] || return 1
  done
  pin_path "$root/scripts/core-contract.sh" || return 1
  selected_at_root=$(selected_core_generation "$root/scripts/core-contract.sh" "$tag") ||
    return 1
  [ "$selected_at_root" = "$selected" ] || return 1
  members="$scratch/runtime-$tag.tsv"
  : >"$members" || return 1
  while IFS= read -r relative; do
    pin_path "$root/$relative" || return 1
  done < <(runtime_paths "$selected")
  while IFS= read -r relative; do
    file="$root/$relative"
    digest=$(sha256_path "$file") || return 1
    /usr/bin/printf '%s\t%s\n' "$relative" "$digest" >>"$members" || return 1
  done < <(runtime_paths "$selected")
  descriptor=$("$jq_bin" -Rn -S -c \
    --arg generation_sha "$(sha256_text "$selected")" '
      [inputs|split("\t")|{path:.[0],sha256:.[1]}] as $members |
      {schema_version:1,kind:"credential_policy_runtime_closure",
       selected_generation_id_sha256:$generation_sha,members:$members}
    ' <"$members") || return 1
  sha256_text "$descriptor"
}
build_runtime_mirror() {
  local selected=$1 mirror="$scratch/runtime" relative source target
  /bin/mkdir -p "$mirror/control/v1" "$mirror/scripts" \
    "$mirror/core/v2/generations/$selected/modules" || return 1
  while IFS= read -r relative; do
    pin_path "$repo/$relative" || return 1
  done < <(runtime_paths "$selected")
  while IFS= read -r relative; do
    source="$repo/$relative"
    target="$mirror/$relative"
    snapshot_fixed "$source" "$target"
  done < <(runtime_paths "$selected")
  /bin/chmod 0500 "$mirror/control/v1/evaluate-duty.sh" \
    "$mirror/control/v1/validate.sh" "$mirror/scripts/core-contract.sh" || return 1
  /usr/bin/printf '%s\n' "$mirror"
}

snapshot_fixed "$source_path" "$scratch/driver.sh"
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$program" "$scratch/program.jq"
snapshot_fixed "$duty_policy" "$scratch/bound-duty-policy.json"
snapshot_fixed "$duty_decision" "$scratch/bound-duty-decision.json"
snapshot_fixed "$duty_program" "$scratch/bound-duty-program.jq"
snapshot_fixed "$duty_driver" "$scratch/bound-duty-driver.sh"
snapshot_fixed "$policy_validator" "$scratch/bound-validator-driver.sh"
snapshot_fixed "$validator_program" "$scratch/bound-validator-program.jq"
: >"$scratch/input-snapshot-ready"
names=(policy-set request resolved result duty claim)
inputs=("$@")
index=0
while [ "$index" -lt 6 ]; do
  snapshot_fixed "${inputs[$index]}" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
for static_name in policy decision policy-set request resolved result duty claim; do
  canonical_json "$scratch/$static_name.json" "$scratch/$static_name.canonical"
done
"$jq_bin" -e '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="credential_boundary_claim" and
  (.id|type=="string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")) and
  (.body|type=="object")
' "$scratch/claim.json" >/dev/null 2>&1 || emit_error E_RELATION

policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/program.jq") || emit_error E_RUNTIME
driver_sha=$(sha256_path "$scratch/driver.sh") || emit_error E_RUNTIME
duty_policy_sha=$(sha256_path "$scratch/bound-duty-policy.json") || emit_error E_RUNTIME
duty_decision_sha=$(sha256_path "$scratch/bound-duty-decision.json") || emit_error E_RUNTIME
duty_program_sha=$(sha256_path "$scratch/bound-duty-program.jq") || emit_error E_RUNTIME
duty_driver_sha=$(sha256_path "$scratch/bound-duty-driver.sh") || emit_error E_RUNTIME
validator_driver_sha=$(sha256_path "$scratch/bound-validator-driver.sh") ||
  emit_error E_RUNTIME
validator_program_sha=$(sha256_path "$scratch/bound-validator-program.jq") ||
  emit_error E_RUNTIME

"$jq_bin" -e --arg policy_sha "$policy_sha" --arg driver_sha "$driver_sha" \
  --arg program_sha "$program_sha" --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_decision_sha "$duty_decision_sha" \
  --slurpfile policy "$scratch/policy.json" '
  . == {
    schema_version:1,kind:"credential_policy_decision",
    id:"control-decision.credential-policy",
    body:{activation_state:"inactive",decision:"allow-observation-only-evaluation",
      dependencies:{duty_separation:{
        policy_ref:{content_id:"control-policy.duty-separation",
          media_type:"application/vnd.ystack.control-policy+json",sha256:$duty_policy_sha},
        decision_ref:{content_id:"control-decision.duty-separation",
          media_type:"application/vnd.ystack.control-decision+json",sha256:$duty_decision_sha}}},
      evaluator:{
        driver_ref:{content_id:"control-evaluator-driver.credential-policy.v1",
          media_type:"text/x-shellscript",sha256:$driver_sha},
        program_ref:{content_id:"control-evaluator-program.credential-policy.v1",
          media_type:"text/x-jq",sha256:$program_sha}},
      fail_mode:"closed",
      policy_ref:{content_id:$policy[0].id,
        media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
      semantics:{authority_effect:"none",claim_provenance:"unqualified-input-claim",
        input_contract:"control-policy-set+public-core-stage-run+duty-evaluation+credential-boundary-claim.v1",
        output_kind:"credential_policy_evaluation",output_schema_version:1,
        qualification_effect:"none",reference_semantics:"identity-only",
        verdicts:["inconclusive","violated"]}}}
' "$scratch/decision.json" >/dev/null 2>&1 || emit_error E_RELATION

"$jq_bin" -e --arg duty_driver_sha "$duty_driver_sha" \
  --arg duty_program_sha "$duty_program_sha" \
  --arg validator_driver_sha "$validator_driver_sha" \
  --arg validator_program_sha "$validator_program_sha" '
  .body.evaluator == {
    driver_ref:{content_id:"control-evaluator-driver.duty-separation.v1",
      media_type:"text/x-shellscript",sha256:$duty_driver_sha},
    policy_set_validator:{
      driver_ref:{content_id:"control-policy-set-validator-driver.v1",
        media_type:"text/x-shellscript",sha256:$validator_driver_sha},
      program_ref:{content_id:"control-policy-set-validator-program.v1",
        media_type:"text/x-jq",sha256:$validator_program_sha}},
    program_ref:{content_id:"control-evaluator-program.duty-separation.v1",
      media_type:"text/x-jq",sha256:$duty_program_sha}}
' "$scratch/bound-duty-decision.json" >/dev/null 2>&1 || emit_error E_RELATION

runtime_components_match() {
  local root=$1
  pin_path "$root/control/v1/duty-separation-policy.json" || return 1
  pin_path "$root/control/v1/duty-separation-decision.json" || return 1
  pin_path "$root/control/v1/duty-separation.jq" || return 1
  pin_path "$root/control/v1/evaluate-duty.sh" || return 1
  pin_path "$root/control/v1/validate.sh" || return 1
  pin_path "$root/control/v1/policy-set.jq" || return 1
  [ "$(sha256_path "$root/control/v1/duty-separation-policy.json")" = "$duty_policy_sha" ] ||
    return 1
  [ "$(sha256_path "$root/control/v1/duty-separation-decision.json")" = "$duty_decision_sha" ] ||
    return 1
  [ "$(sha256_path "$root/control/v1/duty-separation.jq")" = "$duty_program_sha" ] ||
    return 1
  [ "$(sha256_path "$root/control/v1/evaluate-duty.sh")" = "$duty_driver_sha" ] ||
    return 1
  [ "$(sha256_path "$root/control/v1/validate.sh")" = "$validator_driver_sha" ] ||
    return 1
  [ "$(sha256_path "$root/control/v1/policy-set.jq")" = "$validator_program_sha" ]
}

: >"$scratch/runtime-bindings-ready"
selected=$(selected_core_generation "$core_driver" selected) || emit_error E_RELATION
live_runtime_sha=$(runtime_closure_sha "$repo" "$selected" live-pre) ||
  emit_error E_RELATION
runtime_components_match "$repo" || emit_error E_RELATION
mirror_root=$(build_runtime_mirror "$selected") || emit_error E_RELATION
mirror_runtime_sha=$(runtime_closure_sha "$mirror_root" "$selected" mirror-pre) ||
  emit_error E_RELATION
if [ "$live_runtime_sha" != "$mirror_runtime_sha" ] ||
   ! runtime_components_match "$repo" ||
   ! runtime_components_match "$mirror_root"; then
  emit_error E_RELATION
fi

: >"$scratch/duty-ready"
duty_status=0
run_child /usr/bin/env -i LC_ALL=C PATH="${jq_bin%/*}:/usr/bin:/bin" \
  TMPDIR="$scratch" \
  /bin/bash "$mirror_root/control/v1/evaluate-duty.sh" evaluate \
  "$scratch/policy-set.json" "$scratch/request.json" "$scratch/resolved.json" \
  "$scratch/result.json" >"$scratch/generated-duty.json" \
  2>"$scratch/generated-duty.err" || duty_status=$?
: >"$scratch/duty-complete"
post_live_runtime_sha=$(runtime_closure_sha "$repo" "$selected" live-post-duty) ||
  emit_error E_RELATION
post_mirror_runtime_sha=$(runtime_closure_sha \
  "$mirror_root" "$selected" mirror-post-duty) || emit_error E_RELATION
if [ "$post_live_runtime_sha" != "$live_runtime_sha" ] ||
   [ "$post_mirror_runtime_sha" != "$mirror_runtime_sha" ] ||
   ! runtime_components_match "$repo" ||
   ! runtime_components_match "$mirror_root"; then
  emit_error E_RELATION
fi
[ "$duty_status" -eq 0 ] || emit_error E_DUTY
/usr/bin/cmp -s "$scratch/generated-duty.json" "$scratch/duty.json" ||
  emit_error E_DUTY

policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
resolved_sha=$(sha256_path "$scratch/resolved.json") || emit_error E_RUNTIME
result_sha=$(sha256_path "$scratch/result.json") || emit_error E_RUNTIME
duty_sha=$(sha256_path "$scratch/duty.json") || emit_error E_RUNTIME
claim_sha=$(sha256_path "$scratch/claim.json") || emit_error E_RUNTIME
: >"$scratch/credential-ready"
"$jq_bin" -S -c -n -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --slurpfile duty "$scratch/duty.json" \
  --slurpfile claim "$scratch/claim.json" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg duty_sha "$duty_sha" --arg claim_sha "$claim_sha" \
  >"$scratch/output.json" 2>/dev/null || emit_error E_RELATION
: >"$scratch/credential-complete"

if ! unchanged "$source_path" "$scratch/driver.sh" ||
   ! unchanged "$policy" "$scratch/policy.json" ||
   ! unchanged "$decision" "$scratch/decision.json" ||
   ! unchanged "$program" "$scratch/program.jq"; then
  emit_error E_RELATION
fi
final_live_runtime_sha=$(runtime_closure_sha "$repo" "$selected" live-post) ||
  emit_error E_RELATION
final_mirror_runtime_sha=$(runtime_closure_sha \
  "$mirror_root" "$selected" mirror-post) || emit_error E_RELATION
if [ "$final_live_runtime_sha" != "$live_runtime_sha" ] ||
   [ "$final_mirror_runtime_sha" != "$mirror_runtime_sha" ] ||
   ! runtime_components_match "$repo" ||
   ! runtime_components_match "$mirror_root"; then
  emit_error E_RELATION
fi
index=0
while [ "$index" -lt 6 ]; do
  unchanged "${inputs[$index]}" "$scratch/${names[$index]}.json" ||
    emit_error E_RELATION
  index=$((index + 1))
done
physical_regular "$live_jq" && [ -x "$live_jq" ] &&
  [ "$(sha256_path "$live_jq")" = "$jq_sha" ] &&
  physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] || emit_error E_RELATION

canonical_json "$scratch/output.json" "$scratch/output.canonical"
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg duty_sha "$duty_sha" --arg claim_sha "$claim_sha" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --slurpfile duty "$scratch/duty.json" \
  --slurpfile claim "$scratch/claim.json" '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="credential_policy_evaluation" and
  .id==$result[0].id and
  (.body|keys|sort)==["activation_state","authority_effect","claim_ref",
    "core_contract","decision_ref","duty_evaluation_ref","evaluation_mode",
    "policy_ref","policy_set","qualification_effect","reason_ids",
    "reference_semantics","stage","verdict"] and
  .body.activation_state=="inactive" and .body.authority_effect=="none" and
  .body.qualification_effect=="none" and
  .body.evaluation_mode=="observation-only" and
  .body.reference_semantics=="identity-only" and
  .body.policy_set=={id:$policy_set[0].id,sha256:$policy_set_sha} and
  .body.policy_ref=={content_id:"control-policy.credential-policy",
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  .body.decision_ref=={content_id:"control-decision.credential-policy",
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.claim_ref=={schema_version:$claim[0].schema_version,kind:$claim[0].kind,
    id:$claim[0].id,sha256:$claim_sha} and
  .body.duty_evaluation_ref=={schema_version:$duty[0].schema_version,
    kind:$duty[0].kind,id:$duty[0].id,sha256:$duty_sha} and
  .body.core_contract==$policy_set[0].body.core_contract and
  .body.stage=={
    request_ref:{schema_version:$request[0].schema_version,kind:$request[0].kind,
      id:$request[0].id,sha256:$request_sha},
    resolved_profile_ref:{schema_version:$resolved[0].schema_version,
      kind:$resolved[0].kind,id:$resolved[0].id,sha256:$resolved_sha},
    result_ref:{schema_version:$result[0].schema_version,kind:$result[0].kind,
      id:$result[0].id,sha256:$result_sha}} and
  (.body.verdict=="violated" or .body.verdict=="inconclusive") and
  (.body.reason_ids|type=="array" and length>=1 and length<=256 and
    all(.[];type=="string") and .==(sort|unique)) and
  (.body.reason_ids|index("credential-policy.satisfied")==null) and
  ((.body|has("grant_ref") or has("activation") or has("credential_ref"))|not)
' "$scratch/output.json" >/dev/null 2>&1 || emit_error E_RUNTIME

/bin/cat "$scratch/output.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
