#!/usr/bin/env bash

VERSION="0.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

command_exists() { command -v "$1" >/dev/null 2>&1; }

error() { echo -e "${RED}Error: $1${NC}" >&2; }

resolve_host() {
  local host="$1"
  if command_exists getent; then
    getent hosts "$host" | awk '{print $1}' | head -1
  elif command_exists nslookup; then
    nslookup "$host" 2>/dev/null | awk '/^Address:/{print $2}' | grep -v '#' | tail -1
  elif command_exists host; then
    host "$host" 2>/dev/null | awk '/has address/{print $4}' | head -1
  else
    return 1
  fi
}

_ntp_query() {
  local server="$1"
  local timeout=${TIMEOUT:-5}

  command_exists python3 || { error "python3 is required — install it with your package manager"; return 1; }

  python3 - "$server" "$timeout" <<'PYTHON' 2>/dev/null
import socket, sys, time, struct, datetime

server  = sys.argv[1]
timeout = float(sys.argv[2])

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    t1 = time.time()
    s.sendto(b'\x1b' + b'\x00' * 47, (server, 123))
    data, _ = s.recvfrom(1024)
    t4 = time.time()
    s.close()

    if len(data) < 48:
        sys.exit(1)

    li       = (data[0] >> 6) & 0x3
    version  = (data[0] >> 3) & 0x7
    stratum  = data[1]
    poll     = data[2]
    prec     = struct.unpack('b', bytes([data[3]]))[0]

    root_delay      = struct.unpack('!I', data[4:8])[0]  / 2**16
    root_dispersion = struct.unpack('!I', data[8:12])[0] / 2**16

    if stratum <= 1:
        ref_id = data[12:16].decode('ascii', errors='replace').rstrip('\x00') or '?'
    else:
        ref_id = f"{data[12]}.{data[13]}.{data[14]}.{data[15]}"

    ref_sec  = struct.unpack('!I', data[16:20])[0]
    ref_frac = struct.unpack('!I', data[20:24])[0]
    ref_ts   = ref_sec - 2208988800 + ref_frac / 2**32 if ref_sec > 0 else 0

    t2 = struct.unpack('!I', data[32:36])[0] - 2208988800 + struct.unpack('!I', data[36:40])[0] / 2**32
    t3 = struct.unpack('!I', data[40:44])[0] - 2208988800 + struct.unpack('!I', data[44:48])[0] / 2**32

    offset = ((t2 - t1) + (t3 - t4)) / 2
    rtt    = (t4 - t1) - (t3 - t2)

    li_str   = ['none', '+1s pending', '-1s pending', 'unknown'][li]
    poll_s   = 2**poll if poll < 32 else poll
    prec_s   = 2**prec
    ref_date = datetime.datetime.utcfromtimestamp(ref_ts).strftime('%Y-%m-%d %H:%M:%S UTC') if ref_ts > 0 else '?'

    print(f'{t4+offset:.9f}|{offset:.9f}|{rtt:.9f}|{stratum}|{version}|{poll_s}|{prec_s:.9f}|{root_delay:.6f}|{root_dispersion:.6f}|{ref_id}|{ref_date}|{li_str}')
except:
    sys.exit(1)
PYTHON
}

detect_ntp_daemon() {
  if   systemctl is-active --quiet chronyd        2>/dev/null; then echo "chrony"
  elif systemctl is-active --quiet ntpd            2>/dev/null; then echo "ntpd"
  elif systemctl is-active --quiet ntp             2>/dev/null; then echo "ntpd"
  elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then echo "timesyncd"
  elif systemctl is-active --quiet openntpd        2>/dev/null; then echo "openntpd"
  else echo "none"
  fi
}

validate_ntp_server() {
  local server="$1"
  if [[ -z "$server" ]]; then
    error "NTP server not specified"
    return 1
  fi
  if ! resolve_host "$server" >/dev/null 2>&1; then
    error "Cannot resolve NTP server '$server'"
    return 1
  fi
}
