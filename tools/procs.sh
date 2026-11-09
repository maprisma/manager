# Sourced by tools/install-local, tools/uninstall-local and tools/self-update: the Manager's running
# copies found by their real program path (never by name: process names are cut to 15 characters),
# identified by pid and start time, and signalled only after that identity is checked again.
#
# Needs: $lib (the bundle folder) and $proc (default /proc).
proc=${proc:-/proc}

# The bundle folder as written and as /proc reports it (a symlinked HOME or ~/.local/lib).
lib_forms() {
  local parent
  echo "$lib"
  parent=$(cd -- "$(dirname -- "$lib")" 2>/dev/null && pwd -P) || return 0
  [[ $parent/$(basename -- "$lib") != "$lib" ]] && echo "$parent/$(basename -- "$lib")"
  return 0
}

# Field 22 of /proc/<pid>/stat (the start time), empty for a zombie or a gone process.
start_of() {
  local st rest
  st=$(cat "$proc/$1/stat" 2>/dev/null) || return 1
  rest=${st##*) }
  # shellcheck disable=SC2086
  set -- $rest
  [[ $1 == Z || $1 == X ]] && return 1
  echo "${20}"
}

# Whether /proc/<pid>/exe is inside the bundle; $1: pid, $2: also its .new.*/.old.* siblings (1/0).
exe_in_lib() {
  local exe f
  exe=$(readlink "$proc/$1/exe" 2>/dev/null) || return 1
  exe=${exe% (deleted)}
  while read -r f; do
    [[ $exe == "$f/"* ]] && return 0
    [[ ${2:-1} == 1 && $exe == "$f".*/* ]] && return 0
  done < <(lib_forms)
  return 1
}

# pid:start of every process of the bundle; $1 as exe_in_lib's $2.
running_ids() {
  local p pid start
  for p in "$proc"/[0-9]*; do
    pid=${p##*/}
    exe_in_lib "$pid" "${1:-1}" || continue
    start=$(start_of "$pid") || continue
    echo "$pid:$start"
  done
  return 0
}

# Sends $1 to each pid:start given, only while it is still that process and still the bundle's.
signal_ids() {
  local sig=$1 id pid
  shift
  for id in "$@"; do
    pid=${id%%:*}
    [[ $(start_of "$pid") == "${id#*:}" ]] || continue
    exe_in_lib "$pid" 1 || continue
    kill "-$sig" "$pid" 2>/dev/null || true
  done
}

# TERM, up to 5 s, then KILL to what is left (identity checked before each signal); $1 as above.
stop_running() {
  local ids left
  ids=$(running_ids "${1:-1}")
  [[ -z $ids ]] && return 0
  echo "Stopping: $(echo $ids | sed 's/:[0-9]*//g')"
  # shellcheck disable=SC2086
  signal_ids TERM $ids
  for _ in $(seq 1 50); do [[ -z $(running_ids "${1:-1}") ]] && return 0; sleep 0.1; done
  left=$(running_ids "${1:-1}")
  # shellcheck disable=SC2086
  [[ -n $left ]] && { signal_ids KILL $left; sleep 0.3; }
  return 0
}

# The self-update's lock: the helper holds it from start to end; install-local and uninstall-local
# refuse while it is held. $1: the state folder of the self-update.
take_lock() {
  mkdir -p "$1"
  exec 9>"$1/lock"
  flock -n 9
}
