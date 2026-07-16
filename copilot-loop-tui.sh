#!/usr/bin/env bash
#
# copilot-loop-tui.sh
#
# A small terminal UI that manages several copilot-loop.sh instances ("bots")
# side by side, WITHOUT replacing the loop. Each bot is an ordinary
# copilot-loop.sh process, so the bots behave exactly like running the loop by
# hand; the TUI only spawns, monitors and stops them.
#
# With it you can:
#   - spawn a new bot to take on more work in parallel (press 's');
#   - see at a glance how many bots are running (the header count);
#   - watch each bot's latest status line and drill into its full log ('l');
#   - stop a single bot ('x') or all of them, and quit ('q').
#
# Bots run detached (setsid when available, otherwise nohup + disown) with their
# stdin taken from /dev/null and their output captured to a per-bot log, so:
#   - they keep working even after the TUI exits (the TUI re-attaches to the
#     running bots the next time it starts), and
#   - they never fight the TUI or each other for the keyboard.
# The loop's own multi-instance support (a shared GitHub lock plus per-issue git
# worktrees) is what makes running many bots against one repo safe; the TUI just
# drives it. See copilot-loop.sh for that mechanism.
#
# Requirements: bash, and whatever copilot-loop.sh itself needs (git, gh,
# copilot) for the bots to make progress. The TUI opens even if those are
# missing so you can still inspect state; bots will just report the problem in
# their log and show as "stopped".
#
# Usage:
#   ./copilot-loop-tui.sh [options] [-- <copilot-loop.sh options>]
#
# Options:
#   --bots <n>            Spawn n bots on startup            (default: 1)
#   --repo-dir <dir>      Repository the bots operate in     (default: current git repo)
#   --loop-script <path>  Path to copilot-loop.sh            (default: next to this script)
#   -h, --help            Show this help and exit.
#
# Anything after a literal "--" (or any option this script does not recognise)
# is forwarded verbatim to every bot, so all copilot-loop.sh flags work, e.g.:
#   ./copilot-loop-tui.sh --bots 3 -- --auto-merge --model gpt-5
#
# Keys inside the TUI:
#   s / n      spawn a new bot
#   x / d      stop the selected bot
#   a          stop every bot
#   j / k      move the selection down / up (arrow keys work too)
#   l / Enter  open the selected bot's log in a pager
#   c          clear stopped bots from the list
#   r          refresh now
#   ? / h      help
#   q          quit (offers to stop running bots first)
#
set -uo pipefail

# --- Helpers -----------------------------------------------------------------
log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "FATAL: $*"
  exit 1
}

need_arg() {
  [ "$1" -ge 2 ] || die "option $2 requires a value"
}

# Best-effort modification time (epoch seconds) of a path. Portable across the
# BSD stat on macOS (-f %m) and GNU stat on Linux (-c %Y); echoes 0 when it
# cannot tell. Mirrors the helper in copilot-loop.sh.
_stat_mtime() {
  local p="$1" m
  m="$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo 0)"
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

# >>> tui-pure helpers >>>
# Pure, side-effect-free helpers, kept together so the unit tests can extract and
# exercise this exact code. Nothing here touches the filesystem, processes or the
# terminal.

# Read newline-separated bot ids on stdin and print the next free id (max + 1,
# or 1 when there are none). Non-numeric lines are ignored.
next_bot_id() {
  local max=0 id
  while IFS= read -r id; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" -gt "$max" ] && max="$id"
  done
  printf '%s' "$(( max + 1 ))"
}

# Map an already-resolved key token to a TUI action name. Arrow-key escape
# sequences are resolved to up/down/left/right by read_key before they reach
# here, so this stays a plain lookup table.
tui_action_for_key() {
  case "$1" in
    s|n)     printf 'spawn' ;;
    x|d)     printf 'stop' ;;
    a)       printf 'stop-all' ;;
    k|up)    printf 'up' ;;
    j|down)  printf 'down' ;;
    l|enter) printf 'log' ;;
    c)       printf 'clear' ;;
    r)       printf 'refresh' ;;
    q)       printf 'quit' ;;
    '?'|h)   printf 'help' ;;
    *)       printf 'none' ;;
  esac
}

# Clamp a selection index into [0, count-1]; a count of zero (or less) pins it to
# 0. Keeps navigation from ever pointing outside the list.
clamp_selection() {
  local idx="$1" count="$2"
  [ "$count" -le 0 ] 2>/dev/null && { printf '0'; return; }
  [ "$idx" -lt 0 ] 2>/dev/null && idx=0
  [ "$idx" -ge "$count" ] 2>/dev/null && idx=$(( count - 1 ))
  printf '%s' "$idx"
}

# Format a duration in seconds as a compact uptime (e.g. 5s, 1m05s, 1h02m). A
# non-numeric input renders as an em dash so unknown ages stay obvious.
fmt_uptime() {
  local s="$1"
  case "$s" in ''|*[!0-9]*) printf '—'; return ;; esac
  local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 )) sec=$(( s % 60 ))
  if [ "$h" -gt 0 ]; then
    printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm%02ds' "$m" "$sec"
  else
    printf '%ds' "$sec"
  fi
}

# Strip ANSI/OSC escape sequences and stray control characters from a line so a
# bot's captured output can never corrupt the rendered screen.
sanitize_line() {
  local s="$1" esc bel
  esc=$'\x1b'; bel=$'\x07'
  s="$(printf '%s' "$s" | sed -E "s/${esc}\[[0-9;?]*[A-Za-z]//g; s/${esc}\][^${bel}]*${bel}//g")"
  s="${s//$'\t'/ }"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177\r'
}

# Truncate text to fit width columns, marking the cut with a single ellipsis.
truncate_display() {
  local text="$1" width="$2"
  [ "$width" -le 0 ] 2>/dev/null && { printf ''; return; }
  if [ "${#text}" -gt "$width" ]; then
    if [ "$width" -le 1 ]; then
      printf '%s' "${text:0:width}"
    else
      printf '%s…' "${text:0:width-1}"
    fi
  else
    printf '%s' "$text"
  fi
}

# The one-line status header (kept pure so its exact text is unit tested).
render_header() {
  printf 'Running bots: %s    Total tracked: %s    Repo: %s' "$1" "$2" "$3"
}

# Format one bot's row. selected=1 prefixes a "> " marker; the caller adds any
# colour/highlight so this stays a deterministic string.
fmt_bot_line() {
  local sel="$1" id="$2" pid="$3" status="$4" up="$5" last="$6"
  local marker='  '
  [ "$sel" = "1" ] && marker='> '
  printf '%s#%-3s pid %-7s %-8s %-7s | %s' "$marker" "$id" "$pid" "$status" "$up" "$last"
}
# <<< tui-pure helpers <<<

# --- Argument parsing --------------------------------------------------------
START_BOTS=1
REPO_DIR=""
LOOP_SCRIPT=""
LOOP_ARGS=()

usage() {
  # Print the leading comment header (from the title line to the first
  # non-comment line), stripping the "# " prefix.
  awk 'NR<3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bots)         need_arg $# "$1"; START_BOTS="$2"; shift ;;
    --bots=*)       START_BOTS="${1#*=}" ;;
    --repo-dir)     need_arg $# "$1"; REPO_DIR="$2"; shift ;;
    --repo-dir=*)   REPO_DIR="${1#*=}" ;;
    --loop-script)  need_arg $# "$1"; LOOP_SCRIPT="$2"; shift ;;
    --loop-script=*) LOOP_SCRIPT="${1#*=}" ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; while [ $# -gt 0 ]; do LOOP_ARGS+=("$1"); shift; done; break ;;
    *)              LOOP_ARGS+=("$1") ;;  # forward unknown args to each bot
  esac
  shift
done

case "$START_BOTS" in ''|*[!0-9]*) die "--bots must be a non-negative integer" ;; esac

# --- Resolve paths -----------------------------------------------------------
# Resolve this script to an absolute path so the default loop-script location and
# the per-bot state directory are stable regardless of the working directory.
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
  _link="$(readlink "$SCRIPT_PATH")"
  case "$_link" in
    /*) SCRIPT_PATH="$_link" ;;
    *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$_link" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"

REPO_DIR="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="${LOOP_SCRIPT:-$SCRIPT_DIR/copilot-loop.sh}"

[ -f "$LOOP_SCRIPT" ] || die "copilot-loop.sh not found at: $LOOP_SCRIPT (use --loop-script)"
[ -x "$LOOP_SCRIPT" ] || die "copilot-loop.sh is not executable: $LOOP_SCRIPT"

STATE_DIR="$REPO_DIR/.copilot-loop/tui"

# Repo slug (owner/repo) for the header, derived portably from the origin URL
# without relying on non-greedy regex (BSD sed rejects it). Best effort; falls
# back to the directory name.
_slug="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"
_slug="${_slug%.git}"
_slug="${_slug//:/\/}"          # unify scp-style git@host:owner/repo into /-paths
_repo="${_slug##*/}"
_slug="${_slug%/*}"
_owner="${_slug##*/}"
if [ -n "$_repo" ] && [ -n "$_owner" ] && [ "$_owner" != "$_repo" ]; then
  REPO_SLUG="$_owner/$_repo"
else
  REPO_SLUG="$(basename "$REPO_DIR")"
fi
unset _slug _repo _owner

# --- Bot lifecycle -----------------------------------------------------------
# Read the pid recorded for a bot (digits only), or nothing when absent.
bot_pid() {
  local f="$STATE_DIR/bot-$1.pid"
  [ -f "$f" ] || { printf ''; return; }
  head -n1 "$f" 2>/dev/null | tr -dc '0-9'
}

# True when the bot's recorded process is still alive.
bot_alive() {
  local pid; pid="$(bot_pid "$1")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# List tracked bot ids, numerically sorted, one per line.
list_bot_ids() {
  [ -d "$STATE_DIR" ] || return 0
  local f base id
  for f in "$STATE_DIR"/bot-*.pid; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"; id="${base#bot-}"; id="${id%.pid}"
    printf '%s\n' "$id"
  done | sort -n
}

# Count how many tracked bots are currently running.
count_running() {
  local id n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    bot_alive "$id" && n=$(( n + 1 ))
  done < <(list_bot_ids)
  printf '%s' "$n"
}

# Uptime (seconds) of a bot, derived from its pidfile mtime; empty when unknown.
bot_uptime() {
  local f="$STATE_DIR/bot-$1.pid" m now
  m="$(_stat_mtime "$f")"
  [ "$m" -gt 0 ] 2>/dev/null || { printf ''; return; }
  now="$(date +%s)"
  printf '%s' "$(( now - m ))"
}

# The last non-empty line a bot logged (its most recent status).
bot_last_log() {
  local f="$STATE_DIR/bot-$1.log"
  [ -f "$f" ] || { printf ''; return; }
  awk 'NF{last=$0} END{if (last!="") print last}' "$f" 2>/dev/null
}

# Spawn one new bot: an ordinary copilot-loop.sh run, detached so it outlives the
# TUI, with its output captured to a per-bot log. Records the pid (and, when
# setsid is used, a marker noting the process group can be signalled as a whole).
spawn_bot() {
  mkdir -p "$STATE_DIR" || { log "cannot create state dir $STATE_DIR"; return 1; }
  local id; id="$(list_bot_ids | next_bot_id)"
  local logf="$STATE_DIR/bot-$id.log" pidf="$STATE_DIR/bot-$id.pid"
  : > "$logf"

  # --quiet keeps each bot's log to clean loop-status lines; the full Copilot
  # transcript still lands under <repo>/.copilot-loop/logs/. Everything after is
  # forwarded so any copilot-loop.sh flag works.
  local -a cmd=("$LOOP_SCRIPT" --repo-dir "$REPO_DIR" --quiet)
  cmd+=(${LOOP_ARGS[@]+"${LOOP_ARGS[@]}"})

  local pid
  if command -v setsid >/dev/null 2>&1; then
    setsid "${cmd[@]}" >"$logf" 2>&1 </dev/null &
    pid=$!
    : > "$STATE_DIR/bot-$id.grp"   # pid leads its own group -> group-killable
  else
    nohup "${cmd[@]}" >"$logf" 2>&1 </dev/null &
    pid=$!
  fi
  disown "$pid" 2>/dev/null || disown 2>/dev/null || true
  printf '%s\n' "$pid" > "$pidf"
  log "spawned bot #$id (pid $pid)"
}

# Stop one bot: TERM (its whole group when setsid gave us one), escalate to KILL
# after a short grace period, then drop its tracking files.
stop_bot() {
  local id="$1"
  local pidf="$STATE_DIR/bot-$id.pid" grpf="$STATE_DIR/bot-$id.grp"
  local pid; pid="$(bot_pid "$id")"
  if [ -z "$pid" ]; then rm -f "$pidf" "$grpf"; return; fi

  local target="$pid"
  [ -f "$grpf" ] && target="-$pid"
  kill -TERM "$target" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  local w=0
  while [ "$w" -lt 15 ]; do
    bot_alive "$id" || break
    sleep 0.2
    w=$(( w + 1 ))
  done
  if bot_alive "$id"; then
    kill -KILL "$target" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidf" "$grpf"
  log "stopped bot #$id"
}

# Stop every tracked bot.
stop_all_bots() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] && stop_bot "$id"
  done < <(list_bot_ids)
}

# Forget bots whose process has exited, clearing their tracking files.
clear_stopped_bots() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    bot_alive "$id" && continue
    rm -f "$STATE_DIR/bot-$id.pid" "$STATE_DIR/bot-$id.grp"
  done < <(list_bot_ids)
}

# --- Terminal handling -------------------------------------------------------
# Guard so init/restore are idempotent (view_bot_log restores then re-inits).
TUI_ACTIVE=0

tui_init() {
  [ "$TUI_ACTIVE" = 1 ] && return 0
  if [ -t 1 ]; then
    tput smcup 2>/dev/null || true   # alternate screen buffer
    tput civis 2>/dev/null || true   # hide cursor
  fi
  [ -t 0 ] && stty -echo 2>/dev/null || true
  TUI_ACTIVE=1
}

tui_restore() {
  [ "$TUI_ACTIVE" = 0 ] && return 0
  [ -t 0 ] && stty echo 2>/dev/null || true
  if [ -t 1 ]; then
    tput cnorm 2>/dev/null || true   # show cursor
    tput rmcup 2>/dev/null || true   # leave alternate screen
  fi
  TUI_ACTIVE=0
}

# A row of dashes n columns wide (ASCII, so no multibyte width surprises).
hr() {
  local n="$1" s
  [ "$n" -gt 0 ] 2>/dev/null || n=0
  s="$(printf '%*s' "$n" '')"
  printf '%s' "${s// /-}"
}

# Read a single key with a timeout (seconds). Resolves arrow-key escape
# sequences to up/down/left/right and Enter to "enter"; prints nothing on
# timeout so the caller can treat that as "refresh".
read_key() {
  local timeout="$1" c rest
  IFS= read -rsn1 -t "$timeout" c || { printf ''; return; }
  if [ -z "$c" ]; then printf 'enter'; return; fi
  if [ "$c" = $'\x1b' ]; then
    rest=''
    IFS= read -rsn2 -t 0.05 rest 2>/dev/null || true
    case "$rest" in
      '[A') printf 'up' ;;
      '[B') printf 'down' ;;
      '[C') printf 'right' ;;
      '[D') printf 'left' ;;
      *)    printf 'esc' ;;
    esac
    return
  fi
  printf '%s' "$c"
}

# --- Rendering ---------------------------------------------------------------
render() {
  local selected="$1"
  local cols; cols="$(tput cols 2>/dev/null || echo 80)"
  local width=$(( cols - 4 )); [ "$width" -gt 0 ] || width=76
  local running total
  running="$(count_running)"
  total="${#IDS[@]}"

  tput clear 2>/dev/null || printf '\033[2J\033[H'
  printf '  copilot-loop TUI\n'
  printf '  %s\n' "$(hr "$width")"
  printf '  %s\n\n' "$(render_header "$running" "$total" "$REPO_SLUG")"

  if [ "$total" -eq 0 ]; then
    printf '  (no bots yet — press [s] to spawn one)\n'
  fi

  local i id pid status up last sel line lastcol
  lastcol=$(( width - 34 )); [ "$lastcol" -gt 10 ] || lastcol=10
  for i in "${!IDS[@]}"; do
    id="${IDS[$i]}"
    pid="$(bot_pid "$id")"
    if bot_alive "$id"; then status='running'; else status='stopped'; pid='----'; fi
    up="$(fmt_uptime "$(bot_uptime "$id")")"
    last="$(truncate_display "$(sanitize_line "$(bot_last_log "$id")")" "$lastcol")"
    sel=0; [ "$i" = "$selected" ] && sel=1
    line="$(fmt_bot_line "$sel" "$id" "$pid" "$status" "$up" "$last")"
    if [ "$sel" = 1 ]; then
      printf '  \033[7m%s\033[0m\n' "$line"
    else
      printf '  %s\n' "$line"
    fi
  done

  printf '\n  %s\n' "$(hr "$width")"

  # Log preview for the selected bot.
  if [ "$total" -gt 0 ]; then
    local selid="${IDS[$selected]}" logf
    logf="$STATE_DIR/bot-$selid.log"
    printf '  Bot #%s log (last lines) — [l] to open full log:\n' "$selid"
    if [ -s "$logf" ]; then
      local ln
      while IFS= read -r ln; do
        printf '    %s\n' "$(truncate_display "$(sanitize_line "$ln")" "$width")"
      done < <(tail -n 6 "$logf" 2>/dev/null)
    else
      printf '    (no output yet)\n'
    fi
    printf '  %s\n' "$(hr "$width")"
  fi

  printf '  [s]pawn  [x]stop  [a]ll-stop  [j/k]select  [l]og  [c]lear  [r]efresh  [?]help  [q]uit\n'
}

view_bot_log() {
  local id="$1" logf="$STATE_DIR/bot-$1.log"
  [ -f "$logf" ] || return 0
  tui_restore
  if command -v less >/dev/null 2>&1; then
    less +G -- "$logf"
  else
    tail -n 200 -- "$logf"
    printf '\n[press Enter to return] '
    IFS= read -r _ || true
  fi
  tui_init
}

show_help() {
  tput clear 2>/dev/null || printf '\033[2J\033[H'
  cat <<'EOF'
  copilot-loop TUI — help
  --------------------------------------------------------------
  Each bot is a copilot-loop.sh process working the issue queue,
  exactly as if you had run the loop yourself. The GitHub lock and
  per-issue worktrees let many bots share one repo safely.

  Keys:
    s / n      spawn a new bot
    x / d      stop the selected bot
    a          stop every bot
    j / k      move selection down / up (arrow keys too)
    l / Enter  open the selected bot's log in a pager
    c          clear stopped bots from the list
    r          refresh now
    q          quit (offers to stop running bots first)

  Bots run detached: quitting the TUI leaves them working, and the
  next launch re-attaches to them. Full Copilot transcripts are under
  <repo>/.copilot-loop/logs/; the per-bot log shown here is the loop's
  own status stream.

  Press any key to return.
EOF
  read_key 999 >/dev/null
}

confirm_quit() {
  local n; n="$(count_running)"
  [ "$n" -gt 0 ] || return 0
  tui_restore
  printf 'Stop all %s running bot(s) before quitting? [y/N] ' "$n"
  local ans; IFS= read -r ans || ans=''
  case "$ans" in
    y|Y|yes|YES) stop_all_bots ;;
    *)           log "leaving $n bot(s) running in the background" ;;
  esac
  return 0
}

# --- Main --------------------------------------------------------------------
IDS=()

main() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "the TUI needs an interactive terminal (stdin and stdout must be a tty)"
  fi

  # Soft preflight: warn about missing tools the bots need, but still open so the
  # operator can inspect and manage existing bots.
  local missing=""
  local bin
  for bin in git gh copilot; do
    command -v "$bin" >/dev/null 2>&1 || missing="${missing:+$missing }$bin"
  done
  if [ -n "$missing" ]; then
    log "WARNING: missing on PATH: $missing — bots may fail until installed"
    sleep 1
  fi

  tui_init
  trap 'tui_restore' EXIT
  trap 'tui_restore; exit 130' INT TERM

  local i
  for (( i = 0; i < START_BOTS; i++ )); do spawn_bot; done

  local selected=0 key action count _id
  while true; do
    IDS=()
    while IFS= read -r _id; do
      [ -n "$_id" ] && IDS+=("$_id")
    done < <(list_bot_ids)
    count="${#IDS[@]}"
    selected="$(clamp_selection "$selected" "$count")"
    render "$selected"

    key="$(read_key 2)"
    [ -z "$key" ] && continue          # timeout -> periodic refresh
    action="$(tui_action_for_key "$key")"
    case "$action" in
      spawn)    spawn_bot ;;
      stop)     [ "$count" -gt 0 ] && stop_bot "${IDS[$selected]}" ;;
      stop-all) stop_all_bots ;;
      up)       selected="$(clamp_selection $(( selected - 1 )) "$count")" ;;
      down)     selected="$(clamp_selection $(( selected + 1 )) "$count")" ;;
      log)      [ "$count" -gt 0 ] && view_bot_log "${IDS[$selected]}" ;;
      clear)    clear_stopped_bots ;;
      refresh)  : ;;
      help)     show_help ;;
      quit)     confirm_quit; break ;;
      none)     : ;;
    esac
  done
}

# Only run when executed directly, so the unit tests can source/extract the pure
# helpers without launching the interface.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
