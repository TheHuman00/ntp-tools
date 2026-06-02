# diff.sh - Compare time between two NTP servers
# Sourced by ntp-tools dispatcher; do not execute directly.

show_help() {
  cat <<EOF
Usage: ntp-tools diff [options] SERVER1 [SERVER2]

Compare time between two NTP servers, or between a server and local time.

Arguments:
  SERVER1              Compare against local system time
  SERVER1 SERVER2      Compare two NTP servers

Options:
  -n, --samples N      Number of samples (default: 3)
  -h, --help           Show this help

Examples:
  ntp-tools diff pool.ntp.org
  ntp-tools diff pool.ntp.org time.google.com
  ntp-tools diff -n 5 time.cloudflare.com time.google.com
EOF
}

_diff_get_ntp_timestamp() {
  local server="$1"
  local result
  result=$(_ntp_query "$server") || { echo "$(date +%s.%N)|local_estimate"; return 1; }
  echo "$(echo "$result" | cut -d'|' -f1)|ntp"
}

_diff_get_local_timestamp() {
  echo "$(date +%s.%N)|local_system"
}

_diff_run() {
  local srv1="$1" srv2="$2" label1="$3" label2="$4"
  local diffs=() valid=0

  for (( i=1; i<=SAMPLES; i++ )); do
    [[ "$SAMPLES" -gt 1 ]] && echo -e "${YELLOW}Sample $i/$SAMPLES...${NC}"
    local info1 info2 t1 t2 diff

    [[ "$srv1" == "LOCAL" ]] && info1=$(_diff_get_local_timestamp) || info1=$(_diff_get_ntp_timestamp "$srv1")
    [[ "$srv2" == "LOCAL" ]] && info2=$(_diff_get_local_timestamp) || info2=$(_diff_get_ntp_timestamp "$srv2")

    t1=$(echo "$info1" | cut -d'|' -f1)
    t2=$(echo "$info2" | cut -d'|' -f1)

    if [[ -n "$t1" ]] && [[ -n "$t2" ]]; then
      diff=$(awk "BEGIN{printf \"%.9f\", $t2 - $t1}" 2>/dev/null)
      if [[ -n "$diff" ]]; then
        diffs+=("$diff")
        valid=$((valid + 1))
        [[ "$SAMPLES" -gt 1 ]] && echo "  Diff: ${diff}s"
      else
        echo "  Calculation failed"
      fi
    else
      echo "  Could not get timestamps"
    fi

    [[ "$i" -lt "$SAMPLES" ]] && sleep 1
  done

  echo
  [[ "$valid" -eq 0 ]] && { error "No valid samples"; return 1; }

  local sum=0 min="" max="" avg

  for d in "${diffs[@]}"; do
    sum=$(awk "BEGIN{printf \"%.9f\", $sum + $d}")
    { [[ -z "$min" ]] || awk "BEGIN{exit !($d < $min)}"; } && min="$d"
    { [[ -z "$max" ]] || awk "BEGIN{exit !($d > $max)}"; } && max="$d"
  done
  avg=$(awk "BEGIN{printf \"%.9f\", $sum / $valid}")

  if [[ "$SAMPLES" -eq 1 ]]; then
    echo -e "${GREEN}Time Difference:${NC}"
    echo "  From: $label1"
    echo "  To:   $label2"
    echo
    echo "  Seconds:      $avg"
    echo "  Milliseconds: $(awk "BEGIN{printf \"%.3f\", $avg * 1000}") ms"
    echo "  Microseconds: $(awk "BEGIN{printf \"%.0f\", $avg * 1000000}") µs"
  else
    local var_sum=0
    for d in "${diffs[@]}"; do
      local dev sq
      dev=$(awk "BEGIN{printf \"%.9f\", $d - $avg}")
      sq=$(awk "BEGIN{printf \"%.9f\", $dev * $dev}")
      var_sum=$(awk "BEGIN{printf \"%.9f\", $var_sum + $sq}")
    done
    local std
    std=$(awk "BEGIN{printf \"%.9f\", sqrt($var_sum / $valid)}")

    echo -e "${GREEN}Statistics ($valid samples):${NC}"
    echo "  Average:  $avg s  ($(awk "BEGIN{printf \"%.3f\", $avg * 1000}") ms)"
    echo "  Min:      $min s  ($(awk "BEGIN{printf \"%.3f\", $min * 1000}") ms)"
    echo "  Max:      $max s  ($(awk "BEGIN{printf \"%.3f\", $max * 1000}") ms)"
    echo "  Std dev:  $std s  ($(awk "BEGIN{printf \"%.3f\", $std * 1000}") ms)"
  fi

  local abs_avg
  echo
  echo -e "${BLUE}Interpretation:${NC}"
  if   awk "BEGIN{exit !(${avg#-} < 0.001)}"; then echo -e "  ${GREEN}Excellent (< 1ms)${NC}"
  elif awk "BEGIN{exit !(${avg#-} < 0.01)}";  then echo -e "  ${GREEN}Good (< 10ms)${NC}"
  elif awk "BEGIN{exit !(${avg#-} < 0.1)}";   then echo -e "  ${YELLOW}Acceptable (< 100ms)${NC}"
  elif awk "BEGIN{exit !(${avg#-} < 1)}";     then echo -e "  ${YELLOW}Poor (< 1s)${NC}"
  else                                              echo -e "  ${RED}Very poor (> 1s)${NC}"
  fi

  if awk "BEGIN{exit !($avg > 0)}"; then
    echo "  $label2 is ahead of $label1"
  else
    echo "  $label1 is ahead of $label2"
  fi
}

main() {
  local SERVER1="" SERVER2="" SAMPLES=3
  local TIMEOUT=10

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) show_help; return 0 ;;
      -n|--samples)
        [[ -z "${2:-}" ]] && { error "Missing argument for --samples"; return 1; }
        SAMPLES="$2"; shift 2 ;;
      -*)
        error "Unknown option: $1"; return 1 ;;
      *)
        if   [[ -z "$SERVER1" ]]; then SERVER1="$1"
        elif [[ -z "$SERVER2" ]]; then SERVER2="$1"
        else error "Too many arguments"; return 1
        fi
        shift ;;
    esac
  done

  [[ -z "$SERVER1" ]] && { error "No server specified"; show_help; return 1; }

  [[ -z "$SERVER2" ]] && SERVER2="LOCAL"

  if ! [[ "$SAMPLES" =~ ^[0-9]+$ ]] || [[ "$SAMPLES" -lt 1 ]]; then
    error "Invalid samples count: $SAMPLES"
    return 1
  fi

  [[ "$SERVER1" != "LOCAL" ]] && { validate_ntp_server "$SERVER1" || return 1; }
  [[ "$SERVER2" != "LOCAL" ]] && { validate_ntp_server "$SERVER2" || return 1; }

  local label1 label2
  [[ "$SERVER1" == "LOCAL" ]] && label1="Local system" || label1="$SERVER1"
  [[ "$SERVER2" == "LOCAL" ]] && label2="Local system" || label2="$SERVER2"

  echo -e "${BLUE}=== NTP Time Diff ===${NC}"
  echo "  Server 1: $label1"
  echo "  Server 2: $label2"
  echo "  Samples:  $SAMPLES  |  Timeout: ${TIMEOUT}s"
  echo

  _diff_run "$SERVER1" "$SERVER2" "$label1" "$label2"
}
