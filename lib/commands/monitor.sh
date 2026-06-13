# shellcheck shell=bash
# monitor.sh - Monitor NTP synchronization status
# Sourced by ntp-tools dispatcher; do not execute directly.

show_help() {
  cat <<EOF
Usage: ntp-tools monitor [options]

Monitor system NTP synchronization status and health.

Options:
  -w, --watch      Run continuously until Ctrl+C
  -i, --interval N Interval in seconds between cycles (default: 5)
  -n, --count N    Number of cycles to run
  -h, --help       Show this help

Examples:
  ntp-tools monitor
  ntp-tools monitor --watch
  ntp-tools monitor --watch --interval 10
  ntp-tools monitor --count 3
EOF
}

_mon_daemon_status() {
  local daemon
  daemon=$(detect_ntp_daemon)
  echo -e "${BLUE}=== NTP Daemon ===${NC}"
  case "$daemon" in
    chrony)    echo -e "  chrony (chronyd):        ${GREEN}Running${NC}" ;;
    ntpd)      echo -e "  ntpd:                    ${GREEN}Running${NC}" ;;
    timesyncd) echo -e "  systemd-timesyncd:       ${GREEN}Running${NC}" ;;
    openntpd)  echo -e "  openntpd:                ${GREEN}Running${NC}" ;;
    none)
      echo -e "  ${RED}No NTP daemon detected${NC}"
      echo "  Install and start one of: chronyd, ntpd, systemd-timesyncd, openntpd"
      return 1
      ;;
  esac
  echo
}

_mon_sync_status() {
  local daemon
  daemon=$(detect_ntp_daemon)
  echo -e "${BLUE}=== Synchronization Status ===${NC}"
  case "$daemon" in
    chrony)
      local trk
      trk=$(chronyc tracking 2>/dev/null)
      if [[ -n "$trk" ]]; then
        echo "$trk"
        echo
        echo -e "${GREEN}Key metrics:${NC}"
        local stratum offset rms ref
        stratum=$(echo "$trk" | grep "Stratum"        | awk -F': ' '{print $2}')
        offset=$(echo  "$trk" | grep "Last offset"    | awk -F': ' '{print $2}')
        rms=$(echo     "$trk" | grep "RMS offset"     | awk -F': ' '{print $2}')
        ref=$(echo     "$trk" | grep "Reference time" | awk -F': ' '{print $2}')
        [[ -n "$stratum" ]] && echo "  Stratum:        $stratum"
        [[ -n "$ref"     ]] && echo "  Reference time: $ref"
        [[ -n "$offset"  ]] && echo "  Last offset:    $offset"
        [[ -n "$rms"     ]] && echo "  RMS offset:     $rms"
      else
        echo -e "${YELLOW}Cannot retrieve chrony tracking${NC}"
      fi
      ;;
    ntpd)
      if command_exists ntpstat; then
        ntpstat 2>/dev/null || echo -e "${YELLOW}ntpstat failed${NC}"
      fi
      if command_exists ntpq; then
        echo
        ntpq -c rv 2>/dev/null || echo -e "${YELLOW}ntpq failed${NC}"
      fi
      ;;
    timesyncd)
      if command_exists timedatectl; then
        timedatectl timesync-status 2>/dev/null \
          || timedatectl show-timesync --all 2>/dev/null \
          || echo -e "${YELLOW}Cannot retrieve timesyncd status${NC}"
      fi
      ;;
    openntpd)
      if command_exists ntpctl; then
        ntpctl -s status 2>/dev/null || echo -e "${YELLOW}ntpctl failed${NC}"
      fi
      ;;
    none)
      echo -e "${RED}No NTP daemon running${NC}"
      ;;
  esac
  echo
}

_mon_sources() {
  local daemon
  daemon=$(detect_ntp_daemon)
  echo -e "${BLUE}=== Time Sources ===${NC}"
  case "$daemon" in
    chrony)
      local src
      src=$(chronyc sources -v 2>/dev/null)
      if [[ -n "$src" ]]; then
        echo "$src"
        echo
        echo -e "${GREEN}Source statistics:${NC}"
        chronyc sourcestats 2>/dev/null || echo -e "${YELLOW}Cannot retrieve sourcestats${NC}"
      else
        echo -e "${YELLOW}Cannot retrieve chrony sources${NC}"
      fi
      ;;
    ntpd)
      command_exists ntpq \
        && ntpq -p 2>/dev/null \
        || echo -e "${YELLOW}ntpq not available${NC}"
      ;;
    timesyncd)
      command_exists timedatectl \
        && timedatectl show-timesync --all 2>/dev/null \
        || echo -e "${YELLOW}timedatectl not available${NC}"
      ;;
    openntpd)
      command_exists ntpctl \
        && ntpctl -s peers 2>/dev/null \
        || echo -e "${YELLOW}ntpctl not available${NC}"
      ;;
    none)
      echo -e "${RED}No NTP daemon running${NC}"
      ;;
  esac
  echo
}

_mon_clock() {
  echo -e "${BLUE}=== System Clock ===${NC}"
  echo "  Local:    $(date)"
  echo "  UTC:      $(date -u)"
  echo "  Timezone: $(date +%Z) ($(date +%z))"
  if command_exists timedatectl; then
    echo
    timedatectl status 2>/dev/null | grep -E "Local time|Time zone|NTP|synchronized" | sed 's/^/  /'
  fi
  echo
}

_mon_cycle() {
  local n="$1"
  echo -e "${YELLOW}=== Cycle #$n — $(date) ===${NC}"
  echo
  _mon_daemon_status
  _mon_sync_status
  _mon_sources
  _mon_clock
  echo -e "${BLUE}=== End of cycle #$n ===${NC}"
  echo
}

main() {
  local INTERVAL=5 COUNT=0
  local MODE="once"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) show_help; return 0 ;;
      -w|--watch) MODE="watch"; shift ;;
      -i|--interval)
        [[ -z "${2:-}" ]] && { error "Missing argument for --interval"; return 1; }
        INTERVAL="$2"; shift 2 ;;
      -n|--count)
        [[ -z "${2:-}" ]] && { error "Missing argument for --count"; return 1; }
        COUNT="$2"; MODE="count"; shift 2 ;;
      -*) error "Unknown option: $1"; return 1 ;;
      *)  error "Unexpected argument: $1"; return 1 ;;
    esac
  done

  if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
    error "Invalid interval: $INTERVAL"
    return 1
  fi

  trap 'echo -e "\n${YELLOW}Monitoring stopped${NC}"; exit 0' INT TERM

  case "$MODE" in
    once)
      _mon_cycle 1
      ;;
    watch)
      echo -e "${GREEN}Continuous monitoring — Ctrl+C to stop (interval: ${INTERVAL}s)${NC}"
      echo
      local n=1
      while true; do
        _mon_cycle "$n"
        echo -e "${BLUE}Next cycle in ${INTERVAL}s...${NC}"
        sleep "$INTERVAL"
        n=$((n + 1))
      done
      ;;
    count)
      if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
        error "Invalid count: $COUNT"
        return 1
      fi
      echo -e "${GREEN}Running $COUNT cycle(s) (interval: ${INTERVAL}s)${NC}"
      echo
      for (( n=1; n<=COUNT; n++ )); do
        _mon_cycle "$n"
        [[ "$n" -lt "$COUNT" ]] && sleep "$INTERVAL"
      done
      echo -e "${GREEN}Completed $COUNT cycle(s)${NC}"
      ;;
  esac
}
