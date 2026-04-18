#!/usr/bin/env bash
set -uo pipefail

BASE_PORT="${1:-7681}"
DURATION="${DURATION:-6h}"
PROJECTS_DIR="${HOME}/projects"

NEW_PROJECT_LABEL="[ New project ]"
ATTACH_PROJECT_LABEL="[ Attach to existing project ]"
STOP_EXPORT_LABEL="[ Stop existing export ]"
REINIT_EXPORT_LABEL="[ Reinitialize web access ]"
MANUAL_PROJECT_LABEL="[ Type project name manually ]"
WEB_ACCESS_LABEL="[ Open web access ]"
LOCAL_ATTACH_LABEL="[ Attach in this terminal ]"
ACTION_ITEM_COUNT=4

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 1
  }
}

need tmux
need git
need mkdir
need ps
need awk
need grep
need sed
need find

mkdir -p "$PROJECTS_DIR"

selected=0
CHOSEN_ITEM=""

refresh_sessions() {
  mapfile -t TMUX_SESSIONS < <(tmux list-sessions -F '#S' 2>/dev/null || true)
  MENU_ITEMS=(
    "$NEW_PROJECT_LABEL"
    "$ATTACH_PROJECT_LABEL"
    "$STOP_EXPORT_LABEL"
    "$REINIT_EXPORT_LABEL"
  )
  MENU_ITEMS+=("${TMUX_SESSIONS[@]}")
}

need_web_tools() {
  need ttyd
  need timeout
}

draw_menu() {
  local i label info

  printf '\033[2J\033[H'
  echo "Choose an action"
  echo "Persistent tmux sessions with explicit web export or local terminal attach."
  echo
  echo "  ↑/↓ or j/k = move    Enter = select    q = quit"
  echo

  echo "Project and web actions"
  echo
  for ((i = 0; i < ACTION_ITEM_COUNT; i++)); do
    label="${MENU_ITEMS[$i]}"
    if [[ "$i" -eq "$selected" ]]; then
      printf '  > %s\n' "$label"
    else
      printf '    %s\n' "$label"
    fi
  done

  echo
  echo "Running tmux sessions"
  if [[ ${#TMUX_SESSIONS[@]} -eq 0 ]]; then
    echo
    echo "    No running tmux sessions."
  else
    echo
    echo "  Select one to choose web access or attach in this terminal."
    echo
    for ((i = ACTION_ITEM_COUNT; i < ${#MENU_ITEMS[@]}; i++)); do
      label="tmux session: ${MENU_ITEMS[$i]}"
      if info="$(get_existing_export "${MENU_ITEMS[$i]}")"; then
        label="$label [web active]"
      else
        label="$label [no web export]"
      fi

      if [[ "$i" -eq "$selected" ]]; then
        printf '  > %s\n' "$label"
      else
        printf '    %s\n' "$label"
      fi
    done
  fi

  echo
  echo "Base port: $BASE_PORT"
  echo "Web export timeout: $DURATION"
  echo "Select a running tmux session to choose browser or direct SSH/CLI attach."
  echo "tmux/codex sessions are persistent."
}

pause_message() {
  local msg="${1:-Press Enter to continue.}"
  echo > /dev/tty
  read -r -p "$msg" _ < /dev/tty || true
}

valid_project_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" != "." && "$name" != ".." ]] || return 1
  [[ "$name" != */* ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

prompt_project_name() {
  local title="${1:-Project name}"
  local name

  printf '\033[2J\033[H' > /dev/tty
  echo "$title" > /dev/tty
  echo > /dev/tty
  echo "Allowed characters: a-z A-Z 0-9 . _ -" > /dev/tty
  echo "Empty input cancels." > /dev/tty
  echo > /dev/tty

  read -r -p "Project name: " name < /dev/tty || true
  printf '%s' "$name"
}

choose_from_list() {
  local title="$1"
  shift
  local items=("$@")
  local idx=0
  local key rest

  if [[ ${#items[@]} -eq 0 ]]; then
    return 1
  fi

  while true; do
    printf '\033[2J\033[H' > /dev/tty
    echo "$title" > /dev/tty
    echo > /dev/tty
    echo "  ↑/↓ or j/k = move    Enter = select    q = cancel" > /dev/tty
    echo > /dev/tty
    for i in "${!items[@]}"; do
      if [[ "$i" -eq "$idx" ]]; then
        printf '  > %s\n' "${items[$i]}" > /dev/tty
      else
        printf '    %s\n' "${items[$i]}" > /dev/tty
      fi
    done

    IFS= read -rsn1 key < /dev/tty || true
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.05 rest < /dev/tty || true
      key+="${rest:-}"
    fi

    case "$key" in
      $'\x1b[A'|k)
        idx=$((idx - 1))
        if [[ "$idx" -lt 0 ]]; then
          idx=$((${#items[@]} - 1))
        fi
        ;;
      $'\x1b[B'|j)
        idx=$((idx + 1))
        if [[ "$idx" -ge "${#items[@]}" ]]; then
          idx=0
        fi
        ;;
      "")
        CHOSEN_ITEM="${items[$idx]}"
        return 0
        ;;
      q|Q)
        return 1
        ;;
    esac
  done
}

choose_access_for_session() {
  local session="$1"
  local title="${2:-Choose how to access this tmux session}"

  if ! choose_from_list "$title" "$WEB_ACCESS_LABEL" "$LOCAL_ATTACH_LABEL"; then
    return 1
  fi

  case "$CHOSEN_ITEM" in
    "$WEB_ACCESS_LABEL")
      start_export_for_session "$session"
      ;;
    "$LOCAL_ATTACH_LABEL")
      attach_local_for_session "$session"
      ;;
  esac
}

host_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

host_name() {
  local h
  h="${HOSTNAME:-$(hostname 2>/dev/null || true)}"
  if [[ -n "$h" ]]; then
    printf '%s\n' "$h"
  else
    hostname -f 2>/dev/null || printf 'localhost\n'
  fi
}

port_in_use() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"
    return
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0 || return 1
}

find_free_port() {
  local port="$BASE_PORT"
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

list_export_processes() {
  ps -eo pid=,args= | grep '[t]tyd ' || true
}

get_existing_export() {
  local session="$1"
  local line pid args port
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pid="$(awk '{print $1}' <<<"$line")"
    args="${line#"$pid"}"
    if [[ "$args" == *"titleFixed=tmux:$session"* ]] && [[ "$args" == *"tmux attach -t $session"* ]]; then
      port="$(sed -n 's/.* -p \([0-9][0-9]*\).*/\1/p' <<<"$args" | head -n1)"
      [[ -n "$port" ]] || port="?"
      printf '%s|%s\n' "$pid" "$port"
      return 0
    fi
  done < <(list_export_processes)
  return 1
}

print_export_info() {
  local title="$1"
  local session="$2"
  local pid="$3"
  local port="$4"
  local ip host

  ip="$(host_ip)"
  host="$(host_name)"
  [[ -n "$ip" ]] || ip="127.0.0.1"

  printf '\033[2J\033[H'
  echo "$title"
  echo
  echo "Session: $session"
  echo "PID:     $pid"
  echo "Port:    $port"
  echo "URL:     http://$ip:$port"
  echo "URL:     http://$host:$port"
  echo
  echo "This timeout only applies to the web export."
  echo "The tmux/codex session keeps running."
  echo
  echo "Browser scrollback is enabled."
  echo "For deeper tmux history too, add this to ~/.tmux.conf:"
  echo "  set -g history-limit 50000"
  echo "  set -g mouse on"
  echo
}

attach_local_for_session() {
  local session="$1"
  local switch_err=""
  local switch_err_file=""
  local attach_err=""
  local attach_err_file=""

  if ! tmux has-session -t "$session" 2>/dev/null; then
    printf '\033[2J\033[H'
    echo "No tmux session named '$session' was found."
    pause_message
    return 1
  fi

  if [[ -n "${TMUX:-}" ]]; then
    switch_err_file="$(mktemp 2>/dev/null || true)"
    if [[ -n "$switch_err_file" ]]; then
      if tmux switch-client -t "$session" 2>"$switch_err_file"; then
        rm -f "$switch_err_file"
        return 0
      fi
      switch_err="$(cat "$switch_err_file" 2>/dev/null || true)"
      rm -f "$switch_err_file"
    else
      if tmux switch-client -t "$session"; then
        return 0
      fi
    fi
  fi

  printf '\033[2J\033[H'
  echo "Attaching tmux in this terminal."
  echo
  echo "Session: $session"
  echo "This is a direct tmux attach in your current SSH/CLI session."
  echo "No web export is involved, so tmux sees your terminal directly."
  echo "Detach with your tmux prefix followed by d."
  echo

  attach_err_file="$(mktemp 2>/dev/null || true)"

  if [[ -n "$attach_err_file" ]]; then
    if TMUX='' tmux attach -t "$session" 2>"$attach_err_file"; then
      rm -f "$attach_err_file"
      return 0
    fi
    attach_err="$(cat "$attach_err_file" 2>/dev/null || true)"
    rm -f "$attach_err_file"
  else
    if TMUX='' tmux attach -t "$session"; then
      return 0
    fi
  fi

  printf '\033[2J\033[H'
  echo "Failed to open local tmux access for session '$session'."
  echo

  if [[ -n "$attach_err" ]]; then
    echo "$attach_err"
  elif [[ -n "$switch_err" ]]; then
    echo "$switch_err"
  else
    echo "tmux did not return a specific error message."
  fi

  echo
  echo "The script tried switch-client first, then a direct attach with TMUX cleared."
  pause_message
  return 1
}

stop_export_for_session_quiet() {
  local session="$1"
  local info pid

  if ! info="$(get_existing_export "$session")"; then
    return 0
  fi

  IFS='|' read -r pid _ <<<"$info"

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
}

stop_export_for_session() {
  local session="$1"
  local info pid port ip host

  if ! info="$(get_existing_export "$session")"; then
    printf '\033[2J\033[H'
    echo "No active web export found for session '$session'."
    pause_message
    return
  fi

  IFS='|' read -r pid port <<<"$info"
  ip="$(host_ip)"
  host="$(host_name)"
  [[ -n "$ip" ]] || ip="127.0.0.1"

  stop_export_for_session_quiet "$session"

  printf '\033[2J\033[H'
  echo "Stopped web export for session '$session'."
  echo
  echo "Previous URL: http://$ip:$port"
  echo "Previous URL: http://$host:$port"
  echo
  echo "The tmux/codex session is still running."
  pause_message
}

start_export_for_session() {
  local session="$1"
  local info pid port

  if info="$(get_existing_export "$session")"; then
    IFS='|' read -r pid port <<<"$info"
    print_export_info "Session is already exported." "$session" "$pid" "$port"
    exit 0
  fi

  need_web_tools

  port="$(find_free_port)"

  nohup \
    timeout --foreground -k 10s "$DURATION" \
    ttyd \
      -W \
      -m 1 \
      -p "$port" \
      -t "titleFixed=tmux:$session" \
      -t "scrollback=20000" \
      -t "scrollOnUserInput=false" \
      tmux attach -t "$session" \
    >/dev/null 2>&1 < /dev/null &

  pid=$!
  sleep 0.2

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Failed to start ttyd for session '$session'." >&2
    exit 1
  fi

  print_export_info "Started web export for session." "$session" "$pid" "$port"
  exit 0
}

reinitialize_export_for_session() {
  local session="$1"
  stop_export_for_session_quiet "$session"
  start_export_for_session "$session"
}

create_or_resume_project_session() {
  local project_name="$1"
  local project_dir="$PROJECTS_DIR/$project_name"
  local dir_existed=0
  local quoted_dir launch_cmd

  if [[ -d "$project_dir" ]]; then
    dir_existed=1
  else
    mkdir -p "$project_dir"
  fi

  (
    cd "$project_dir"
    git init >/dev/null 2>&1
  )

  quoted_dir="$(printf '%q' "$project_dir")"

  if [[ "$dir_existed" -eq 1 ]]; then
    launch_cmd="cd $quoted_dir && exec codex resume"
  else
    launch_cmd="cd $quoted_dir && exec codex"
  fi

  tmux new-session -d -s "$project_name" "$launch_cmd"
}

create_new_project_session() {
  local project_name

  while true; do
    project_name="$(prompt_project_name "Create new project")"

    if [[ -z "$project_name" ]]; then
      return
    fi

    if ! valid_project_name "$project_name"; then
      printf '\033[2J\033[H'
      echo "Invalid project name."
      echo
      echo "Use only: a-z A-Z 0-9 . _ -"
      pause_message "Press Enter to try again."
      continue
    fi

    if tmux has-session -t "$project_name" 2>/dev/null; then
      choose_access_for_session "$project_name" "Project session already exists - choose access"
      return
    fi

    create_or_resume_project_session "$project_name"
    choose_access_for_session "$project_name" "Choose how to access the new project session"
    return
  done
}

attach_existing_project() {
  local dirs=()
  local path name chosen project_name project_dir

  if [[ -d "$PROJECTS_DIR" ]]; then
    while IFS= read -r -d '' path; do
      name="$(basename "$path")"
      dirs+=("$name")
    done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
  fi

  dirs+=("$MANUAL_PROJECT_LABEL")

  if ! choose_from_list "Choose project directory" "${dirs[@]}"; then
    return
  fi
  chosen="$CHOSEN_ITEM"

  if [[ "$chosen" == "$MANUAL_PROJECT_LABEL" ]]; then
    project_name="$(prompt_project_name "Attach to existing project")"
    [[ -n "$project_name" ]] || return
    if ! valid_project_name "$project_name"; then
      printf '\033[2J\033[H'
      echo "Invalid project name."
      echo
      echo "Use only: a-z A-Z 0-9 . _ -"
      pause_message
      return
    fi
  else
    project_name="$chosen"
  fi

  project_dir="$PROJECTS_DIR/$project_name"

  if tmux has-session -t "$project_name" 2>/dev/null; then
    choose_access_for_session "$project_name" "Project session already exists - choose access"
    return
  fi

  mkdir -p "$project_dir"
  (
    cd "$project_dir"
    git init >/dev/null 2>&1
  )
  tmux new-session -d -s "$project_name" "cd $(printf '%q' "$project_dir") && exec codex resume"
  choose_access_for_session "$project_name" "Choose how to access the project session"
}

choose_and_stop_export() {
  local sessions=()
  local session

  refresh_sessions

  for session in "${TMUX_SESSIONS[@]}"; do
    if get_existing_export "$session" >/dev/null; then
      sessions+=("$session")
    fi
  done

  if [[ ${#sessions[@]} -eq 0 ]]; then
    printf '\033[2J\033[H'
    echo "No active web exports found."
    pause_message
    return
  fi

  if choose_from_list "Choose web export to stop" "${sessions[@]}"; then
    stop_export_for_session "$CHOSEN_ITEM"
  fi
}

choose_and_reinitialize_export() {
  local sessions=()
  local session

  refresh_sessions

  for session in "${TMUX_SESSIONS[@]}"; do
    if get_existing_export "$session" >/dev/null; then
      sessions+=("$session")
    fi
  done

  if [[ ${#sessions[@]} -eq 0 ]]; then
    printf '\033[2J\033[H'
    echo "No active web exports found."
    pause_message
    return
  fi

  if choose_from_list "Choose web export to reinitialize" "${sessions[@]}"; then
    reinitialize_export_for_session "$CHOSEN_ITEM"
  fi
}

refresh_sessions

while true; do
  refresh_sessions

  if [[ $selected -ge ${#MENU_ITEMS[@]} ]]; then
    selected=0
  fi

  draw_menu

  IFS= read -rsn1 key < /dev/tty || true

  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.05 rest < /dev/tty || true
    key+="${rest:-}"
  fi

  case "$key" in
    $'\x1b[A'|k)
      selected=$((selected - 1))
      if [[ "$selected" -lt 0 ]]; then
        selected=$((${#MENU_ITEMS[@]} - 1))
      fi
      ;;
    $'\x1b[B'|j)
      selected=$((selected + 1))
      if [[ "$selected" -ge "${#MENU_ITEMS[@]}" ]]; then
        selected=0
      fi
      ;;
    "")
      chosen="${MENU_ITEMS[$selected]}"
      case "$chosen" in
        "$NEW_PROJECT_LABEL")
          create_new_project_session
          ;;
        "$ATTACH_PROJECT_LABEL")
          attach_existing_project
          ;;
        "$STOP_EXPORT_LABEL")
          choose_and_stop_export
          ;;
        "$REINIT_EXPORT_LABEL")
          choose_and_reinitialize_export
          ;;
        *)
          choose_access_for_session "$chosen" "Choose how to access tmux session '$chosen'"
          ;;
      esac
      ;;
    q|Q)
      printf '\033[2J\033[H'
      exit 0
      ;;
  esac
done
