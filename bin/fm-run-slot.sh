#!/usr/bin/env bash
# fm-run-slot.sh - hand out machine run slots first-come-first-served, so heavy
# test suites, builds, and evals from many workers on one machine take turns
# instead of polling the load average and starting together.
#
# Usage:
#   fm-run-slot.sh acquire --class <cpu|net> [--wait] -- <command> [args...]
#   fm-run-slot.sh status
#   fm-run-slot.sh --help
#
# acquire runs <command> while holding one slot of the named class and frees
# the slot when the command exits or dies. The command keeps this terminal's
# stdin, stdout, and stderr, and acquire exits with the command's own status.
# Without --wait, acquire takes a slot only when one is free right now and no
# earlier caller is waiting for that class; otherwise it prints why on stderr
# and exits 75 without running anything. With --wait, it joins the class's
# first-in-first-out queue, prints its position on stderr whenever that
# changes, and runs the command when its turn comes.
#
# Classes:
#   cpu  CPU- or memory-heavy runs: test suites, builds, local model work.
#   net  runs that mostly wait on the network, such as evals that call a
#        hosted model. They get their own, larger slot count so they never
#        queue behind CPU-heavy runs.
#
# A slot is granted only when all of these hold:
#   - the caller is first in its class's queue (strict FIFO, so a run can
#     never be overtaken and starved);
#   - fewer than <class>_slots runs of that class hold a slot;
#   - reclaimable memory is at least <class>_mem_floor_mb, unless no run of
#     that class holds a slot: the floor is waived for a class's first slot,
#     so one run of each class can always progress, and applies to every
#     additional slot. Reclaimable memory is MemAvailable from /proc/meminfo where that file exists, otherwise the
#     free, inactive, and speculative pages reported by vm_stat (macOS). When
#     neither probe works the floor is not enforced and status says so.
# The load average is never consulted.
#
# Liveness: every holder and waiter record names the acquire process and, once
# the command starts, the command's own process, each with its start time so a
# recycled PID is never mistaken for the original. A slot stays held while
# either process is alive, so killing only the acquire process does not free
# a slot whose command is still running; it frees as soon as both are gone.
# A queue entry whose acquire process died is dropped. acquire and status
# remove dead records under the lock, and waiting runs drop a dead entry ahead
# of them on sight, so a crashed or killed run never keeps a slot or a queue
# place. Waiters behind the head check their place without the lock or a fork;
# only the head takes the lock to claim a slot, so a long queue stays cheap.
#
# Signals: TERM, INT, and HUP sent to acquire while its command runs are
# forwarded to the command, and acquire then exits with the command's status.
# While still queued, those signals leave the queue and exit 128+signal.
# The command starts with SIGINT and SIGQUIT at their defaults, so Ctrl-C
# reaches it as it would without this wrapper.
#
# Scope: slots are per machine. Config and state live in the local root
# Firstmate home (the home fm_firstmate_root_home in bin/fm-wake-lib.sh
# resolves), so every local secondmate home and its workers share one queue.
# When FM_HOME is itself the root, FM_CONFIG_OVERRIDE and FM_STATE_OVERRIDE
# apply as they do for other scripts.
#
# Config: optional config/run-slots, one "key=value" per line. Blank lines and
# lines starting with "#" are ignored. Keys and defaults:
#   cpu_slots=2            positive integer
#   cpu_mem_floor_mb=2048  non-negative integer; 0 disables the memory floor
#   net_slots=8            positive integer
#   net_mem_floor_mb=1024  non-negative integer; 0 disables the memory floor
# An unknown key, a repeated key, a malformed line or value, or an unreadable
# file stops acquire and status with an error naming the file and line, rather
# than guessing which limit was meant.
#
# State: state/run-slots/ in the root home holds the ticket counter "seq", the
# lock ".lock" (bin/fm-wake-lib.sh's portable lock), and one record file per
# ticket under <class>/queue/ and <class>/held/. Change it only through this
# script.
#
# status removes dead records, then prints one block per class:
#   cpu: 2/2 held, 1 waiting, memory floor 2048 MB, reclaimable 6100 MB
#     held    #6 for 9m02s pid 1200 command 1201: cargo test  (in /path)
#     held    #7 for 3m12s pid 1234 command 1235: pytest -x  (in /path)
#     waiting #8 for 0m40s position 1 pid 1300, next: all 2 cpu slots are held: npm test  (in /path)
#
# Environment:
#   FM_HOME, FM_CONFIG_OVERRIDE, FM_STATE_OVERRIDE  resolve the home as usual.
#   FM_PROC_ROOT_OVERRIDE  directory read instead of /proc for meminfo.
#   FM_RUN_SLOT_POLL_SECS  seconds between queue checks while waiting
#                          (default 1; a positive number such as 0.2).
#
# Exit status: the command's status after it ran; 75 when no slot was free
# without --wait; 127 when the command cannot be executed; 2 on a usage
# error; 1 on an unreadable config, an unresolvable root home, or a state
# failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

RUN_SLOT_BUSY_EXIT=75
RUN_SLOT_CLASSES="cpu net"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "fm-run-slot: $*" >&2
  exit 1
}

usage_error() {
  echo "fm-run-slot: $*" >&2
  echo "usage: fm-run-slot.sh acquire --class <cpu|net> [--wait] -- <command> [args...] | status | --help" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  acquire|status) SUBCOMMAND=$1; shift ;;
  "") usage_error "missing subcommand" ;;
  *) usage_error "unknown subcommand: $1" ;;
esac

CLASS=
WAIT=0
if [ "$SUBCOMMAND" = acquire ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class)
        [ "$#" -ge 2 ] || usage_error "--class needs a value"
        CLASS=$2
        shift 2
        ;;
      --class=*) CLASS=${1#--class=}; shift ;;
      --wait) WAIT=1; shift ;;
      --) shift; break ;;
      *) usage_error "unexpected argument before --: $1" ;;
    esac
  done
  case "$CLASS" in
    cpu|net) ;;
    "") usage_error "acquire needs --class cpu or --class net" ;;
    *) usage_error "unknown class: $CLASS (expected cpu or net)" ;;
  esac
  [ "$#" -gt 0 ] || usage_error "acquire needs a command after --"
else
  [ "$#" -eq 0 ] || usage_error "status takes no arguments"
fi

POLL_SECS=${FM_RUN_SLOT_POLL_SECS:-1}
if ! [[ $POLL_SECS =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ $POLL_SECS =~ [1-9] ]]; then
  usage_error "FM_RUN_SLOT_POLL_SECS must be a positive number, got: $POLL_SECS"
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# --- home resolution --------------------------------------------------------
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
  || die "FM_HOME is not a directory: $FM_HOME"
ROOT_HOME=$(fm_firstmate_root_home "$HOME_REAL") \
  || die "cannot resolve the local root Firstmate home from $HOME_REAL"
if [ "$ROOT_HOME" = "$HOME_REAL" ]; then
  SLOT_CONFIG="${FM_CONFIG_OVERRIDE:-$HOME_REAL/config}"
  SLOT_STATE_ROOT="${FM_STATE_OVERRIDE:-$HOME_REAL/state}"
else
  SLOT_CONFIG="$ROOT_HOME/config"
  SLOT_STATE_ROOT="$ROOT_HOME/state"
fi
CONFIG_FILE="$SLOT_CONFIG/run-slots"
SLOTS="$SLOT_STATE_ROOT/run-slots"
LOCK="$SLOTS/.lock"

# --- config -----------------------------------------------------------------
cpu_slots=2
cpu_mem_floor_mb=2048
net_slots=8
net_mem_floor_mb=1024

read_config() {
  local line lineno=0 key value seen='|'
  if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    return 0
  fi
  [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] \
    || die "$CONFIG_FILE is not a readable regular file"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$(printf '%s' "$line" | tr -d '[:space:]')" in
      '') continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) die "$CONFIG_FILE line $lineno: expected key=value, got: $line" ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      cpu_slots|net_slots)
        case "$value" in
          ''|*[!0-9]*) die "$CONFIG_FILE line $lineno: $key must be a positive integer, got: $value" ;;
        esac
        [ "${#value}" -le 6 ] && [ "$value" -gt 0 ] \
          || die "$CONFIG_FILE line $lineno: $key must be a positive integer of at most six digits, got: $value"
        ;;
      cpu_mem_floor_mb|net_mem_floor_mb)
        case "$value" in
          ''|*[!0-9]*) die "$CONFIG_FILE line $lineno: $key must be a non-negative integer, got: $value" ;;
        esac
        [ "${#value}" -le 9 ] \
          || die "$CONFIG_FILE line $lineno: $key must be at most nine digits, got: $value"
        ;;
      *) die "$CONFIG_FILE line $lineno: unknown key: $key" ;;
    esac
    case "$seen" in
      *"|$key|"*) die "$CONFIG_FILE line $lineno: $key is set more than once" ;;
    esac
    seen="$seen$key|"
    value=$((10#$value))
    printf -v "$key" '%s' "$value"
  done < "$CONFIG_FILE"
}
read_config

class_slots() {
  case "$1" in
    cpu) printf '%s\n' "$cpu_slots" ;;
    net) printf '%s\n' "$net_slots" ;;
  esac
}

class_floor() {
  case "$1" in
    cpu) printf '%s\n' "$cpu_mem_floor_mb" ;;
    net) printf '%s\n' "$net_mem_floor_mb" ;;
  esac
}

# --- probes -----------------------------------------------------------------
# Reclaimable memory in whole MB, or non-zero when no probe works.
reclaimable_mem_mb() {
  local meminfo="${FM_PROC_ROOT_OVERRIDE:-/proc}/meminfo" kb out
  if [ -r "$meminfo" ]; then
    kb=$(awk '$1 == "MemAvailable:" { print $2; exit }' "$meminfo" 2>/dev/null)
    case "$kb" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$((kb / 1024))"; return 0 ;;
    esac
  fi
  command -v vm_stat >/dev/null 2>&1 || return 1
  out=$(vm_stat 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk '
    /page size of/ {
      for (i = 1; i <= NF; i++) if ($i == "of") { size = $(i + 1); break }
    }
    /^Pages free:/ { gsub(/\./, "", $3); free = $3; seen++ }
    /^Pages inactive:/ { gsub(/\./, "", $3); inactive = $3; seen++ }
    /^Pages speculative:/ { gsub(/\./, "", $3); spec = $3 }
    END {
      if (size !~ /^[0-9]+$/ || size == 0 || seen < 2) exit 1
      if (free !~ /^[0-9]+$/ || inactive !~ /^[0-9]+$/) exit 1
      if (spec !~ /^[0-9]+$/) spec = 0
      printf "%d\n", (free + inactive + spec) * size / 1048576
    }
  '
}

# A process start time that survives exec, so a recycled PID never matches.
pid_start() {
  local pid=$1 stat_line starttime
  local -a fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    { IFS= read -r stat_line < "/proc/$pid/stat"; } 2>/dev/null || return 1
    read -r -a fields <<< "${stat_line##*)}"
    starttime=${fields[19]:-}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'ticks-%s\n' "$starttime"
    return 0
  fi
  starttime=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/_/g')
  [ -n "$starttime" ] || return 1
  printf '%s\n' "$starttime"
}

# 0 when <pid> is alive and, when <start> is known, still the same process.
proc_matches() {
  local pid=$1 start=$2 now
  fm_pid_alive "$pid" || return 1
  [ -n "$start" ] || return 0
  # An unreadable start time cannot prove reuse; keep the record.
  now=$(pid_start "$pid") || return 0
  [ "$now" = "$start" ]
}

# --- records ----------------------------------------------------------------
# A record is key=value lines. read_record sets REC_<key> for the known keys.
read_record() {
  local file=$1 line key value
  REC_pid='' REC_pid_start='' REC_child='' REC_child_start=''
  REC_enqueued='' REC_granted='' REC_cwd='' REC_cmd=''
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      pid) REC_pid=$value ;;
      pid_start) REC_pid_start=$value ;;
      child) REC_child=$value ;;
      child_start) REC_child_start=$value ;;
      enqueued) REC_enqueued=$value ;;
      granted) REC_granted=$value ;;
      cwd) REC_cwd=$value ;;
      cmd) REC_cmd=$value ;;
    esac
  done < "$file"
}

# write_record <dest> : atomically write the REC_* fields to <dest>.
write_record() {
  local dest=$1 tmp
  local me=''
  fm_current_pid me || me=$$
  tmp="${dest%/*}/.tmp.$me"
  {
    printf 'pid=%s\n' "$REC_pid"
    printf 'pid_start=%s\n' "$REC_pid_start"
    printf 'child=%s\n' "$REC_child"
    printf 'child_start=%s\n' "$REC_child_start"
    printf 'enqueued=%s\n' "$REC_enqueued"
    printf 'granted=%s\n' "$REC_granted"
    printf 'cwd=%s\n' "$REC_cwd"
    printf 'cmd=%s\n' "$REC_cmd"
  } > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dest" 2>/dev/null && return 0
  rm -f -- "$tmp" 2>/dev/null
  return 1
}

holder_alive() {
  proc_matches "$REC_pid" "$REC_pid_start" && return 0
  [ -n "$REC_child" ] && proc_matches "$REC_child" "$REC_child_start" && return 0
  return 1
}

# load_tickets <dir>: set TICKETS to the ticket names in <dir>, ascending
# (zero-padded names sort numerically), without forking.
load_tickets() {
  local f
  TICKETS=()
  for f in "$1"/[0-9]*; do
    [ -f "$f" ] && TICKETS[${#TICKETS[@]}]=${f##*/}
  done
}

# prune_holders <class>: remove holders whose acquire process and command are
# both gone, checking start times so a recycled PID never keeps a slot.
# Caller holds the lock.
prune_holders() {
  local class=$1 i
  load_tickets "$SLOTS/$class/held"
  for ((i = 0; i < ${#TICKETS[@]}; i++)); do
    read_record "$SLOTS/$class/held/${TICKETS[$i]}" || continue
    holder_alive || rm -f -- "$SLOTS/$class/held/${TICKETS[$i]}"
  done
}

# prune_queue <class>: remove waiters whose acquire process is gone or was
# replaced by a recycled PID. Caller holds the lock.
prune_queue() {
  local class=$1 i
  load_tickets "$SLOTS/$class/queue"
  for ((i = 0; i < ${#TICKETS[@]}; i++)); do
    read_record "$SLOTS/$class/queue/${TICKETS[$i]}" || continue
    proc_matches "$REC_pid" "$REC_pid_start" || rm -f -- "$SLOTS/$class/queue/${TICKETS[$i]}"
  done
}

count_tickets() {  # <dir> -> TICKET_COUNT
  load_tickets "$1"
  TICKET_COUNT=${#TICKETS[@]}
}

ensure_dirs() {
  local class
  for class in $RUN_SLOT_CLASSES; do
    mkdir -p "$SLOTS/$class/queue" "$SLOTS/$class/held" 2>/dev/null \
      || die "cannot create run-slot state under $SLOTS"
  done
}

LOCK_HELD=0
lock() {
  fm_lock_acquire_wait "$LOCK" || die "cannot take the run-slot lock $LOCK"
  LOCK_HELD=1
}
unlock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  fm_lock_release "$LOCK"
  LOCK_HELD=0
}

next_ticket() {
  local seq n
  seq=$(cat "$SLOTS/seq" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  n=$((10#$seq + 1))
  printf -v n '%012d' "$n"
  if ! { printf '%s\n' "$n" > "$SLOTS/seq.tmp.$$" && mv -f -- "$SLOTS/seq.tmp.$$" "$SLOTS/seq"; }; then
    rm -f -- "$SLOTS/seq.tmp.$$"
    return 1
  fi
  printf '%s\n' "$n"
}

fmt_duration() {
  local s=$1
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm%02ds' "$((s / 3600))" "$((s % 3600 / 60))" "$((s % 60))"
  else
    printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
  fi
}

# Why the head of <class>'s queue cannot start now, or empty when it can.
# Sets BLOCK_REASON, with the current memory reading, and BLOCK_NOTE, the same
# reason without the reading so it stays stable while a run waits. Caller
# holds the lock and has pruned the class.
evaluate_capacity() {
  local class=$1 held slots floor mem
  BLOCK_REASON='' BLOCK_NOTE=''
  count_tickets "$SLOTS/$class/held"
  held=$TICKET_COUNT
  slots=$(class_slots "$class")
  if [ "$held" -ge "$slots" ]; then
    BLOCK_REASON="all $slots $class slots are held"
    BLOCK_NOTE=$BLOCK_REASON
    return 0
  fi
  [ "$held" -gt 0 ] || return 0
  floor=$(class_floor "$class")
  [ "$floor" -gt 0 ] || return 0
  mem=$(reclaimable_mem_mb) || return 0
  if [ "$mem" -lt "$floor" ]; then
    BLOCK_REASON="reclaimable memory ${mem} MB is below the ${floor} MB floor"
    BLOCK_NOTE="reclaimable memory is below the ${floor} MB floor"
  fi
}

# --- status -----------------------------------------------------------------
if [ "$SUBCOMMAND" = status ]; then
  ensure_dirs
  lock
  for class in $RUN_SLOT_CLASSES; do
    prune_holders "$class"
    prune_queue "$class"
  done
  now=$(date +%s)
  mem=$(reclaimable_mem_mb) || mem=
  mem_text=${mem:+reclaimable $mem MB}
  [ -n "$mem_text" ] || mem_text="reclaimable memory unknown, floor not enforced"
  for class in $RUN_SLOT_CLASSES; do
    load_tickets "$SLOTS/$class/held"
    held_list=(${TICKETS[@]+"${TICKETS[@]}"})
    load_tickets "$SLOTS/$class/queue"
    queue_list=(${TICKETS[@]+"${TICKETS[@]}"})
    floor=$(class_floor "$class")
    if [ "$floor" -gt 0 ]; then floor_text="memory floor $floor MB"; else floor_text="no memory floor"; fi
    printf '%s: %s/%s held, %s waiting, %s, %s\n' "$class" "${#held_list[@]}" "$(class_slots "$class")" \
      "${#queue_list[@]}" "$floor_text" "$mem_text"
    for ((i = 0; i < ${#held_list[@]}; i++)); do
      t=${held_list[$i]}
      read_record "$SLOTS/$class/held/$t" || continue
      child_text=
      [ -z "$REC_child" ] || child_text=" command $REC_child"
      printf '  held    #%s for %s pid %s%s: %s  (in %s)\n' "$((10#$t))" \
        "$(fmt_duration "$((now - ${REC_granted:-$now}))")" "$REC_pid" "$child_text" "$REC_cmd" "$REC_cwd"
    done
    head_reason=
    if [ "${#queue_list[@]}" -gt 0 ]; then
      evaluate_capacity "$class"
      head_reason=${BLOCK_REASON:-a slot is free}
    fi
    for ((i = 0; i < ${#queue_list[@]}; i++)); do
      t=${queue_list[$i]}
      read_record "$SLOTS/$class/queue/$t" || continue
      if [ "$i" -eq 0 ]; then next_text=", next: $head_reason"; else next_text=; fi
      printf '  waiting #%s for %s position %s pid %s%s: %s  (in %s)\n' "$((10#$t))" \
        "$(fmt_duration "$((now - ${REC_enqueued:-$now}))")" "$((i + 1))" "$REC_pid" "$next_text" "$REC_cmd" "$REC_cwd"
    done
  done
  unlock
  exit 0
fi

# --- acquire ----------------------------------------------------------------
ensure_dirs
SELF_START=$(pid_start "$$" || true)
CMD_TEXT=$(printf '%s ' "$@" | tr '\n\r\t' '   ' | cut -c1-200)
CMD_TEXT=${CMD_TEXT% }
CWD_TEXT=$(pwd 2>/dev/null || true)
CWD_TEXT=$(printf '%s' "$CWD_TEXT" | tr '\n\r' '  ')
TICKET=
CHILD=
CHILD_RC=
FORWARDED=0

cleanup() {
  [ -n "$TICKET" ] || return 0
  lock
  rm -f -- "$SLOTS/$CLASS/queue/$TICKET" "$SLOTS/$CLASS/held/$TICKET"
  unlock
  TICKET=
}

# shellcheck disable=SC2329 # Invoked by the traps below.
on_signal() {  # <signal> <number>
  if [ -n "$CHILD" ]; then
    FORWARDED=1
    kill -s "$1" "$CHILD" 2>/dev/null || true
    return 0
  fi
  unlock
  cleanup
  exit "$((128 + $2))"
}
trap 'cleanup' EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP

# Load this run's own record into REC_*; reading other records clobbers it.
OWN_ENQUEUED=$(date +%s)
own_record() {  # [granted-epoch]
  REC_pid=$$ REC_pid_start=$SELF_START REC_child='' REC_child_start=''
  REC_enqueued=$OWN_ENQUEUED REC_granted=${1:-} REC_cwd=$CWD_TEXT REC_cmd=$CMD_TEXT
}

# queue_position: set POSITION to this run's 1-based place in its class queue
# (0 when its entry is gone) and HEAD_* to the live entry at the head when that
# is someone else. Drops entries ahead whose acquire process is dead. Needs no
# lock: records are replaced atomically and only dead entries are removed.
queue_position() {
  local i t dir="$SLOTS/$CLASS/queue"
  POSITION=0 HEAD_TICKET='' HEAD_PID='' HEAD_START=''
  load_tickets "$dir"
  for ((i = 0; i < ${#TICKETS[@]}; i++)); do
    t=${TICKETS[$i]}
    if [ "$t" = "$TICKET" ]; then
      POSITION=$((POSITION + 1))
      return 0
    fi
    read_record "$dir/$t" || continue
    if ! fm_pid_alive "$REC_pid"; then
      rm -f -- "$dir/$t"
      continue
    fi
    POSITION=$((POSITION + 1))
    if [ -z "$HEAD_TICKET" ]; then
      HEAD_TICKET=$t HEAD_PID=$REC_pid HEAD_START=$REC_pid_start
    fi
  done
  POSITION=0
}

lock
prune_holders "$CLASS"
prune_queue "$CLASS"
TICKET=$(next_ticket) || { unlock; die "cannot allocate a run-slot ticket under $SLOTS"; }
if [ "$WAIT" -eq 0 ]; then
  count_tickets "$SLOTS/$CLASS/queue"
  ahead=$TICKET_COUNT
  if [ "$ahead" -gt 0 ]; then
    BLOCK_REASON="$ahead earlier run(s) are waiting for a $CLASS slot"
  else
    evaluate_capacity "$CLASS"
  fi
  if [ -n "$BLOCK_REASON" ]; then
    TICKET=
    unlock
    echo "fm-run-slot: no $CLASS slot free: $BLOCK_REASON; rerun with --wait to queue" >&2
    exit "$RUN_SLOT_BUSY_EXIT"
  fi
  own_record "$OWN_ENQUEUED"
  write_record "$SLOTS/$CLASS/held/$TICKET" || { unlock; die "cannot record the $CLASS slot under $SLOTS"; }
  unlock
else
  own_record
  write_record "$SLOTS/$CLASS/queue/$TICKET" || { unlock; die "cannot record the $CLASS queue entry under $SLOTS"; }
  unlock
  last_note=
  head_check_at=$((SECONDS + 5))
  while :; do
    # Waiters behind the head only read the queue, without the lock or a
    # fork, so a long queue costs nothing; a dead waiter ahead is dropped on
    # sight and a recycled PID at the head is caught every few seconds.
    queue_position
    if [ "$POSITION" -eq 0 ]; then
      # Our entry vanished (state was cleared by hand); queue again at the back.
      lock
      TICKET=$(next_ticket) || { unlock; die "cannot allocate a run-slot ticket under $SLOTS"; }
      own_record
      write_record "$SLOTS/$CLASS/queue/$TICKET" || { unlock; die "cannot record the $CLASS queue entry under $SLOTS"; }
      unlock
      continue
    fi
    if [ "$POSITION" -gt 1 ] && [ "$SECONDS" -ge "$head_check_at" ]; then
      proc_matches "$HEAD_PID" "$HEAD_START" || rm -f -- "$SLOTS/$CLASS/queue/$HEAD_TICKET"
      head_check_at=$((SECONDS + 5))
    fi
    if [ "$POSITION" -eq 1 ]; then
      lock
      prune_holders "$CLASS"
      queue_position
      BLOCK_NOTE=
      if [ "$POSITION" -eq 1 ]; then
        evaluate_capacity "$CLASS"
        if [ -z "$BLOCK_NOTE" ]; then
          own_record "$(date +%s)"
          write_record "$SLOTS/$CLASS/held/$TICKET" || { unlock; die "cannot record the $CLASS slot under $SLOTS"; }
          rm -f -- "$SLOTS/$CLASS/queue/$TICKET"
          unlock
          break
        fi
      fi
      unlock
      note="first in line for a $CLASS slot: ${BLOCK_NOTE:-rechecking}"
    else
      note="waiting for a $CLASS slot: position $POSITION"
    fi
    if [ "$note" != "$last_note" ]; then
      echo "fm-run-slot: $note" >&2
      last_note=$note
    fi
    sleep "$POLL_SECS"
  done
  [ -z "$last_note" ] || echo "fm-run-slot: $CLASS slot granted after waiting $(fmt_duration "$(( $(date +%s) - OWN_ENQUEUED ))")" >&2
fi

# Run the command with this terminal's stdin and SIGINT/SIGQUIT at their
# defaults (a non-interactive shell's background job otherwise ignores both and
# reads /dev/null). The child records its own PID in the slot before it execs
# the command, so the slot outlives a killed acquire process for exactly as
# long as the command runs, with no window where the command runs unrecorded.
record_self_as_child() {
  local me=''
  fm_current_pid me || return 0
  read_record "$SLOTS/$CLASS/held/$TICKET" || return 0
  REC_child=$me
  REC_child_start=$(pid_start "$me" || true)
  write_record "$SLOTS/$CLASS/held/$TICKET" || true
}
exec 3<&0
if command -v perl >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # Perl code, expanded by perl.
  ( record_self_as_child; exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec { $ARGV[0] } @ARGV; print STDERR "fm-run-slot: cannot execute $ARGV[0]: $!\n"; exit 127' -- "$@" <&3 3<&- ) &
else
  ( record_self_as_child; trap - INT QUIT; exec "$@" <&3 3<&- ) &
fi
CHILD=$!
exec 3<&-

while :; do
  FORWARDED=0
  wait "$CHILD"
  CHILD_RC=$?
  # A forwarded signal interrupts wait before the command has exited, or
  # after bash has already reaped it; either way wait again, which returns the
  # command's real status from bash's own record of the job.
  [ "$FORWARDED" -eq 1 ] && [ "$CHILD_RC" -gt 128 ] && continue
  break
done
CHILD=
cleanup
exit "$CHILD_RC"
