# Sourced by tools/install-local, tools/uninstall-local and tools/self-update: Maprisma Settings' running
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

# pid:start of the bundle's tray (bin/maprisma-settings-tray, or bin/maprisma-manager-tray of a build
# from before the rename; in the bundle or a .new/.old sibling).
tray_ids() {
  local id pid exe
  for id in $(running_ids 1); do
    pid=${id%%:*}
    exe=$(readlink "$proc/$pid/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    [[ $exe == */bin/maprisma-settings-tray || $exe == */bin/maprisma-manager-tray ]] && echo "$id"
  done
  return 0
}

# --- the rename from Maprisma Manager to Maprisma Settings ------------------------------------
# The same rule as the core's migrateLegacyFolders (paths.dart): a folder of the old name that is a
# real folder, while none of the new name exists, is renamed (never copied) and a link of the old
# name is left pointing to the new one, so an older build, its self-update helper and other tools
# that still use the old name find the same files. A folder on another file system (the old one a
# mount point) is left alone; when both exist the new one is used and the old one stays.

# $1: the old folder, $2: the new one (the same parent).
migrate_dir() {
  local old=$1 new=$2 parent
  [[ -L $old || ! -d $old ]] && return 0
  [[ -e $new || -L $new ]] && return 0
  parent=$(dirname -- "$old")
  [[ $(stat -c %d -- "$old") == "$(stat -c %d -- "$parent")" ]] || return 0
  mv -T -- "$old" "$new" || return 0
  ln -sT -- "$(basename -- "$new")" "$old" 2>/dev/null || echo "note: no link $old -> $new" >&2
  return 0
}

# The XDG folder for $1 (variable) with $2 below HOME as its default (relative values are ignored).
xdg_dir() {
  local v=${!1:-}
  [[ $v == /* ]] && echo "$v" || echo "$HOME/$2"
}

# Settings, state, data, cache and the installed bundle: maprisma-manager -> maprisma-settings.
migrate_legacy() {
  local base
  for base in "$(xdg_dir XDG_CONFIG_HOME .config)" "$(xdg_dir XDG_STATE_HOME .local/state)" \
      "$(xdg_dir XDG_DATA_HOME .local/share)" "$(xdg_dir XDG_CACHE_HOME .cache)" "$HOME/.local/lib"; do
    migrate_dir "$base/maprisma-manager" "$base/maprisma-settings"
  done
}
