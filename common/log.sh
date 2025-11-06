#!/bin/bash
# common/log.sh
# shared logging + section timing

: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

# store per-section start times
declare -gA __SECTION_STARTS

log_internal() {
  local LEVEL="$1"; shift
  local MESSAGE="$*"
  local TS="[$(date +'%Y-%m-%d %H:%M:%S')]"
  local COLOR RESET

  case "$LEVEL" in
    INFO)    COLOR="\033[1;34m" ;;
    WARN)    COLOR="\033[1;33m" ;;
    ERROR)   COLOR="\033[1;31m" ;;
    DEBUG)   COLOR="\033[1;36m" ;;
    SUCCESS) COLOR="\033[1;92m" ;;
    PROMPT)  COLOR="\033[1;32m" ;;
    *)       COLOR="\033[0m" ;;
  esac
  RESET="\033[0m"

  local SHORT="[$LEVEL] $MESSAGE"
  local FULL="${TS}[$LEVEL][${0##*/}] $MESSAGE"

  if [ -t 1 ]; then
    echo -e "${COLOR}${SHORT}${RESET}" | tee -a "$LOG_FILE"
  else
    echo "$SHORT" >> "$LOG_FILE"
  fi
  echo "$FULL" >> "$LOG_FILE"
}

info()    { log_internal INFO "$@"; }
warn()    { log_internal WARN "$@"; }
error()   { log_internal ERROR "$@"; exit 1; }
debug()   { log_internal DEBUG "$@"; }
success() { log_internal SUCCESS "$@"; }
prompt()  { log_internal PROMPT "$@"; }

section_start() {
  local NAME="$1"
  __SECTION_STARTS["$NAME"]="$(date +%s)"
  info "▶ $NAME ..."
}

section_end() {
  local NAME="$1"
  local END SEC
  END=$(date +%s)
  SEC=0
  if [[ -n "${__SECTION_STARTS[$NAME]}" ]]; then
    SEC=$(( END - __SECTION_STARTS[$NAME] ))
  fi
  success "✔ $NAME completed in ${SEC}s"
}

script_start() {
  SCRIPT_START_TIME=$(date +%s)
}

script_end() {
  local END=$(date +%s)
  local DUR=$(( END - SCRIPT_START_TIME ))
  info "⏱ Total script time: $((DUR/60))m $((DUR%60))s"
}

