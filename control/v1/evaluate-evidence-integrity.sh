#!/bin/bash
# YSTACK_EVIDENCE_PAYLOAD_SHARED_BEGIN
# shellcheck disable=SC2016,SC2329
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  local token=${1:-E_RUNTIME}
  case "$token" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_RELATION|E_POLICY_SET|E_CORE) ;;
    *) token=E_RUNTIME ;;
  esac
  if [ -n "${scratch:-}" ] && declare -F cleanup >/dev/null 2>&1; then
    if cleanup; then
      trap - EXIT HUP INT TERM
    else
      exec >/dev/null 2>&1
      exit 125
    fi
  fi
  /usr/bin/printf '%s\n' "$token" >&2
  exit 1
}

silent_fail() {
  exec >/dev/null 2>&1
  exit 125
}

terminal_teardown_fail() {
  exec >/dev/null 2>&1
  trap - EXIT HUP INT TERM
  exit 125
}

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

expected_jq_digest() {
  case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
    Darwin:*)
      /usr/bin/printf '%s\n' \
        5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
      ;;
    Linux:x86_64)
      /usr/bin/printf '%s\n' \
        af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
      ;;
    *) return 1 ;;
  esac
}

private_mode_ok() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:mode -e '
      my @st=lstat($ARGV[0]);
      exit 1 unless @st && S_ISREG($st[2]) && (($st[2] & 07777) == 0500);
    ' "$1"
}

directory_identity() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:mode -MCwd=abs_path -e '
      my ($path)=@ARGV; my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 1 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      my @parent=lstat($parent); my @dir=lstat($path); my $physical=abs_path($path);
      exit 1 unless @parent && @dir && S_ISDIR($parent[2]) && S_ISDIR($dir[2]) &&
        (($dir[2] & 07777) == 0700) && defined($physical) && $physical eq $path;
      print $parent[0],":",$parent[1],":",$dir[0],":",$dir[1],"\n";
    ' "$1"
}

directory_matches_identity() {
  local actual
  actual=$(directory_identity "$1") || return 1
  [ "$actual" = "$2" ]
}

path_identity() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
      use strict; use warnings;
      my ($path,$limit)=@ARGV;
      my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($parent) && defined($name);
      my $physical=abs_path($parent);
      exit 2 unless defined($physical) && $physical eq $parent;
      my @parent=lstat($parent);
      exit 2 unless @parent && S_ISDIR($parent[2]);
      chdir($parent) or exit 2;
      my @cwd=stat("."); my @leaf=lstat($name);
      exit 2 unless @cwd && @leaf && S_ISREG($leaf[2]);
      sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
      binmode($input); my @opened=stat($input);
      exit 2 unless @opened && S_ISREG($opened[2]) &&
        $leaf[0]==$opened[0] && $leaf[1]==$opened[1] &&
        $leaf[7]==$opened[7] && $leaf[9]==$opened[9] && $leaf[10]==$opened[10];
      my $sha=Digest::SHA->new(256); my $total=0;
      while (1) {
        my $read=sysread($input,my $buffer,65536);
        exit 2 unless defined $read; last if $read==0;
        $total += $read; exit 3 if $total > $limit; $sha->add($buffer);
      }
      my @after=stat($input); my @path_after=lstat($name);
      my @parent_after=lstat($parent); my $after_physical=abs_path($parent);
      exit 2 unless @after && @path_after && @parent_after &&
        defined($after_physical) && $after_physical eq $parent &&
        S_ISREG($path_after[2]) && S_ISDIR($parent_after[2]) &&
        $opened[0]==$after[0] && $opened[1]==$after[1] &&
        $opened[7]==$after[7] && $opened[9]==$after[9] &&
        $opened[10]==$after[10] &&
        $after[0]==$path_after[0] && $after[1]==$path_after[1] &&
        $cwd[0]==$parent_after[0] && $cwd[1]==$parent_after[1];
      print $parent[0],":",$parent[1],":",$leaf[0],":",$leaf[1],":",
        $leaf[7],":",$leaf[9],":",$leaf[10],":",$sha->hexdigest,"\n";
    ' "$1" "$2"
}

path_matches_identity() {
  local actual
  actual=$(path_identity "$1" "$3") || return 1
  [ "$actual" = "$2" ]
}

snapshot_nofollow() {
  local source=$1 expected=$2 target=$3 limit=$4 mode=${5:-0600}
  local copy_status=0 relative
  case "$target" in
    "$scratch"/*) relative=${target#"$scratch/"} ;;
    *) return 1 ;;
  esac
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
      use strict; use warnings;
      my ($source,$expected,$root,$root_expected,$target,$limit,$mode)=@ARGV;
      my ($p_dev,$p_ino,$f_dev,$f_ino,$size,$mtime,$ctime,$digest)=
        split(/:/,$expected,8);
      my ($parent,$name)=$source =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      my @parent=lstat($parent);
      exit 2 unless @parent && S_ISDIR($parent[2]) &&
        $parent[0]==$p_dev && $parent[1]==$p_ino;
      opendir(my $source_parent_dh,$parent) or exit 2;
      my @source_parent_opened=stat($source_parent_dh);
      exit 2 unless @source_parent_opened && S_ISDIR($source_parent_opened[2]) &&
        $source_parent_opened[0]==$parent[0] &&
        $source_parent_opened[1]==$parent[1];
      chdir($source_parent_dh) or exit 2;
      my @cwd=stat($source_parent_dh); my @leaf=lstat($name);
      exit 2 unless @cwd && @leaf && S_ISREG($leaf[2]) &&
        $leaf[0]==$f_dev && $leaf[1]==$f_ino && $leaf[7]==$size &&
        $leaf[9]==$mtime && $leaf[10]==$ctime;
      sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
      binmode($input); my @opened=stat($input);
      exit 2 unless @opened && S_ISREG($opened[2]) &&
        $opened[0]==$f_dev && $opened[1]==$f_ino && $opened[7]==$size &&
        $opened[9]==$mtime && $opened[10]==$ctime;

      my ($rp_dev,$rp_ino,$rd_dev,$rd_ino)=split(/:/,$root_expected,4);
      my ($root_parent,$root_name)=$root =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($root_parent) && defined($root_name) &&
        defined(abs_path($root_parent)) && abs_path($root_parent) eq $root_parent &&
        $target =~ m{\A[^/]+(?:/[^/]+)*\z};
      opendir(my $root_parent_dh,$root_parent) or exit 2;
      my @root_parent_st=stat($root_parent_dh);
      exit 2 unless @root_parent_st && S_ISDIR($root_parent_st[2]) &&
        $root_parent_st[0]==$rp_dev && $root_parent_st[1]==$rp_ino;
      chdir($root_parent_dh) or exit 2;
      my @root_named=lstat($root_name);
      exit 2 unless @root_named && S_ISDIR($root_named[2]) &&
        $root_named[0]==$rd_dev && $root_named[1]==$rd_ino;
      opendir(my $root_dh,$root_name) or exit 2;
      my @root_opened=stat($root_dh);
      exit 2 unless @root_opened && S_ISDIR($root_opened[2]) &&
        $root_opened[0]==$rd_dev && $root_opened[1]==$rd_ino;
      chdir($root_dh) or exit 2;
      my @parts=split(m{/},$target); my $leaf=pop @parts;
      for my $component (@parts) {
        exit 2 if $component eq "." or $component eq "..";
        my @named=lstat($component);
        exit 2 unless @named && S_ISDIR($named[2]);
        opendir(my $next,$component) or exit 2;
        my @next_opened=stat($next);
        exit 2 unless @next_opened && S_ISDIR($next_opened[2]) &&
          $next_opened[0]==$named[0] && $next_opened[1]==$named[1];
        chdir($next) or exit 2;
      }
      exit 2 if $leaf eq "." or $leaf eq "..";
      sysopen(my $output,$leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or exit 2;
      binmode($output); my $sha=Digest::SHA->new(256); my $total=0;
      while (1) {
        my $read=sysread($input,my $buffer,65536);
        exit 2 unless defined $read; last if $read==0;
        $total += $read; exit 3 if $total > $limit; $sha->add($buffer);
        my $offset=0;
        while ($offset < $read) {
          my $written=syswrite($output,$buffer,$read-$offset,$offset);
          exit 2 unless defined($written) && $written>0; $offset += $written;
        }
      }
      chmod(oct($mode),$output) or exit 2;
      close($output) or exit 2;
      chdir($source_parent_dh) or exit 2;
      my @after=stat($input); my @path_after=lstat($name);
      my @parent_after=lstat($parent);
      exit 2 unless @after && @path_after && @parent_after &&
        S_ISREG($path_after[2]) && S_ISDIR($parent_after[2]) &&
        $opened[0]==$after[0] && $opened[1]==$after[1] &&
        $opened[7]==$after[7] && $opened[9]==$after[9] &&
        $opened[10]==$after[10] && $after[0]==$path_after[0] &&
        $after[1]==$path_after[1] && $cwd[0]==$parent_after[0] &&
        $cwd[1]==$parent_after[1] && $sha->hexdigest eq $digest;
    ' "$source" "$expected" "$scratch" "$SCRATCH_ID" "$relative" "$limit" \
      "$mode" || copy_status=$?
  case "$copy_status" in 0) ;; 3) emit_error E_LIMIT ;; *) return 1 ;; esac
}

scratch_mkdirs() {
  [ "$#" -gt 0 ] || return 1
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:mode -MCwd=abs_path -e '
      use strict; use warnings;
      my ($root,$expected,@paths)=@ARGV;
      my ($p_dev,$p_ino,$d_dev,$d_ino)=split(/:/,$expected,4);
      my ($parent,$name)=$root =~ m{\A(.+)/([^/]+)\z};
      exit 1 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      opendir(my $parent_dh,$parent) or exit 1;
      my @parent_st=stat($parent_dh);
      exit 1 unless @parent_st && S_ISDIR($parent_st[2]) &&
        $parent_st[0]==$p_dev && $parent_st[1]==$p_ino;
      chdir($parent_dh) or exit 1;
      my @root_named=lstat($name);
      exit 1 unless @root_named && S_ISDIR($root_named[2]) &&
        $root_named[0]==$d_dev && $root_named[1]==$d_ino;
      opendir(my $root_dh,$name) or exit 1;
      my @root_opened=stat($root_dh);
      exit 1 unless @root_opened && S_ISDIR($root_opened[2]) &&
        $root_opened[0]==$d_dev && $root_opened[1]==$d_ino;
      for my $path (@paths) {
        exit 1 unless $path =~ m{\A[^/]+(?:/[^/]+)*\z};
        chdir($root_dh) or exit 1;
        for my $component (split(m{/},$path)) {
          exit 1 if $component eq "." or $component eq "..";
          my @named=lstat($component);
          if (!@named) {
            mkdir($component,0700) or exit 1;
            @named=lstat($component);
          }
          exit 1 unless @named && S_ISDIR($named[2]);
          opendir(my $next,$component) or exit 1;
          my @opened=stat($next);
          exit 1 unless @opened && S_ISDIR($opened[2]) &&
            $opened[0]==$named[0] && $opened[1]==$named[1];
          chdir($next) or exit 1;
        }
      }
    ' "$scratch" "$SCRATCH_ID" "$@"
}

scratch_relative() {
  case "$1" in
    "$scratch"/*) /usr/bin/printf '%s\n' "${1#"$scratch/"}" ;;
    *) return 1 ;;
  esac
}

scratch_prepare_capture() {
  local output=$1 error=$2 receipt=$3
  if { [ "$output" != - ] &&
       { [ "$output" = "$error" ] || [ "$output" = "$receipt" ]; }; } ||
     { [ "$error" != - ] && [ "$error" = "$receipt" ]; }; then
    return 125
  fi
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MCwd=abs_path -e '
      use strict; use warnings;
      my ($root,$expected,@names)=@ARGV;
      my ($p_dev,$p_ino,$d_dev,$d_ino)=split(/:/,$expected,4);
      my ($parent,$name)=$root =~ m{\A(.+)/([^/]+)\z};
      exit 125 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      opendir(my $parent_dh,$parent) or exit 125;
      my @parent_st=stat($parent_dh);
      exit 125 unless @parent_st && S_ISDIR($parent_st[2]) &&
        $parent_st[0]==$p_dev && $parent_st[1]==$p_ino;
      chdir($parent_dh) or exit 125;
      my @root_named=lstat($name);
      exit 125 unless @root_named && S_ISDIR($root_named[2]) &&
        $root_named[0]==$d_dev && $root_named[1]==$d_ino;
      opendir(my $root_dh,$name) or exit 125;
      my @root_opened=stat($root_dh);
      exit 125 unless @root_opened && S_ISDIR($root_opened[2]) &&
        $root_opened[0]==$d_dev && $root_opened[1]==$d_ino;
      sub create_output {
        my ($root_handle,$relative)=@_;
        return "-" if $relative eq "-";
        exit 125 unless $relative =~ m{\A[^/]+(?:/[^/]+)*\z};
        chdir($root_handle) or exit 125;
        my @parts=split(m{/},$relative); my $leaf=pop @parts;
        for my $component (@parts) {
          exit 125 if $component eq "." or $component eq "..";
          my @named=lstat($component);
          exit 125 unless @named && S_ISDIR($named[2]);
          opendir(my $next,$component) or exit 125;
          my @opened=stat($next);
          exit 125 unless @opened && S_ISDIR($opened[2]) &&
            $opened[0]==$named[0] && $opened[1]==$named[1];
          chdir($next) or exit 125;
        }
        exit 125 if $leaf eq "." or $leaf eq "..";
        sysopen(my $file,$leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or
          exit 125;
        my @opened=stat($file);
        exit 125 unless @opened && S_ISREG($opened[2]) && $opened[7]==0;
        close($file) or exit 125;
        return $opened[0].":".$opened[1];
      }
      print join(" ",map {create_output($root_dh,$_)} @names),"\n";
    ' "$scratch" "$SCRATCH_ID" "$output" "$error" "$receipt"
}

scratch_prepare_capture_keys() {
  local prepared remainder
  prepared=$(scratch_prepare_capture "$1" "$2" "$3") || return 125
  case "$prepared" in *' '*' '*) ;; *) return 125 ;; esac
  CAPTURE_OUTPUT_KEY=${prepared%% *}
  remainder=${prepared#* }
  CAPTURE_ERROR_KEY=${remainder%% *}
  CAPTURE_RECEIPT_KEY=${remainder#* }
  case "$CAPTURE_RECEIPT_KEY" in *' '*) return 125 ;; esac
  [ -n "$CAPTURE_OUTPUT_KEY" ] && [ -n "$CAPTURE_ERROR_KEY" ] &&
    [ -n "$CAPTURE_RECEIPT_KEY" ]
}

scratch_capture_prepared() {
  local output=$1 output_key=$2 error=$3 error_key=$4
  local receipt=$5 receipt_key=$6 input=$7 input_identity=$8 payload_sha=$9
  shift 9
  [ "$#" -gt 0 ] || return 125
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path \
      -MPOSIX=_exit,dup2 -e '
      use strict; use warnings;
      my ($root,$expected,$stdout_name,$stdout_key,$stderr_name,$stderr_key,
        $receipt_name,$receipt_key,$stdin_name,$stdin_identity,$payload_sha,
        @command)=@ARGV;
      exit 125 unless @command;
      my ($p_dev,$p_ino,$d_dev,$d_ino)=split(/:/,$expected,4);
      my ($parent,$name)=$root =~ m{\A(.+)/([^/]+)\z};
      exit 125 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      opendir(my $parent_dh,$parent) or exit 125;
      my @parent_st=stat($parent_dh);
      exit 125 unless @parent_st && S_ISDIR($parent_st[2]) &&
        $parent_st[0]==$p_dev && $parent_st[1]==$p_ino;
      chdir($parent_dh) or exit 125;
      my @root_named=lstat($name);
      exit 125 unless @root_named && S_ISDIR($root_named[2]) &&
        $root_named[0]==$d_dev && $root_named[1]==$d_ino;
      opendir(my $root_dh,$name) or exit 125;
      my @root_opened=stat($root_dh);
      exit 125 unless @root_opened && S_ISDIR($root_opened[2]) &&
        $root_opened[0]==$d_dev && $root_opened[1]==$d_ino;
      sub open_output {
        my ($root_handle,$relative,$key)=@_;
        if ($relative eq "-") {
          exit 125 unless $key eq "-";
          sysopen(my $null,"/dev/null",O_WRONLY|O_NOFOLLOW) or exit 125;
          return $null;
        }
        exit 125 unless $relative =~ m{\A[^/]+(?:/[^/]+)*\z} &&
          $key =~ m{\A[0-9]+:[0-9]+\z};
        my ($dev,$ino)=split(/:/,$key,2);
        chdir($root_handle) or exit 125;
        my @parts=split(m{/},$relative); my $leaf=pop @parts;
        for my $component (@parts) {
          exit 125 if $component eq "." or $component eq "..";
          my @named=lstat($component);
          exit 125 unless @named && S_ISDIR($named[2]);
          opendir(my $next,$component) or exit 125;
          my @opened=stat($next);
          exit 125 unless @opened && S_ISDIR($opened[2]) &&
            $opened[0]==$named[0] && $opened[1]==$named[1];
          chdir($next) or exit 125;
        }
        my @named=lstat($leaf);
        exit 125 unless @named && S_ISREG($named[2]) &&
          $named[0]==$dev && $named[1]==$ino && $named[7]==0;
        sysopen(my $file,$leaf,O_WRONLY|O_NOFOLLOW) or exit 125;
        my @opened=stat($file);
        exit 125 unless @opened && S_ISREG($opened[2]) &&
          $opened[0]==$dev && $opened[1]==$ino && $opened[7]==0;
        return $file;
      }
      sub extract_payload {
        my ($text)=@_; my @spec=(
          ["# YSTACK_EVIDENCE_PAYLOAD_SHARED_BEGIN\n",
           "# YSTACK_EVIDENCE_PAYLOAD_SHARED_END\n"],
          ["# YSTACK_EVIDENCE_PAYLOAD_CLEANUP_BEGIN\n",
           "# YSTACK_EVIDENCE_PAYLOAD_CLEANUP_END\n"],
          ["# YSTACK_EVIDENCE_PAYLOAD_WORKER_BEGIN\n",
           "# YSTACK_EVIDENCE_PAYLOAD_WORKER_END\n"]);
        my @lines=split(/(?<=\n)/,$text); my $payload=""; my $cursor=0;
        for my $pair (@spec) {
          my ($begin,$end)=@$pair;
          exit 125 unless grep({$_ eq $begin} @lines)==1 &&
            grep({$_ eq $end} @lines)==1;
          $cursor++ while $cursor<@lines && $lines[$cursor] ne $begin;
          exit 125 if $cursor>=@lines; $cursor++;
          while ($cursor<@lines && $lines[$cursor] ne $end) {
            $payload .= $lines[$cursor]; $cursor++;
          }
          exit 125 if $cursor>=@lines; $cursor++;
        }
        return $payload;
      }
      sub input_bytes {
        my ($root_handle,$relative,$identity,$expected_payload_sha)=@_;
        return undef if $relative eq "-" && $expected_payload_sha eq "-";
        exit 125 unless $relative =~ m{\A[^/]+(?:/[^/]+)*\z} &&
          $expected_payload_sha =~ m{\A[0-9a-f]{64}\z};
        my (undef,undef,$f_dev,$f_ino,$size,$mtime,$ctime,$digest)=
          split(/:/,$identity,8);
        chdir($root_handle) or exit 125;
        my @parts=split(m{/},$relative); my $leaf=pop @parts;
        for my $component (@parts) {
          my @named=lstat($component);
          exit 125 unless @named && S_ISDIR($named[2]);
          opendir(my $next,$component) or exit 125;
          my @opened=stat($next);
          exit 125 unless @opened && S_ISDIR($opened[2]) &&
            $opened[0]==$named[0] && $opened[1]==$named[1];
          chdir($next) or exit 125;
        }
        my @named=lstat($leaf);
        exit 125 unless @named && S_ISREG($named[2]) &&
          $named[0]==$f_dev && $named[1]==$f_ino && $named[7]==$size &&
          $named[9]==$mtime && $named[10]==$ctime;
        sysopen(my $file,$leaf,O_RDONLY|O_NOFOLLOW) or exit 125;
        my @opened=stat($file);
        exit 125 unless @opened && S_ISREG($opened[2]) &&
          $opened[0]==$f_dev && $opened[1]==$f_ino && $opened[7]==$size &&
          $opened[9]==$mtime && $opened[10]==$ctime;
        my $sha=Digest::SHA->new(256); my $total=0; my $text="";
        while (1) {
          my $read=sysread($file,my $buffer,65536);
          exit 125 unless defined $read; last if $read==0;
          $total += $read; exit 125 if $total > 1048576;
          $sha->add($buffer); $text .= $buffer;
        }
        my @after=stat($file); my @path_after=lstat($leaf);
        exit 125 unless $total==$size && $sha->hexdigest eq $digest &&
          @after && @path_after && $after[0]==$f_dev && $after[1]==$f_ino &&
          $path_after[0]==$f_dev && $path_after[1]==$f_ino;
        my $payload=extract_payload($text);
        exit 125 unless Digest::SHA::sha256_hex($payload) eq $expected_payload_sha;
        return $payload;
      }
      my $stdout=open_output($root_dh,$stdout_name,$stdout_key);
      my $stderr=open_output($root_dh,$stderr_name,$stderr_key);
      my $receipt=open_output($root_dh,$receipt_name,$receipt_key);
      my $stdin_text=input_bytes($root_dh,$stdin_name,$stdin_identity,$payload_sha);
      if (defined($stdin_text)) {
        pipe(my $reader,my $writer) or exit 125;
        my $writer_pid=fork(); exit 125 unless defined($writer_pid);
        if ($writer_pid==0) {
          close($reader); my $offset=0; my $length=length($stdin_text);
          while ($offset < $length) {
            my $written=syswrite($writer,$stdin_text,$length-$offset,$offset);
            _exit(125) unless defined($written) && $written>0;
            $offset += $written;
          }
          close($writer); _exit(0);
        }
        close($writer); open(STDIN,"<&",$reader) or exit 125; close($reader);
      } else {
        sysopen(my $null,"/dev/null",O_RDONLY|O_NOFOLLOW) or exit 125;
        open(STDIN,"<&",$null) or exit 125; close($null);
      }
      open(STDOUT,">&",$stdout) or exit 125;
      open(STDERR,">&",$stderr) or exit 125;
      my $receipt_fd=fileno($receipt);
      close($stdout); close($stderr); close($root_dh); close($parent_dh);
      dup2($receipt_fd,3)>=0 or exit 125;
      close($receipt) if $receipt_fd!=3;
      exec {$command[0]} @command; exit 126;
    ' "$scratch" "$SCRATCH_ID" "$output" "$output_key" "$error" \
      "$error_key" "$receipt" "$receipt_key" "$input" "$input_identity" \
      "$payload_sha" "$@"
}

scratch_capture() {
  local output=$1 error=$2 receipt=$3 input=$4 input_identity=$5 payload_sha=$6
  shift 6
  scratch_prepare_capture_keys "$output" "$error" "$receipt" || return 125
  scratch_capture_prepared "$output" "$CAPTURE_OUTPUT_KEY" \
    "$error" "$CAPTURE_ERROR_KEY" "$receipt" "$CAPTURE_RECEIPT_KEY" \
    "$input" "$input_identity" "$payload_sha" "$@"
}

capture_identity_for_key() {
  local path=$1 key=$2 limit=${3:-1048576} identity file_key
  [ "$key" != - ] || return 1
  identity=$(path_identity "$path" "$limit") || return 1
  file_key=$(/usr/bin/printf '%s\n' "$identity" | /usr/bin/awk -F: \
    'NF==8 {print $3":"$4}') || return 1
  [ "$file_key" = "$key" ] || return 1
  /usr/bin/printf '%s\n' "$identity"
}

capture_path_matches() {
  capture_identity_for_key "$@" >/dev/null
}

scratch_write_lines() {
  local target=$1
  shift
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MCwd=abs_path -e '
      use strict; use warnings;
      my ($root,$expected,$target,@lines)=@ARGV;
      my ($p_dev,$p_ino,$d_dev,$d_ino)=split(/:/,$expected,4);
      my ($parent,$name)=$root =~ m{\A(.+)/([^/]+)\z};
      exit 1 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent &&
        $target =~ m{\A[^/]+(?:/[^/]+)*\z};
      opendir(my $parent_dh,$parent) or exit 1;
      my @parent_st=stat($parent_dh);
      exit 1 unless @parent_st && S_ISDIR($parent_st[2]) &&
        $parent_st[0]==$p_dev && $parent_st[1]==$p_ino;
      chdir($parent_dh) or exit 1;
      my @root_named=lstat($name);
      exit 1 unless @root_named && S_ISDIR($root_named[2]) &&
        $root_named[0]==$d_dev && $root_named[1]==$d_ino;
      opendir(my $root_dh,$name) or exit 1;
      my @root_opened=stat($root_dh);
      exit 1 unless @root_opened && S_ISDIR($root_opened[2]) &&
        $root_opened[0]==$d_dev && $root_opened[1]==$d_ino;
      chdir($root_dh) or exit 1;
      my @parts=split(m{/},$target); my $leaf=pop @parts;
      for my $component (@parts) {
        exit 1 if $component eq "." or $component eq "..";
        my @named=lstat($component);
        exit 1 unless @named && S_ISDIR($named[2]);
        opendir(my $next,$component) or exit 1;
        my @opened=stat($next);
        exit 1 unless @opened && S_ISDIR($opened[2]) &&
          $opened[0]==$named[0] && $opened[1]==$named[1];
        chdir($next) or exit 1;
      }
      exit 1 if $leaf eq "." or $leaf eq "..";
      sysopen(my $file,$leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or exit 1;
      for my $line (@lines) { print {$file} $line,"\n" or exit 1; }
      close($file) or exit 1;
    ' "$scratch" "$SCRATCH_ID" "$target" "$@"
}

capture_identity_text() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
      use strict; use warnings;
      my ($path,$expected)=@ARGV;
      my ($p_dev,$p_ino,$f_dev,$f_ino,$size,$mtime,$ctime,$digest)=
        split(/:/,$expected,8);
      exit 2 if $size > 1048576;
      my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      my @parent=lstat($parent);
      exit 2 unless @parent && S_ISDIR($parent[2]) &&
        $parent[0]==$p_dev && $parent[1]==$p_ino;
      chdir($parent) or exit 2;
      my @cwd=stat("."); my @leaf=lstat($name);
      exit 2 unless @cwd && @leaf && S_ISREG($leaf[2]) &&
        $leaf[0]==$f_dev && $leaf[1]==$f_ino && $leaf[7]==$size &&
        $leaf[9]==$mtime && $leaf[10]==$ctime;
      sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
      binmode($input); my @opened=stat($input);
      exit 2 unless @opened && S_ISREG($opened[2]) &&
        $opened[0]==$f_dev && $opened[1]==$f_ino && $opened[7]==$size &&
        $opened[9]==$mtime && $opened[10]==$ctime;
      my $sha=Digest::SHA->new(256); my $text=""; my $total=0;
      while (1) {
        my $read=sysread($input,my $buffer,65536);
        exit 2 unless defined $read; last if $read==0;
        $total += $read; exit 2 if $total > 1048576;
        $sha->add($buffer); $text .= $buffer;
      }
      my @after=stat($input); my @path_after=lstat($name);
      my @parent_after=lstat($parent);
      exit 2 unless $total==$size && $sha->hexdigest eq $digest &&
        @after && @path_after && @parent_after && S_ISREG($path_after[2]) &&
        S_ISDIR($parent_after[2]) && $opened[0]==$after[0] &&
        $opened[1]==$after[1] && $opened[7]==$after[7] &&
        $opened[9]==$after[9] && $opened[10]==$after[10] &&
        $after[0]==$path_after[0] && $after[1]==$path_after[1] &&
        $cwd[0]==$parent_after[0] && $cwd[1]==$parent_after[1];
      print $text;
    ' "$1" "$2"
}

PINNED_PATHS=()
PINNED_IDENTITIES=()
pin_path() {
  local path=$1 limit=${2:-1048576} identity index=0 identity_status=0
  identity=$(path_identity "$path" "$limit") || identity_status=$?
  case "$identity_status" in
    0) ;;
    3) emit_error E_LIMIT ;;
    *) return 1 ;;
  esac
  while [ "$index" -lt "${#PINNED_PATHS[@]}" ]; do
    if [ "${PINNED_PATHS[$index]}" = "$path" ]; then
      [ "${PINNED_IDENTITIES[$index]}" = "$identity" ]
      return
    fi
    index=$((index + 1))
  done
  PINNED_PATHS[${#PINNED_PATHS[@]}]=$path
  PINNED_IDENTITIES[${#PINNED_IDENTITIES[@]}]=$identity
}
pinned_identity() {
  local path=$1 index=0
  while [ "$index" -lt "${#PINNED_PATHS[@]}" ]; do
    if [ "${PINNED_PATHS[$index]}" = "$path" ]; then
      /usr/bin/printf '%s\n' "${PINNED_IDENTITIES[$index]}"; return 0
    fi
    index=$((index + 1))
  done
  return 1
}
verify_all_pins() {
  local index=0 limit
  while [ "$index" -lt "${#PINNED_PATHS[@]}" ]; do
    limit=1048576
    [ "${PINNED_PATHS[$index]}" != "${live_jq_path:-}" ] || limit=16777216
    [ "${PINNED_PATHS[$index]}" != "${jq_bin:-}" ] || limit=16777216
    path_matches_identity "${PINNED_PATHS[$index]}" \
      "${PINNED_IDENTITIES[$index]}" "$limit" || return 1
    index=$((index + 1))
  done
}
sha256_path() {
  local identity
  pin_path "$1" || return 1
  identity=$(pinned_identity "$1") || return 1
  /usr/bin/printf '%s\n' "${identity##*:}"
}

payload_sha_from_identity() {
  local wrapped text sentinel=YSTACK_EVIDENCE_PAYLOAD_SENTINEL_9f41c2
  wrapped=$({
    capture_identity_text "$1" "$2" || exit 1
    /usr/bin/printf '%s' "$sentinel"
  }) || return 1
  case "$wrapped" in *"$sentinel") ;; *) return 1 ;; esac
  text=${wrapped%"$sentinel"}
  /usr/bin/printf '%s' "$text" | /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MDigest::SHA -e '
      use strict; use warnings; local $/; my $text=<STDIN>;
      my @spec=(
        ["# YSTACK_EVIDENCE_PAYLOAD_SHARED_BEGIN\n",
         "# YSTACK_EVIDENCE_PAYLOAD_SHARED_END\n"],
        ["# YSTACK_EVIDENCE_PAYLOAD_CLEANUP_BEGIN\n",
         "# YSTACK_EVIDENCE_PAYLOAD_CLEANUP_END\n"],
        ["# YSTACK_EVIDENCE_PAYLOAD_WORKER_BEGIN\n",
         "# YSTACK_EVIDENCE_PAYLOAD_WORKER_END\n"]);
      my @lines=split(/(?<=\n)/,$text); my $payload=""; my $cursor=0;
      for my $pair (@spec) {
        my ($begin,$end)=@$pair;
        exit 1 unless grep({$_ eq $begin} @lines)==1 &&
          grep({$_ eq $end} @lines)==1;
        $cursor++ while $cursor<@lines && $lines[$cursor] ne $begin;
        exit 1 if $cursor>=@lines; $cursor++;
        while ($cursor<@lines && $lines[$cursor] ne $end) {
          $payload .= $lines[$cursor]; $cursor++;
        }
        exit 1 if $cursor>=@lines; $cursor++;
      }
      print Digest::SHA::sha256_hex($payload),"\n";
    '
}
# YSTACK_EVIDENCE_PAYLOAD_SHARED_END

if [ -n "${YSTACK_EVIDENCE_STAGE+x}" ]; then silent_fail; fi
scratch=
SCRATCH_ID=
SCRATCH_OWNED=0
ACTIVE_PID=
ACTIVE_PGID=
# YSTACK_EVIDENCE_PAYLOAD_CLEANUP_BEGIN
cleanup() {
  [ -z "${scratch:-}" ] && return 0
  case "$scratch" in
    /*/ystack-evidence.??????|/*/ystack-evidence.??????/worker) ;;
    *) return 1 ;;
  esac
  [ "$SCRATCH_OWNED" -eq 1 ] && [ -n "$SCRATCH_ID" ] || return 1
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:mode -MCwd=abs_path -e '
      use strict; use warnings;
      my ($path,$expected)=@ARGV;
      my ($p_dev,$p_ino,$d_dev,$d_ino)=split(/:/,$expected,4);
      my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 1 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      opendir(my $parent_dh,$parent) or exit 1;
      my @parent_st=stat($parent_dh);
      exit 1 unless @parent_st && S_ISDIR($parent_st[2]) &&
        $parent_st[0]==$p_dev && $parent_st[1]==$p_ino;
      chdir($parent_dh) or exit 1;
      my @named=lstat($name);
      exit 1 unless @named && S_ISDIR($named[2]) &&
        $named[0]==$d_dev && $named[1]==$d_ino;
      opendir(my $root_dh,$name) or exit 1;
      my @opened=stat($root_dh);
      exit 1 unless @opened && S_ISDIR($opened[2]) &&
        $opened[0]==$d_dev && $opened[1]==$d_ino;

      sub empty_dir {
        my ($dh)=@_; chdir($dh) or return 0; rewinddir($dh);
        while (defined(my $entry=readdir($dh))) {
          next if $entry eq "." or $entry eq "..";
          my @before=lstat($entry); return 0 unless @before;
          if (S_ISDIR($before[2])) {
            opendir(my $child,$entry) or return 0;
            my @child_st=stat($child);
            return 0 unless @child_st && $child_st[0]==$before[0] &&
              $child_st[1]==$before[1] && empty_dir($child);
            chdir($dh) or return 0;
            my @after=lstat($entry);
            return 0 unless @after && S_ISDIR($after[2]) &&
              $after[0]==$before[0] && $after[1]==$before[1] && rmdir($entry);
          } else {
            return 0 unless unlink($entry);
          }
          chdir($dh) or return 0;
        }
        return 1;
      }

      exit 1 unless empty_dir($root_dh);
      chdir($parent_dh) or exit 1;
      my @final=lstat($name);
      exit 1 unless @final && S_ISDIR($final[2]) &&
        $final[0]==$d_dev && $final[1]==$d_ino && rmdir($name);
      exit 1 if lstat($name);
    ' "$scratch" "$SCRATCH_ID" >/dev/null 2>&1 || return 1
  [ ! -e "$scratch" ] && [ ! -L "$scratch" ]
}
# YSTACK_EVIDENCE_PAYLOAD_CLEANUP_END
group_live_count() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  /bin/ps -axo pgid=,state= 2>/dev/null | /usr/bin/awk -v group="$1" '
    $1==group && $2!~/^Z/ {count+=1} END {print count+0}'
}
leader_state() {
  /bin/ps -o state= -p "$1" 2>/dev/null | /usr/bin/tr -d ' '
}
terminate_active() {
  local group=${ACTIVE_PGID:-} leader=${ACTIVE_PID:-} state count attempt=0
  [[ "$group" =~ ^[1-9][0-9]*$ ]] && [[ "$leader" =~ ^[1-9][0-9]*$ ]] ||
    return 1
  /bin/kill -TERM -- "-$group" 2>/dev/null || :
  state=$(leader_state "$leader") || state=
  while [ -n "$state" ] && [[ "$state" != Z* ]] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1)); /bin/sleep 0.01
    state=$(leader_state "$leader") || state=
  done
  count=$(group_live_count "$group") || return 1
  if { [ -n "$state" ] && [[ "$state" != Z* ]]; } || [ "$count" -gt 0 ]; then
    /bin/kill -KILL -- "-$group" 2>/dev/null || :
  fi
  wait "$leader" 2>/dev/null || :
  state=$(leader_state "$leader") || state=
  [ -z "$state" ] || return 1
  attempt=0; count=$(group_live_count "$group") || return 1
  while [ "$count" -gt 0 ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1)); /bin/sleep 0.01
    count=$(group_live_count "$group") || return 1
  done
  [ "$count" -eq 0 ] || return 1
  ACTIVE_PID=; ACTIVE_PGID=
}
signal_exit() {
  local status=${1:-1}
  exec >/dev/null 2>&1
  if [ -n "${ACTIVE_PGID:-}" ] && ! terminate_active; then
    terminal_teardown_fail
  fi
  cleanup || status=125
  trap - EXIT HUP INT TERM
  exit "$status"
}
PENDING_SIGNAL=0
arm_signal_traps() {
  trap cleanup EXIT
  trap 'signal_exit 129' HUP
  trap 'signal_exit 130' INT
  trap 'signal_exit 143' TERM
}
defer_signal_traps() {
  PENDING_SIGNAL=0
  trap 'PENDING_SIGNAL=129' HUP
  trap 'PENDING_SIGNAL=130' INT
  trap 'PENDING_SIGNAL=143' TERM
}
kill_unregistered_child() {
  local child=$1 state attempt=0
  /bin/kill -TERM "$child" 2>/dev/null || :
  state=$(leader_state "$child") || state=
  while [ -n "$state" ] && [[ "$state" != Z* ]] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1)); /bin/sleep 0.01
    state=$(leader_state "$child") || state=
  done
  if [ -n "$state" ] && [[ "$state" != Z* ]]; then
    /bin/kill -KILL "$child" 2>/dev/null || :
  fi
  wait "$child" 2>/dev/null || :
  state=$(leader_state "$child") || state=
  [ -z "$state" ]
}
arm_signal_traps

run_child() {
  local child pgid state attempt=0 child_status=0 count self_pgid
  [ -z "${ACTIVE_PID:-}" ] && [ -z "${ACTIVE_PGID:-}" ] || return 125
  defer_signal_traps
  self_pgid=$(/bin/ps -o pgid= -p "$$" 2>/dev/null | /usr/bin/tr -d ' ') || {
    arm_signal_traps
    [ "$PENDING_SIGNAL" -eq 0 ] || signal_exit "$PENDING_SIGNAL"
    return 125
  }
  if ! [[ "$self_pgid" =~ ^[1-9][0-9]*$ ]]; then
    arm_signal_traps
    [ "$PENDING_SIGNAL" -eq 0 ] || signal_exit "$PENDING_SIGNAL"
    return 125
  fi
  set -m
  "$@" &
  child=$!
  set +m
  while [ "$attempt" -lt 100 ]; do
    pgid=$(/bin/ps -o pgid= -p "$child" 2>/dev/null | /usr/bin/tr -d ' ') || pgid=
    if [[ "$pgid" =~ ^[1-9][0-9]*$ ]] && [ "$pgid" = "$child" ] &&
       [ "$pgid" != "$self_pgid" ]; then break; fi
    state=$(leader_state "$child") || state=
    [ -n "$state" ] && [[ "$state" != Z* ]] || break
    attempt=$((attempt + 1)); /bin/sleep 0.01
  done
  if ! [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$child" ] ||
     [ "$pgid" = "$self_pgid" ]; then
    kill_unregistered_child "$child" || terminal_teardown_fail
    arm_signal_traps
    [ "$PENDING_SIGNAL" -eq 0 ] || signal_exit "$PENDING_SIGNAL"
    return 125
  fi
  ACTIVE_PID=$child; ACTIVE_PGID=$pgid
  arm_signal_traps
  [ "$PENDING_SIGNAL" -eq 0 ] || signal_exit "$PENDING_SIGNAL"
  attempt=0
  state=$(leader_state "$child") || state=
  while [ -n "$state" ] && [[ "$state" != Z* ]] && [ "$attempt" -lt 1000 ]; do
    attempt=$((attempt + 1)); /bin/sleep 0.01
    state=$(leader_state "$child") || state=
  done
  if [ -n "$state" ] && [[ "$state" != Z* ]]; then
    terminate_active || return 125
    return 124
  fi
  wait "$child" || child_status=$?
  count=$(group_live_count "$pgid") || {
    terminate_active || return 125
    return 125
  }
  if [ "$count" -ne 0 ]; then
    ACTIVE_PID=$child; ACTIVE_PGID=$pgid
    terminate_active || return 125
    return 125
  fi
  ACTIVE_PID=; ACTIVE_PGID=
  return "$child_status"
}

emit_supervisor_failure() {
  local token=${1:-E_RUNTIME}
  case "$token" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_RELATION|E_POLICY_SET|E_CORE) ;;
    *) token=E_RUNTIME ;;
  esac
  if cleanup; then trap - EXIT HUP INT TERM; /usr/bin/printf '%s\n' "$token" >&2; fi
  exit 1
}

bootstrap_prepare() {
[ "$#" -eq 6 ] && [ "$1" = evaluate ] || emit_error E_USAGE
normalized_args=(evaluate)
for input in "${@:2}"; do
  case "$input" in /*) ;; *) input="$(pwd -P)/$input" ;; esac
  input_parent=$(CDPATH='' cd -P -- "${input%/*}" 2>/dev/null && pwd -P) ||
    emit_error E_RUNTIME
  input="$input_parent/${input##*/}"
  physical_regular "$input" || emit_error E_RUNTIME
  normalized_args+=("$input")
done
origin=${BASH_SOURCE[0]}
case "$origin" in /*) ;; *) origin="$(pwd -P)/$origin" ;; esac
origin_dir=$(CDPATH='' cd -P -- "${origin%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
origin="$origin_dir/${origin##*/}"
[ "$origin" = "$origin_dir/evaluate-evidence-integrity.sh" ] || emit_error E_RUNTIME
origin_identity=$(path_identity "$origin" 1048576) || emit_error E_RUNTIME
live_jq=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$live_jq" in /*) ;; *) emit_error E_RUNTIME ;; esac
live_jq_parent=$(CDPATH='' cd -P -- "${live_jq%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
live_jq="$live_jq_parent/${live_jq##*/}"
physical_regular "$live_jq" || emit_error E_RUNTIME
live_jq_identity=$(path_identity "$live_jq" 16777216) || emit_error E_RUNTIME
expected_jq=$(expected_jq_digest) || emit_error E_RUNTIME
[ "${live_jq_identity##*:}" = "$expected_jq" ] || emit_error E_RUNTIME
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evidence.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
SCRATCH_ID=$(directory_identity "$scratch") || emit_error E_RUNTIME
SCRATCH_OWNED=1
scratch_mkdirs bin io worker || emit_error E_RUNTIME
worker_scratch="$scratch/worker"
worker_scratch_id=$(directory_identity "$worker_scratch") || emit_error E_RUNTIME
source_path="$scratch/driver.sh"
jq_bin="$scratch/bin/jq"
snapshot_nofollow "$origin" "$origin_identity" "$source_path" 1048576 0500 ||
  emit_error E_RUNTIME
private_driver_identity=$(path_identity "$source_path" 1048576) ||
  emit_error E_RUNTIME
private_payload_sha=$(payload_sha_from_identity "$source_path" \
  "$private_driver_identity") || emit_error E_RUNTIME
snapshot_nofollow "$live_jq" "$live_jq_identity" "$jq_bin" 16777216 0500 ||
  emit_error E_RUNTIME
private_jq_identity=$(path_identity "$jq_bin" 16777216) || emit_error E_RUNTIME

[ -n "$scratch" ] || emit_error E_RUNTIME
case "$scratch" in /*/ystack-evidence.??????) ;; *) emit_error E_RUNTIME ;; esac
if [ -z "$SCRATCH_ID" ] ||
   ! directory_matches_identity "$scratch" "$SCRATCH_ID"; then
  emit_error E_RUNTIME
fi
SCRATCH_OWNED=1
[ "$source_path" = "$scratch/driver.sh" ] && [ "$jq_bin" = "$scratch/bin/jq" ] ||
  emit_error E_RUNTIME
origin_id=$origin_identity
private_driver_id=$private_driver_identity
live_jq_path=$live_jq
live_jq_id=$live_jq_identity
private_jq_id=$private_jq_identity
PINNED_PATHS=("$origin" "$source_path" "$live_jq_path" "$jq_bin")
PINNED_IDENTITIES=("$origin_id" "$private_driver_id" "$live_jq_id" "$private_jq_id")
for input in "${normalized_args[@]:1}"; do
  pin_path "$input" || emit_error E_RUNTIME
done
for internal_identity in "${PINNED_IDENTITIES[@]}"; do
  [ -n "$internal_identity" ] || emit_error E_RUNTIME
done
expected_jq=$(expected_jq_digest) || emit_error E_RUNTIME
[ "${origin_id##*:}" = "${private_driver_id##*:}" ] || emit_error E_RUNTIME
[ "${live_jq_id##*:}" = "$expected_jq" ] &&
  [ "${private_jq_id##*:}" = "$expected_jq" ] ||
  emit_error E_RUNTIME
if ! private_mode_ok "$source_path" || ! private_mode_ok "$jq_bin"; then
  emit_error E_RUNTIME
fi
verify_all_pins || emit_error E_RELATION
}

supervisor_main() {
  worker_status=0
  scratch_prepare_capture_keys io/worker.out io/worker.err - ||
    emit_supervisor_failure E_RUNTIME
  worker_output_key=$CAPTURE_OUTPUT_KEY
  worker_error_key=$CAPTURE_ERROR_KEY
  run_child scratch_capture_prepared io/worker.out "$worker_output_key" \
    io/worker.err "$worker_error_key" - - driver.sh "$private_driver_id" \
    "$private_payload_sha" /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    TMPDIR="$scratch" HOME=/nonexistent /bin/bash -c \
    'source /dev/stdin || exit 125; worker_entry "$@"' ystack-evidence-worker \
    "$worker_scratch" "$worker_scratch_id" "$origin" "$origin_id" "$source_path" \
    "$private_driver_id" "$private_payload_sha" "$live_jq_path" "$live_jq_id" \
    "$jq_bin" "$private_jq_id" "$@" ||
    worker_status=$?
  if [ -n "${ACTIVE_PGID:-}" ] || [ -n "${ACTIVE_PID:-}" ]; then
    signal_exit 125
  fi
  error_identity=$(capture_identity_for_key "$scratch/io/worker.err" \
    "$worker_error_key") ||
    emit_supervisor_failure E_RUNTIME
  error_text=$(capture_identity_text "$scratch/io/worker.err" "$error_identity") ||
    emit_supervisor_failure E_RUNTIME
  capture_path_matches "$scratch/io/worker.err" "$worker_error_key" ||
    emit_supervisor_failure E_RUNTIME
  if [ "$worker_status" -ne 0 ]; then emit_supervisor_failure "$error_text"; fi
  [ -z "$error_text" ] || emit_supervisor_failure E_RUNTIME
  worker_output_identity=$(capture_identity_for_key "$scratch/io/worker.out" \
    "$worker_output_key") ||
    emit_supervisor_failure E_RUNTIME
  worker_output_text=$(capture_identity_text "$scratch/io/worker.out" \
    "$worker_output_identity") || emit_supervisor_failure E_RUNTIME
  [ -n "$worker_output_text" ] || emit_supervisor_failure E_RUNTIME
  capture_path_matches "$scratch/io/worker.out" "$worker_output_key" ||
    emit_supervisor_failure E_RUNTIME
  policy_set_expected=$(pinned_identity "$2") || emit_supervisor_failure E_RUNTIME
  request_expected=$(pinned_identity "$3") || emit_supervisor_failure E_RUNTIME
  resolved_expected=$(pinned_identity "$4") || emit_supervisor_failure E_RUNTIME
  result_expected=$(pinned_identity "$5") || emit_supervisor_failure E_RUNTIME
  presentation_expected=$(pinned_identity "$6") || emit_supervisor_failure E_RUNTIME
  worker_canonical=$("$jq_bin" -S -c . "$scratch/io/worker.out" 2>/dev/null) ||
    emit_supervisor_failure E_RUNTIME
  [ "$worker_canonical" = "$worker_output_text" ] ||
    emit_supervisor_failure E_RUNTIME
  "$jq_bin" -e --arg policy_set_sha "${policy_set_expected##*:}" \
    --arg request_sha "${request_expected##*:}" \
    --arg resolved_sha "${resolved_expected##*:}" \
    --arg result_sha "${result_expected##*:}" \
    --arg presentation_sha "${presentation_expected##*:}" '
    (keys|sort)==["body","id","kind","schema_version"] and
    .schema_version==1 and .kind=="evidence_integrity_evaluation" and
    .body.activation_state=="inactive" and .body.authority_effect=="none" and
    .body.storage_effect=="none" and
    .body.policy_set.sha256==$policy_set_sha and
    .body.stage.request_ref.sha256==$request_sha and
    .body.stage.resolved_profile_ref.sha256==$resolved_sha and
    .body.stage.result_ref.sha256==$result_sha and
    .body.presentation_ref.sha256==$presentation_sha and
    (.body.verdict=="satisfied" or .body.verdict=="violated") and
    ((.body|has("grant_ref") or has("qualification_ref") or has("activation") or
      has("credential") or has("network") or has("candidate_execution"))|not)
  ' "$scratch/io/worker.out" >/dev/null 2>&1 || emit_supervisor_failure E_RUNTIME
  capture_path_matches "$scratch/io/worker.out" "$worker_output_key" ||
    emit_supervisor_failure E_RUNTIME
  output_text=$worker_output_text
  verify_all_pins || emit_supervisor_failure E_RELATION
  if ! cleanup; then exit 1; fi
  trap - EXIT HUP INT TERM
  /usr/bin/printf '%s\n' "$output_text" || exit 1
  exit 0
}

# YSTACK_EVIDENCE_PAYLOAD_WORKER_BEGIN
worker_entry() {
  [ "$#" -eq 17 ] || silent_fail
  trap - EXIT HUP INT TERM
  scratch=$1
  SCRATCH_ID=$2
  origin=$3
  origin_id=$4
  source_path=$5
  private_driver_id=$6
  private_payload_sha=$7
  live_jq_path=$8
  live_jq_id=$9
  jq_bin=${10}
  private_jq_id=${11}
  shift 11
  SCRATCH_OWNED=0
  ACTIVE_PID=
  ACTIVE_PGID=
  [ "$#" -eq 6 ] && [ "$1" = evaluate ] || silent_fail
  case "$scratch" in /*/ystack-evidence.??????/worker) ;; *) silent_fail ;; esac
  directory_matches_identity "$scratch" "$SCRATCH_ID" || silent_fail
  SCRATCH_OWNED=1
  outer_scratch=${scratch%/worker}
  [ "$source_path" = "$outer_scratch/driver.sh" ] &&
    [ "$jq_bin" = "$outer_scratch/bin/jq" ] || emit_error E_RUNTIME
  PINNED_PATHS=("$origin" "$source_path" "$live_jq_path" "$jq_bin")
  PINNED_IDENTITIES=("$origin_id" "$private_driver_id" "$live_jq_id" "$private_jq_id")
  expected_jq=$(expected_jq_digest) || emit_error E_RUNTIME
  [ "${origin_id##*:}" = "${private_driver_id##*:}" ] &&
    [ "${live_jq_id##*:}" = "$expected_jq" ] &&
    [ "${private_jq_id##*:}" = "$expected_jq" ] || emit_error E_RUNTIME
  if ! private_mode_ok "$source_path" || ! private_mode_ok "$jq_bin"; then
    emit_error E_RUNTIME
  fi
  observed_payload_sha=$(payload_sha_from_identity "$source_path" \
    "$private_driver_id") || emit_error E_RUNTIME
  [ "$observed_payload_sha" = "$private_payload_sha" ] || emit_error E_RUNTIME
  verify_all_pins || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
ulimit -f 2048 || emit_error E_RUNTIME

shift
source_dir=$(CDPATH='' cd -P -- "${origin%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$origin" = "$source_dir/evaluate-evidence-integrity.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
policy="$source_dir/evidence-integrity-policy.json"
decision="$source_dir/evidence-integrity-decision.json"
program="$source_dir/evidence-integrity.jq"
policy_validator="$source_dir/validate.sh"
validator_program="$source_dir/policy-set.jq"
core_driver="$repo/scripts/core-contract.sh"
for required in "$source_path" "$origin" "$policy" "$decision" "$program" \
  "$policy_validator" "$validator_program" "$core_driver" "$@"; do
  pin_path "$required" || emit_error E_RUNTIME
done

sha256_text() {
  /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}
selected_core_generation() {
  local wrapper=$1 selected assignment_count
  assignment_count=$(/usr/bin/grep -Ec \
    '^[[:space:]]*PORTABLE_CORE_GENERATION=' "$wrapper") || return 1
  [ "$assignment_count" -eq 1 ] || return 1
  selected=$(/usr/bin/sed -n \
    "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
    "$wrapper") || return 1
  [[ "$selected" =~ ^g-[0-9a-f]{64}$ ]] || return 1
  /usr/bin/printf '%s\n' "$selected"
}

snapshot_fixed() {
  local source=$1 target=$2 expected
  pin_path "$source" || emit_error E_RUNTIME
  expected=$(pinned_identity "$source") || emit_error E_RUNTIME
  snapshot_nofollow "$source" "$expected" "$target" 1048576 0600 ||
    emit_error E_RUNTIME
  pin_path "$target" || emit_error E_RUNTIME
}
snapshot_executable() {
  local source=$1 target=$2 expected
  pin_path "$source" || emit_error E_RUNTIME
  expected=$(pinned_identity "$source") || emit_error E_RUNTIME
  snapshot_nofollow "$source" "$expected" "$target" 1048576 0500 ||
    emit_error E_RUNTIME
  pin_path "$target" || emit_error E_RUNTIME
}
canonical_json() {
  local input=$1 canonical=$2 canonical_relative bom canonical_identity input_identity
  bom=$(/usr/bin/od -An -tx1 -N3 "$input" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" -e 'true' "$input" </dev/null >/dev/null 2>&1 || emit_error E_PARSE
  "$jq_bin" -s -e 'length==1' "$input" </dev/null >/dev/null 2>&1 ||
    emit_error E_PARSE
  canonical_relative=$(scratch_relative "$canonical") || emit_error E_RUNTIME
  scratch_capture "$canonical_relative" - - - - - "$jq_bin" -S -c . "$input" ||
    emit_error E_PARSE
  canonical_identity=$(capture_identity_for_key "$canonical" \
    "$CAPTURE_OUTPUT_KEY") || emit_error E_RUNTIME
  input_identity=$(path_identity "$input" 1048576) || emit_error E_RUNTIME
  [ "${canonical_identity##*:}" = "${input_identity##*:}" ] ||
    emit_error E_CANONICAL
  capture_path_matches "$canonical" "$CAPTURE_OUTPUT_KEY" || emit_error E_RUNTIME
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
  ' "$input" >/dev/null 2>&1 || emit_error E_LIMIT
}
validator_pair_ok() {
  local pair_dir=$1 driver=$2 validator_jq=$3 expected_driver=$4 expected_program=$5
  local physical_dir
  [ -d "$pair_dir" ] && [ ! -L "$pair_dir" ] || return 1
  physical_dir=$(CDPATH='' cd -P -- "$pair_dir" 2>/dev/null && pwd -P) || return 1
  [ "$physical_dir" = "$pair_dir" ] &&
    [ "$driver" = "$pair_dir/validate.sh" ] &&
    [ "$validator_jq" = "$pair_dir/policy-set.jq" ] &&
    [ -f "$driver" ] && [ ! -L "$driver" ] &&
    [ -f "$validator_jq" ] && [ ! -L "$validator_jq" ] &&
    [ "$(sha256_path "$driver")" = "$expected_driver" ] &&
    [ "$(sha256_path "$validator_jq")" = "$expected_program" ]
}
build_validator_mirror() {
  local mirror="$scratch/policy-validator/control/v1" source target
  scratch_mkdirs policy-validator/control/v1 || return 1
  for source in "$policy_validator" "$validator_program"; do
    target="$mirror/${source##*/}"
    case "$source" in
      "$policy_validator") snapshot_executable "$source" "$target" ;;
      *) snapshot_fixed "$source" "$target" ;;
    esac
  done
  /usr/bin/printf '%s\n' "$mirror"
}
core_closure_sha() {
  local root=$1 wrapper=$2 selected=$3 tag=$4 registry generation_root canonical
  local relative file digest members descriptor physical selected_sha count modules
  local members_identity members_text canonical_identity registry_identity
  local -a paths member_lines
  registry="$root/core/v2/generation-registry.json"
  generation_root="$root/core/v2/generations/$selected"
  for required_dir in "$root" "$root/scripts" "$root/core" "$root/core/v2" \
    "$root/core/v2/generations" "$generation_root" "$generation_root/modules"; do
    [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || return 1
    physical=$(CDPATH='' cd -P -- "$required_dir" 2>/dev/null && pwd -P) || return 1
    [ "$physical" = "$required_dir" ] || return 1
  done
  [ "$wrapper" = "$root/scripts/core-contract.sh" ] || return 1
  [ "$(selected_core_generation "$wrapper")" = "$selected" ] || return 1
  count=$(/usr/bin/find "$generation_root" -mindepth 1 -maxdepth 1 -print 2>/dev/null |
    /usr/bin/wc -l | /usr/bin/tr -d ' ') || return 1
  modules=$(/usr/bin/find "$generation_root/modules" -mindepth 1 -maxdepth 1 \
    -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || return 1
  [ "$count" -eq 3 ] && [ "$modules" -eq 5 ] || return 1
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  canonical="$scratch/registry-$tag.json"
  scratch_capture "registry-$tag.json" - - - - - "$jq_bin" -s -S -c \
    'if length==1 then .[0] else error("root-count") end' "$registry" || return 1
  canonical_identity=$(capture_identity_for_key "$canonical" \
    "$CAPTURE_OUTPUT_KEY") || return 1
  registry_identity=$(path_identity "$registry" 1048576) || return 1
  [ "${canonical_identity##*:}" = "${registry_identity##*:}" ] || return 1
  capture_path_matches "$canonical" "$CAPTURE_OUTPUT_KEY" || return 1
  "$jq_bin" -e --arg selected "$selected" '
    type=="array" and length>=1 and
    ([.[]|select(.generation_id==$selected and .semantic_identity=="core.contracts.v2")]
      |length)==1
  ' "$registry" >/dev/null 2>&1 || return 1
  paths=(
    scripts/core-contract.sh
    core/v2/generation-registry.json
    "core/v2/generations/$selected/contracts.jq"
    "core/v2/generations/$selected/core-ingress.sh"
    "core/v2/generations/$selected/modules/profile_graph.jq"
    "core/v2/generations/$selected/modules/result_facts.jq"
    "core/v2/generations/$selected/modules/result_truth.jq"
    "core/v2/generations/$selected/modules/schema.jq"
    "core/v2/generations/$selected/modules/stage_request.jq"
  )
  members="$scratch/core-members-$tag.tsv"
  member_lines=()
  for relative in "${paths[@]}"; do
    file="$root/$relative"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    digest=$(sha256_path "$file") || return 1
    member_lines[${#member_lines[@]}]="$relative"$'\t'"$digest"
  done
  scratch_write_lines "core-members-$tag.tsv" "${member_lines[@]}" || return 1
  pin_path "$members" || return 1
  members_identity=$(pinned_identity "$members") || return 1
  members_text=$(capture_identity_text "$members" "$members_identity") || return 1
  selected_sha=$(sha256_text "$selected") || return 1
  descriptor=$("$jq_bin" -Rn -S -c --arg selected_sha "$selected_sha" \
    --arg members "$members_text" '
    ($members|split("\n")|map(select(length>0)|split("\t")|
      {path:.[0],sha256:.[1]})) as $members |
    {schema_version:1,kind:"core_contract_package_closure",
     semantic_identity:"core.contracts.v2",
     selected_generation_id_sha256:$selected_sha,members:$members}
  ') || return 1
  sha256_text "$descriptor"
}
build_core_mirror() {
  local selected=$1 mirror="$scratch/core-package" relative source target
  local -a paths
  scratch_mkdirs core-package/scripts \
    "core-package/core/v2/generations/$selected/modules" ||
    return 1
  paths=(
    scripts/core-contract.sh
    core/v2/generation-registry.json
    "core/v2/generations/$selected/contracts.jq"
    "core/v2/generations/$selected/core-ingress.sh"
    "core/v2/generations/$selected/modules/profile_graph.jq"
    "core/v2/generations/$selected/modules/result_facts.jq"
    "core/v2/generations/$selected/modules/result_truth.jq"
    "core/v2/generations/$selected/modules/schema.jq"
    "core/v2/generations/$selected/modules/stage_request.jq"
  )
  for relative in "${paths[@]}"; do
    source="$repo/$relative"
    target="$mirror/$relative"
    case "$relative" in
      scripts/core-contract.sh) snapshot_executable "$source" "$target" ;;
      *) snapshot_fixed "$source" "$target" ;;
    esac
  done
  /usr/bin/printf '%s\n' "$mirror"
}
pin_core_package() {
  local root=$1 selected=$2 relative
  local -a paths
  paths=(
    scripts/core-contract.sh
    core/v2/generation-registry.json
    "core/v2/generations/$selected/contracts.jq"
    "core/v2/generations/$selected/core-ingress.sh"
    "core/v2/generations/$selected/modules/profile_graph.jq"
    "core/v2/generations/$selected/modules/result_facts.jq"
    "core/v2/generations/$selected/modules/result_truth.jq"
    "core/v2/generations/$selected/modules/schema.jq"
    "core/v2/generations/$selected/modules/stage_request.jq"
  )
  for relative in "${paths[@]}"; do pin_path "$root/$relative" || return 1; done
}
fixed_files_ok() {
  [ "$(sha256_path "$source_path")" = "$launcher_sha" ] &&
    [ "$(payload_sha_from_identity "$source_path" "$private_driver_id")" = \
      "$payload_sha" ] &&
    [ "$(sha256_path "$program")" = "$program_sha" ] &&
    [ "$(sha256_path "$policy")" = "$policy_sha" ] &&
    [ "$(sha256_path "$decision")" = "$decision_sha" ]
}

names=(policy-set request resolved result presentation)
index=0
for input in "$@"; do
  snapshot_fixed "$input" "$scratch/${names[$index]}.json"
  canonical_json "$scratch/${names[$index]}.json" \
    "$scratch/${names[$index]}.canonical" || emit_error E_RELATION
  index=$((index + 1))
done
"$jq_bin" -e '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="evidence_integrity_presentation" and
  (.id|type=="string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")) and
  (.body|type=="object")
' "$scratch/presentation.json" >/dev/null 2>&1 || emit_error E_RELATION
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$program" "$scratch/program.jq"
canonical_json "$scratch/policy.json" "$scratch/policy.canonical" ||
  emit_error E_RELATION
canonical_json "$scratch/decision.json" "$scratch/decision.canonical" ||
  emit_error E_RELATION
for control_dir in "$repo/control" "$source_dir"; do
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || emit_error E_RELATION
done
[ "$source_dir" = "$repo/control/v1" ] || emit_error E_RELATION

launcher_sha=$(sha256_path "$source_path") || emit_error E_RUNTIME
payload_sha=$(payload_sha_from_identity "$source_path" "$private_driver_id") ||
  emit_error E_RUNTIME
[ "$payload_sha" = "$private_payload_sha" ] || emit_error E_RELATION
program_sha=$(sha256_path "$scratch/program.jq") || emit_error E_RUNTIME
policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
validator_driver_sha=$(sha256_path "$policy_validator") || emit_error E_RUNTIME
validator_program_sha=$(sha256_path "$validator_program") || emit_error E_RUNTIME
"$jq_bin" -n -e --arg policy_sha "$policy_sha" --arg launcher_sha "$launcher_sha" \
  --arg payload_sha "$payload_sha" \
  --arg program_sha "$program_sha" --arg validator_driver_sha "$validator_driver_sha" \
  --arg validator_program_sha "$validator_program_sha" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile definition "$scratch/decision.json" '
  $definition[0] == {
    schema_version:1,kind:"evidence_integrity_decision",
    id:"control-decision.evidence-integrity",
    body:{activation_state:"inactive",decision:"allow-observation-only-evaluation",
      evaluator:{
        trusted_launcher_ref:{
          content_id:"control-evaluator-launcher.evidence-integrity.v1",
          media_type:"text/x-shellscript",sha256:$launcher_sha},
        evaluation_payload_ref:{
          content_id:"control-evaluator-payload.evidence-integrity.v1",
          media_type:"text/x-shellscript-fragment",sha256:$payload_sha},
        policy_set_validator:{
          driver_ref:{content_id:"control-policy-set-validator-driver.v1",
            media_type:"text/x-shellscript",sha256:$validator_driver_sha},
          program_ref:{content_id:"control-policy-set-validator-program.v1",
            media_type:"text/x-jq",sha256:$validator_program_sha}},
        program_ref:{content_id:"control-evaluator-program.evidence-integrity.v1",
          media_type:"text/x-jq",sha256:$program_sha}},
      fail_mode:"closed",
      policy_ref:{content_id:$policy[0].id,
        media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
      semantics:{authority_effect:"none",candidate_execution:"none",
        credential_access:"none",
        input_contract:"control-policy-set+public-core-stage-run+evidence-integrity-presentation.v1",
        launcher_attestation:"trusted-boundary-not-self-attested",
        network_access:"none",output_kind:"evidence_integrity_evaluation",
        output_schema_version:1,qualification_effect:"none",
        reference_semantics:"identity-only",storage_effect:"none",
        verdicts:["satisfied","violated"]}}
  }
' >/dev/null 2>&1 || emit_error E_RELATION

validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
  "$validator_driver_sha" "$validator_program_sha" || emit_error E_RELATION
mirror_validator_dir=$(build_validator_mirror) || emit_error E_RELATION
mirror_policy_validator="$mirror_validator_dir/validate.sh"
mirror_validator_program="$mirror_validator_dir/policy-set.jq"
pin_path "$mirror_policy_validator" || emit_error E_RELATION
pin_path "$mirror_validator_program" || emit_error E_RELATION
validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
  "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha" ||
  emit_error E_RELATION
policy_status=0
scratch_capture policy.out policy.err - - - - /usr/bin/env -i LC_ALL=C \
  PATH="${jq_bin%/*}:/usr/bin:/bin" TMPDIR="$scratch" HOME=/nonexistent \
  "$mirror_policy_validator" validate "$scratch/policy-set.json" ||
  policy_status=$?
capture_path_matches "$scratch/policy.out" "$CAPTURE_OUTPUT_KEY" ||
  emit_error E_RUNTIME
capture_path_matches "$scratch/policy.err" "$CAPTURE_ERROR_KEY" ||
  emit_error E_RUNTIME
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
[ "$policy_status" -eq 0 ] || emit_error E_POLICY_SET

selected=$(selected_core_generation "$core_driver") || emit_error E_RELATION
selected_sha=$(sha256_text "$selected") || emit_error E_RUNTIME
pin_core_package "$repo" "$selected" || emit_error E_RELATION
live_core_sha=$(core_closure_sha "$repo" "$core_driver" "$selected" live-pre) ||
  emit_error E_RELATION
mirror_root=$(build_core_mirror "$selected") || emit_error E_RELATION
mirror_core_driver="$mirror_root/scripts/core-contract.sh"
pin_core_package "$mirror_root" "$selected" || emit_error E_RELATION
mirror_core_sha=$(core_closure_sha "$mirror_root" "$mirror_core_driver" "$selected" mirror-pre) ||
  emit_error E_RELATION
[ "$mirror_core_sha" = "$live_core_sha" ] || emit_error E_RELATION
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg selected "$selected" --arg selected_sha "$selected_sha" \
  --arg core_sha "$live_core_sha" --slurpfile policy "$scratch/policy.json" '
  .body.core_contract == {
    semantic_identity:$policy[0].body.core_contract.semantic_identity,
    generation_id:$selected,package_ref:$policy[0].body.core_contract.package_ref} and
  $selected_sha == $policy[0].body.core_contract.generation_id_sha256 and
  $core_sha == $policy[0].body.core_contract.package_ref.sha256 and
  ([.body.sections[]|select(.section_id=="evidence-integrity")]|length)==1 and
  ([.body.sections[]|select(.section_id=="evidence-integrity")][0]) == {
    section_id:"evidence-integrity",
    policy_ref:{content_id:$policy[0].id,
      media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
    decision_ref:{content_id:"control-decision.evidence-integrity",
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha}}
' "$scratch/policy-set.json" >/dev/null 2>&1 || emit_error E_RELATION

core_status=0
scratch_mkdirs core-accounted || emit_error E_RUNTIME
core_accounted_root="$scratch/core-accounted"
core_accounted_id=$(directory_identity "$core_accounted_root") ||
  emit_error E_RUNTIME
core_byte_budget=16777216
scratch_capture core.out core.err core.receipt - - - /usr/bin/env -i LC_ALL=C \
  PATH="${jq_bin%/*}:/usr/bin:/bin" TMPDIR="$scratch" HOME=/nonexistent \
  "$mirror_core_driver" --accounted-validation "$core_accounted_root" \
  "$core_byte_budget" validate-stage-run \
  "$scratch/request.json" "$scratch/resolved.json" "$scratch/result.json" \
  || core_status=$?
core_output_key=$CAPTURE_OUTPUT_KEY
core_error_key=$CAPTURE_ERROR_KEY
core_receipt_key=$CAPTURE_RECEIPT_KEY
capture_path_matches "$scratch/core.out" "$core_output_key" || emit_error E_RUNTIME
capture_path_matches "$scratch/core.err" "$core_error_key" || emit_error E_RUNTIME
capture_path_matches "$scratch/core.receipt" "$core_receipt_key" ||
  emit_error E_RUNTIME
core_receipt_identity=$(capture_identity_for_key "$scratch/core.receipt" \
  "$core_receipt_key") || emit_error E_RUNTIME
core_receipt_text=$(capture_identity_text "$scratch/core.receipt" \
  "$core_receipt_identity") || emit_error E_RUNTIME
capture_path_matches "$scratch/core.receipt" "$core_receipt_key" ||
  emit_error E_RUNTIME
case "$core_receipt_text" in written-bytes:*) ;; *) emit_error E_RUNTIME ;; esac
core_written_bytes=${core_receipt_text#written-bytes:}
[[ "$core_written_bytes" =~ ^(0|[1-9][0-9]*)$ ]] || emit_error E_RUNTIME
[ "$core_written_bytes" -gt 0 ] &&
  [ "$core_written_bytes" -le "$core_byte_budget" ] || emit_error E_RUNTIME
directory_matches_identity "$core_accounted_root" "$core_accounted_id" ||
  emit_error E_RUNTIME
[ -z "$(/usr/bin/find "$core_accounted_root" -mindepth 1 -print -quit \
  2>/dev/null)" ] || emit_error E_RUNTIME
directory_matches_identity "$core_accounted_root" "$core_accounted_id" ||
  emit_error E_RUNTIME
post_live_core_sha=$(core_closure_sha "$repo" "$core_driver" "$selected" live-post) ||
  emit_error E_RELATION
post_mirror_core_sha=$(core_closure_sha \
  "$mirror_root" "$mirror_core_driver" "$selected" mirror-post) || emit_error E_RELATION
[ "$post_live_core_sha" = "$live_core_sha" ] &&
  [ "$post_mirror_core_sha" = "$mirror_core_sha" ] || emit_error E_RELATION
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
[ "$core_status" -eq 0 ] || emit_error E_CORE

policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
resolved_sha=$(sha256_path "$scratch/resolved.json") || emit_error E_RUNTIME
result_sha=$(sha256_path "$scratch/result.json") || emit_error E_RUNTIME
presentation_sha=$(sha256_path "$scratch/presentation.json") || emit_error E_RUNTIME
scratch_capture evaluation.json - - - - - "$jq_bin" -S -c -n \
  -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --slurpfile presentation "$scratch/presentation.json" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg presentation_sha "$presentation_sha" ||
  emit_error E_RUNTIME
evaluation_capture_key=$CAPTURE_OUTPUT_KEY
evaluation_identity=$(capture_identity_for_key "$scratch/evaluation.json" \
  "$evaluation_capture_key") || emit_error E_RUNTIME
fixed_files_ok || emit_error E_RELATION
final_live_core_sha=$(core_closure_sha "$repo" "$core_driver" "$selected" live-final) ||
  emit_error E_RELATION
final_mirror_core_sha=$(core_closure_sha \
  "$mirror_root" "$mirror_core_driver" "$selected" mirror-final) || emit_error E_RELATION
[ "$final_live_core_sha" = "$live_core_sha" ] &&
  [ "$final_mirror_core_sha" = "$mirror_core_sha" ] || emit_error E_RELATION
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
canonical_json "$scratch/evaluation.json" "$scratch/evaluation.canonical" ||
  emit_error E_RUNTIME
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg presentation_sha "$presentation_sha" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" --slurpfile presentation "$scratch/presentation.json" '
  (keys|sort)==["body","id","kind","schema_version"] and .schema_version==1 and
  .kind=="evidence_integrity_evaluation" and .id==$result[0].id and
  (.body|keys|sort)==["activation_state","authority_effect","core_contract",
    "decision_ref","evaluation_mode","evidence_refs","policy_ref","policy_set",
    "presentation_ref","prior_evidence_refs","qualification_observation",
    "qualification_semantics","reason_ids","reference_semantics","stage",
    "storage_effect","verdict"] and
  .body.activation_state=="inactive" and .body.authority_effect=="none" and
  .body.evaluation_mode=="observation-only" and .body.storage_effect=="none" and
  .body.reference_semantics=="identity-only" and
  .body.qualification_semantics=="identity-only-unqualified" and
  .body.core_contract==$policy_set[0].body.core_contract and
  .body.policy_set=={id:$policy_set[0].id,sha256:$policy_set_sha} and
  .body.policy_ref=={content_id:"control-policy.evidence-integrity",
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  .body.decision_ref=={content_id:"control-decision.evidence-integrity",
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.presentation_ref=={content_id:$presentation[0].id,
    media_type:"application/vnd.ystack.evidence-integrity-presentation+json",
    sha256:$presentation_sha} and
  .body.stage=={
    request_ref:{schema_version:$request[0].schema_version,kind:$request[0].kind,
      id:$request[0].id,sha256:$request_sha},
    resolved_profile_ref:{schema_version:$resolved[0].schema_version,kind:$resolved[0].kind,
      id:$resolved[0].id,sha256:$resolved_sha},
    result_ref:{schema_version:$result[0].schema_version,kind:$result[0].kind,
      id:$result[0].id,sha256:$result_sha}} and
  .body.evidence_refs==($result[0].body.evidence|map({evidence_id,kind,proof_ref,verdict})) and
  .body.prior_evidence_refs==$request[0].body.prior_evidence_refs and
  .body.qualification_observation==
    (if $request[0].body|has("qualification_ref") then
       {state:"present",value:$request[0].body.qualification_ref}
     else {state:"absent"} end) and
  (.body.verdict=="satisfied" or .body.verdict=="violated") and
  (.body.reason_ids|type=="array" and length>=1 and .==(sort|unique)) and
  (if .body.verdict=="satisfied" then
     .body.reason_ids==["evidence.integrity-satisfied"]
   else (.body.reason_ids|index("evidence.integrity-satisfied")==null) end) and
  ((.body|has("grant_ref") or has("qualification_ref") or has("activation") or
    has("credential") or has("network") or has("candidate_execution"))|not)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME

capture_path_matches "$scratch/evaluation.json" "$evaluation_capture_key" ||
  emit_error E_RUNTIME
verify_all_pins || emit_error E_RELATION
output_text=$(capture_identity_text "$scratch/evaluation.json" \
  "$evaluation_identity") ||
  emit_error E_RUNTIME
capture_path_matches "$scratch/evaluation.json" "$evaluation_capture_key" ||
  emit_error E_RUNTIME
if ! cleanup; then silent_fail; fi
trap - EXIT HUP INT TERM
/usr/bin/printf '%s\n' "$output_text" || exit 1
return 0
}
# YSTACK_EVIDENCE_PAYLOAD_WORKER_END

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  bootstrap_prepare "$@"
  supervisor_main "${normalized_args[@]}"
fi
