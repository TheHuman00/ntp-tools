# diff.sh - Compare time between two NTP servers
# Sourced by ntp-tools dispatcher; do not execute directly.

show_help() {
  cat <<EOF
Usage: ntp-tools diff [options] SERVER1 [SERVER2]

Compare time offset between two servers. If SERVER2 is omitted, local system clock is used as reference.

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

_diff_run() {
  local srv1="$1" srv2="$2" label1="$3" label2="$4"
  local diffs=() valid=0 failed=0

  local s1_rtt="" s1_stratum="" s1_precision="" s1_root_delay="" s1_root_disp="" s1_ref_id=""
  local s2_rtt="" s2_stratum="" s2_precision="" s2_root_delay="" s2_root_disp="" s2_ref_id=""

  for (( i=1; i<=SAMPLES; i++ )); do
    [[ "$SAMPLES" -gt 1 ]] && echo -e "${YELLOW}Sample $i/$SAMPLES...${NC}"

    local r1 r2 t1 t2

    if [[ "$srv1" == "LOCAL" ]]; then
      t1=$(date +%s.%N)
    else
      r1=$(_ntp_query "$srv1")
      t1=$(echo "$r1" | cut -d'|' -f1)
      if [[ -n "$t1" ]] && [[ -z "$s1_rtt" ]]; then
        s1_rtt=$(       echo "$r1" | cut -d'|' -f3)
        s1_stratum=$(   echo "$r1" | cut -d'|' -f4)
        s1_precision=$( echo "$r1" | cut -d'|' -f7)
        s1_root_delay=$(echo "$r1" | cut -d'|' -f8)
        s1_root_disp=$( echo "$r1" | cut -d'|' -f9)
        s1_ref_id=$(    echo "$r1" | cut -d'|' -f10)
      fi
    fi

    if [[ "$srv2" == "LOCAL" ]]; then
      t2=$(date +%s.%N)
    else
      r2=$(_ntp_query "$srv2")
      t2=$(echo "$r2" | cut -d'|' -f1)
      if [[ -n "$t2" ]] && [[ -z "$s2_rtt" ]]; then
        s2_rtt=$(       echo "$r2" | cut -d'|' -f3)
        s2_stratum=$(   echo "$r2" | cut -d'|' -f4)
        s2_precision=$( echo "$r2" | cut -d'|' -f7)
        s2_root_delay=$(echo "$r2" | cut -d'|' -f8)
        s2_root_disp=$( echo "$r2" | cut -d'|' -f9)
        s2_ref_id=$(    echo "$r2" | cut -d'|' -f10)
      fi
    fi

    if [[ -n "$t1" ]] && [[ -n "$t2" ]]; then
      local diff
      diff=$(awk "BEGIN{printf \"%.9f\", $t2 - $t1}" 2>/dev/null)
      if [[ -n "$diff" ]]; then
        diffs+=("$diff")
        valid=$((valid + 1))
        [[ "$SAMPLES" -gt 1 ]] && echo "  Diff: $(format_unit "$diff")"
      fi
    else
      failed=$((failed + 1))
      echo "  Failed to get timestamps"
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

  local var_sum=0
  for d in "${diffs[@]}"; do
    local dev sq
    dev=$(awk "BEGIN{printf \"%.9f\", $d - $avg}")
    sq=$(awk  "BEGIN{printf \"%.9f\", $dev * $dev}")
    var_sum=$(awk "BEGIN{printf \"%.9f\", $var_sum + $sq}")
  done
  local jitter
  jitter=$(awk "BEGIN{printf \"%.9f\", sqrt($var_sum / $valid)}")

  # Server comparison table (only if both are NTP servers)
  if [[ "$srv1" != "LOCAL" ]] && [[ "$srv2" != "LOCAL" ]]; then
    echo -e "${BLUE}Server comparison:${NC}"
    printf "  %-20s %-28s %s\n" "" "$label1" "$label2"
    printf "  %-20s %-28s %s\n" "Stratum:"         "${s1_stratum:-?}"                    "${s2_stratum:-?}"
    printf "  %-20s %-28s %s\n" "RTT:"             "$(format_unit "$s1_rtt")"            "$(format_unit "$s2_rtt")"
    printf "  %-20s %-28s %s\n" "Precision:"       "$(format_unit "$s1_precision")"      "$(format_unit "$s2_precision")"
    printf "  %-20s %-28s %s\n" "Root delay:"      "$(format_unit "$s1_root_delay")"     "$(format_unit "$s2_root_delay")"
    printf "  %-20s %-28s %s\n" "Root dispersion:" "$(format_unit "$s1_root_disp")"      "$(format_unit "$s2_root_disp")"
    printf "  %-20s %-28s %s\n" "Reference ID:"    "${s1_ref_id:-?}"                     "${s2_ref_id:-?}"
    echo
  fi

  # Results
  if [[ "$valid" -eq 1 ]]; then
    echo -e "${GREEN}Offset:${NC}  $(format_unit "$avg")"
  else
    echo -e "${GREEN}Avg offset:${NC}  $(format_unit "$avg")  (mean of $valid samples)"
    echo -e "${GREEN}Jitter:${NC}      $(format_unit "$jitter")  (std deviation)"
  fi
  [[ "$failed" -gt 0 ]] && echo -e "${YELLOW}Warning: $failed/$SAMPLES samples failed${NC}"
  echo

  # Interpretation
  local abs_avg="${avg#-}"
  echo -e "${BLUE}Interpretation:${NC}"
  if   awk "BEGIN{exit !($abs_avg < 0.000001)}"; then echo -e "  ${GREEN}Excellent (< 1µs)${NC}"
  elif awk "BEGIN{exit !($abs_avg < 0.001)}";    then echo -e "  ${GREEN}Excellent (< 1ms)${NC}"
  elif awk "BEGIN{exit !($abs_avg < 0.01)}";     then echo -e "  ${GREEN}Good (< 10ms)${NC}"
  elif awk "BEGIN{exit !($abs_avg < 0.1)}";      then echo -e "  ${YELLOW}Acceptable (< 100ms)${NC}"
  elif awk "BEGIN{exit !($abs_avg < 1)}";        then echo -e "  ${YELLOW}Poor (< 1s)${NC}"
  else                                                echo -e "  ${RED}Very poor (> 1s)${NC}"
  fi

  if awk "BEGIN{exit !($avg > 0)}"; then
    echo "  $label2 is ahead of $label1"
  else
    echo "  $label1 is ahead of $label2"
  fi
}

main() {
  local SERVER1="" SERVER2="" SAMPLES=3
  local TIMEOUT=5

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
  echo "  Samples:  $SAMPLES"
  echo

  _diff_run "$SERVER1" "$SERVER2" "$label1" "$label2"
}
