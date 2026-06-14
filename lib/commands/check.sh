# shellcheck shell=bash
# check.sh - Check NTP server health and availability
# Sourced by ntp-tools dispatcher; do not execute directly.

show_help() {
  cat <<EOF
Usage: ntp-tools check [options] [SERVER...]

Check NTP server health and availability.

Arguments:
  SERVER...            NTP server(s) to check (default: pool.ntp.org)

Options:
  -f, --file FILE      Read server list from file
  -n, --nts            Check NTS support (requires openssl)
  -r, --roughtime      Check Roughtime support (default port: 2002)
      --roughtime-port PORT  Roughtime UDP port (default: 2002)
      --roughtime-key  KEY   Public key (base64); default: DNS TXT lookup
  -h, --help           Show this help

Examples:
  ntp-tools check
  ntp-tools check time.google.com
  ntp-tools check --nts time.cloudflare.com
  ntp-tools check --roughtime roughtime.cloudflare.com
  ntp-tools check --roughtime --roughtime-port 2003 roughtime.cloudflare.com
  ntp-tools check --file servers.txt
EOF
}

_check_ntp_data() {
  local server="$1"
  local result
  result=$(_ntp_query "$server") || { echo "FAIL"; return 1; }
  echo "OK|$result"
}

_check_nts() {
  local server="$1" port="${2:-4460}"

  if (echo >/dev/tcp/"$server"/"$port") 2>/dev/null; then
    echo "NTS:KE_PORT_OK"
  else
    echo "NTS:KE_PORT_FAIL"
    return 1
  fi

  if command_exists openssl; then
    local tls
    local tls
    tls=$(timeout 10 openssl s_client \
      -connect "$server:$port" \
      -servername "$server" \
      -verify_hostname "$server" \
      < /dev/null 2>&1)

    if echo "$tls" | grep -q "Verify return code: 0 (ok)"; then
      echo "NTS:TLS_OK"
      local expiry_str expiry_epoch days_left
      expiry_str=$(echo "$tls" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if [[ -n "$expiry_str" ]]; then
        expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null)
        if [[ -n "$expiry_epoch" ]]; then
          days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
          if   [[ "$days_left" -lt 0 ]];  then echo "NTS:CERT_EXPIRED"
          elif [[ "$days_left" -lt 10 ]]; then echo "NTS:CERT_WARN_${days_left}d"
          else                                 echo "NTS:CERT_OK_${days_left}d"
          fi
        fi
      fi
    elif echo "$tls" | grep -q "certificate"; then
      echo "NTS:TLS_CERT_MISMATCH"
    else
      echo "NTS:TLS_HANDSHAKE_FAIL"
    fi
  else
    echo "NTS:NO_OPENSSL_TOOL"
  fi

  local daemon ver major
  daemon=$(detect_ntp_daemon)
  case "$daemon" in
    chrony)
      ver=$(chronyc -v 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1)
      major=$(echo "$ver" | cut -d. -f1)
      if [[ -n "$major" ]] && [[ "$major" -ge 4 ]] 2>/dev/null; then
        echo "NTS:LOCAL_DAEMON_CAPABLE"
      else
        echo "NTS:LOCAL_DAEMON_TOO_OLD"
      fi
      ;;
    ntpd)
      ver=$(ntpd --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
      major=$(echo "$ver" | cut -d. -f1)
      minor=$(echo "$ver" | cut -d. -f2)
      patch=$(echo "$ver" | cut -d. -f3)
      if [[ -n "$major" ]] && { [[ "$major" -gt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -gt 2 ]]; } || { [[ "$major" -eq 4 ]] && [[ "$minor" -eq 2 ]] && [[ "${patch:-0}" -ge 8 ]]; }; } 2>/dev/null; then
        echo "NTS:LOCAL_DAEMON_CAPABLE"
      else
        echo "NTS:LOCAL_DAEMON_TOO_OLD"
      fi
      ;;
    timesyncd)
      ver=$(systemd-timesyncd --version 2>/dev/null | grep -o '[0-9]\+' | head -1)
      if [[ -n "$ver" ]] && [[ "$ver" -ge 239 ]] 2>/dev/null; then
        echo "NTS:LOCAL_DAEMON_CAPABLE"
      else
        echo "NTS:LOCAL_DAEMON_TOO_OLD"
      fi
      ;;
    openntpd)
      echo "NTS:LOCAL_DAEMON_NOT_SUPPORTED"
      ;;
    none)
      echo "NTS:NO_LOCAL_DAEMON"
      ;;
  esac
}

_check_server() {
  local server="$1"
  local ok="${GREEN}✓${NC}" fail="${RED}✗${NC}"
  local explicit_rt_key="${ROUGHTIME_KEY:-}"

  echo -e "${BLUE}Checking: $server${NC}"

  local dns ip
  ip=$(resolve_host "$server")
  if [[ -n "$ip" ]]; then
    dns="OK"
  else
    dns="FAIL"
  fi

  local port
  (echo >/dev/udp/"$server"/123) 2>/dev/null && port="OK" || port="FAIL"

  local ntp_raw ntp_status ntp_offset ntp_rtt ntp_stratum
  local ntp_version ntp_poll ntp_precision ntp_root_delay ntp_root_disp ntp_ref_id ntp_ref_time ntp_leap
  ntp_raw=$(_check_ntp_data "$server")
  ntp_status=$(   echo "$ntp_raw" | cut -d'|' -f1)
  ntp_offset=$(   echo "$ntp_raw" | cut -d'|' -f3)
  ntp_rtt=$(      echo "$ntp_raw" | cut -d'|' -f4)
  ntp_stratum=$(  echo "$ntp_raw" | cut -d'|' -f5)
  ntp_version=$(  echo "$ntp_raw" | cut -d'|' -f6)
  ntp_poll=$(     echo "$ntp_raw" | cut -d'|' -f7)
  ntp_precision=$(echo "$ntp_raw" | cut -d'|' -f8)
  ntp_root_delay=$(echo "$ntp_raw" | cut -d'|' -f9)
  ntp_root_disp=$( echo "$ntp_raw" | cut -d'|' -f10)
  ntp_ref_id=$(   echo "$ntp_raw" | cut -d'|' -f11)
  ntp_ref_time=$( echo "$ntp_raw" | cut -d'|' -f12)
  ntp_leap=$(     echo "$ntp_raw" | cut -d'|' -f13)

  echo "  DNS:      $([ "$dns" = "OK" ] && echo -e "$ok ${ip:-}" || echo -e "$fail")"
  echo "  Port 123: $([ "$port" = "OK" ] && echo -e "$ok" || echo -e "$fail")"

  if [[ "$ntp_status" == "OK" ]]; then
    echo -e "  NTP:      $ok  offset: ${ntp_offset}s  RTT: ${ntp_rtt}s  stratum: $ntp_stratum"
    echo    "    Version:          $ntp_version"
    echo    "    Poll interval:    ${ntp_poll}s"
    echo    "    Precision:        ${ntp_precision}s"
    echo    "    Root delay:       ${ntp_root_delay}s"
    echo    "    Root dispersion:  ${ntp_root_disp}s"
    echo    "    Reference ID:     $ntp_ref_id"
    echo    "    Reference time:   $ntp_ref_time"
    echo    "    Leap indicator:   $ntp_leap"
  else
    echo -e "  NTP:      $fail"
  fi

  if [[ "$CHECK_ROUGHTIME" == "true" ]]; then
    local rt_result rt_midp rt_radi rt_rtt rt_sig rt_ts rt_chain rt_mint rt_maxt
    local rt_pubkey
    if [[ -n "$explicit_rt_key" ]]; then
      rt_pubkey="$explicit_rt_key"
    else
      rt_pubkey=$(_roughtime_dns_key "$server")
    fi
    if rt_result=$(_roughtime_query "$server" "$ROUGHTIME_PORT" "$rt_pubkey") && [[ -n "$rt_result" ]]; then
      rt_midp=$(  echo "$rt_result" | cut -d'|' -f1)
      rt_radi=$(  echo "$rt_result" | cut -d'|' -f2)
      rt_rtt=$(   echo "$rt_result" | cut -d'|' -f3)
      rt_sig=$(   echo "$rt_result" | cut -d'|' -f4)
      rt_ts=$(    echo "$rt_result" | cut -d'|' -f5)
      rt_chain=$( echo "$rt_result" | cut -d'|' -f6)
      rt_mint=$(  echo "$rt_result" | cut -d'|' -f7)
      rt_maxt=$(  echo "$rt_result" | cut -d'|' -f8)
      if [[ -z "$rt_pubkey" ]]; then
        echo -e "  Roughtime: ${YELLOW}⚠${NC} (unverified)"
      elif [[ "$rt_chain" == "FAIL" ]] || [[ "$rt_sig" == "FAIL" ]]; then
        echo -e "  Roughtime: $fail"
      else
        echo -e "  Roughtime: $ok"
      fi
      echo    "    Time:      $rt_ts"
      echo    "    Radius:    ±${rt_radi}s"
      echo    "    RTT:       $(format_unit "$rt_rtt")"
      if [[ -z "$rt_pubkey" ]]; then
        echo    "    Auth:      no public key - DNS TXT lookup failed"
        echo    "    Delegate:  —"
      else
        local chain_icon resp_icon
        case "$rt_chain" in
          OK)   chain_icon="${GREEN}✓${NC} chain" ;;
          FAIL) chain_icon="${RED}✗${NC} chain" ;;
          *)    chain_icon="${NC}— chain" ;;
        esac
        case "$rt_sig" in
          VERIFIED) resp_icon="${GREEN}✓${NC} response" ;;
          FAIL)     resp_icon="${RED}✗${NC} response" ;;
          *)        resp_icon="${NC}— response" ;;
        esac
        echo -e "    Auth:      Ed25519  ${chain_icon}  ·  ${resp_icon}"
        if [[ -n "$rt_mint" ]] && [[ -n "$rt_maxt" ]]; then
          echo    "    Delegate:  $rt_mint → $rt_maxt"
        else
          echo    "    Delegate:  —"
        fi
      fi
      if [[ -n "$ntp_offset" ]] && [[ "$ntp_offset" != "?" ]]; then
        local rt_ntp_diff
        rt_ntp_diff=$(awk "BEGIN{printf \"%.3f\", ($rt_midp - (systime())) - $ntp_offset}" 2>/dev/null || echo "?")
        echo    "    Δ vs NTP:  ${rt_ntp_diff}s"
      fi
    else
      local rt_err="${rt_result#FAIL:}"
      echo -e "  Roughtime: $fail ${rt_err:-port ${ROUGHTIME_PORT} not responding}"
    fi
  fi

  if [[ "$CHECK_NTS" == "true" ]]; then
    echo "  NTS:"
    while IFS= read -r line; do
      local val
      val=$(echo "$line" | cut -d: -f2)
      case "$val" in
        KE_PORT_OK|TLS_OK|LOCAL_DAEMON_CAPABLE)
          echo -e "    $ok $val" ;;
        CERT_OK_*)
          echo -e "    $ok Certificate valid for ${val#CERT_OK_}" ;;
        CERT_WARN_*)
          echo -e "    ${YELLOW}⚠${NC}  Certificate expires in ${val#CERT_WARN_}" ;;
        CERT_EXPIRED)
          echo -e "    $fail Certificate EXPIRED" ;;
        TLS_CERT_MISMATCH)
          echo -e "    $fail Certificate does not match hostname" ;;
        *)
          echo -e "    $fail $val" ;;
      esac
    done <<< "$(_check_nts "$server")"
  fi

  if [[ "$dns" == "OK" ]] && [[ "$ntp_status" == "OK" ]]; then
    echo -e "  Overall:  ${GREEN}HEALTHY${NC}"; return 0
  elif [[ "$dns" == "OK" ]] && [[ "$port" == "OK" ]]; then
    echo -e "  Overall:  ${YELLOW}DEGRADED${NC}"; return 1
  else
    echo -e "  Overall:  ${RED}UNHEALTHY${NC}"; return 2
  fi
}


main() {
  local SERVERS=() CHECK_NTS=false CHECK_ROUGHTIME=false
  ROUGHTIME_PORT=2002
  ROUGHTIME_KEY=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) show_help; return 0 ;;
      -f|--file)
        [[ ! -f "${2:-}" ]] && { error "File not found: ${2:-}"; return 1; }
        while IFS= read -r line; do
          [[ -n "$line" ]] && [[ ! "$line" =~ ^# ]] && SERVERS+=("$line")
        done < "$2"
        shift 2 ;;
      -n|--nts)        CHECK_NTS=true; shift ;;
      -r|--roughtime)  CHECK_ROUGHTIME=true; shift ;;
      --roughtime-port)
        [[ -z "${2:-}" ]] && { error "Missing argument for --roughtime-port"; return 1; }
        ROUGHTIME_PORT="$2"; shift 2 ;;
      --roughtime-key)
        [[ -z "${2:-}" ]] && { error "Missing argument for --roughtime-key"; return 1; }
        ROUGHTIME_KEY="$2"; shift 2 ;;
      -*)           error "Unknown option: $1"; return 1 ;;
      *)            SERVERS+=("$1"); shift ;;
    esac
  done

  [[ ${#SERVERS[@]} -eq 0 ]] && SERVERS=("pool.ntp.org")

  mapfile -t SERVERS < <(printf '%s\n' "${SERVERS[@]}" | sort -u)

  local total=${#SERVERS[@]} healthy=0 degraded=0 unhealthy=0

  echo -e "${BLUE}=== NTP Server Check ===${NC}"
  echo "Servers: $total"
  echo

  for server in "${SERVERS[@]}"; do
    _check_server "$server"
    case $? in
      0) healthy=$((healthy + 1)) ;;
      1) degraded=$((degraded + 1)) ;;
      *) unhealthy=$((unhealthy + 1)) ;;
    esac
    echo
  done

  if [[ "$total" -gt 1 ]]; then
    echo -e "${BLUE}=== Summary ===${NC}"
    echo "  Healthy:   $healthy / $total"
    echo "  Degraded:  $degraded / $total"
    echo "  Unhealthy: $unhealthy / $total"
    echo
    if   [[ "$healthy" -eq "$total" ]];             then echo -e "  ${GREEN}ALL OPERATIONAL${NC}";    return 0
    elif [[ "$healthy" -gt $(( total / 2 )) ]];     then echo -e "  ${YELLOW}MOSTLY OPERATIONAL${NC}"; return 1
    else                                                  echo -e "  ${RED}CRITICAL ISSUES${NC}";     return 2
    fi
  fi

  [[ "$healthy" -eq "$total" ]] && return 0 || return 2
}
