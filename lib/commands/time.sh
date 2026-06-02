# time.sh - Get current time from NTP servers
# Sourced by ntp-tools dispatcher; do not execute directly.

show_help() {
  cat <<EOF
Usage: ntp-tools time [options] [SERVER...]

Get current time from one or more NTP servers.

Arguments:
  SERVER...            NTP server(s) to query (default: pool.ntp.org)

Options:
  -f, --format FORMAT  Output format: human, iso, unix (default: human)
  -h, --help           Show this help

Examples:
  ntp-tools time
  ntp-tools time time.google.com
  ntp-tools time -f iso time.cloudflare.com
  ntp-tools time pool.ntp.org time.google.com
EOF
}

_format_timestamp() {
  local timestamp="$1"
  case "$OUTPUT_FORMAT" in
    unix) echo "$timestamp" ;;
    iso)  date -d "@$timestamp" --iso-8601=seconds 2>/dev/null || echo "Invalid timestamp" ;;
    *)    date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "Invalid timestamp" ;;
  esac
}

main() {
  local SERVERS=() OUTPUT_FORMAT="human"
  local TIMEOUT=5

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) show_help; return 0 ;;
      -f|--format)
        [[ -z "${2:-}" ]] && { error "Missing argument for --format"; return 1; }
        OUTPUT_FORMAT="$2"; shift 2 ;;
      -*) error "Unknown option: $1"; return 1 ;;
      *)  SERVERS+=("$1"); shift ;;
    esac
  done

  [[ ${#SERVERS[@]} -eq 0 ]] && SERVERS=("pool.ntp.org")

  case "$OUTPUT_FORMAT" in
    human|iso|unix) ;;
    *) error "Invalid format '$OUTPUT_FORMAT'. Use: human, iso, unix"; return 1 ;;
  esac

  local success=false
  for server in "${SERVERS[@]}"; do
    local result
    result=$(_ntp_query "$server")
    if [[ -n "$result" ]]; then
      _format_timestamp "$(echo "$result" | cut -d'|' -f1)"
      success=true
    else
      error "Failed to get time from $server"
    fi
  done

  [[ "$success" == "false" ]] && return 1
}
