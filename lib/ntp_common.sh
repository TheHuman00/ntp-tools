#!/usr/bin/env bash

VERSION="1.1.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

command_exists() { command -v "$1" >/dev/null 2>&1; }

error() { echo -e "${RED}Error: $1${NC}" >&2; }

format_unit() {
  local val="${1:-0}"
  local abs="${val#-}"
  if   awk "BEGIN{exit !($abs < 0.000001)}"; then awk "BEGIN{printf \"%.0f ns\", $val * 1000000000}"
  elif awk "BEGIN{exit !($abs < 0.001)}";    then awk "BEGIN{printf \"%.3f µs\", $val * 1000000}"
  elif awk "BEGIN{exit !($abs < 1)}";        then awk "BEGIN{printf \"%.3f ms\", $val * 1000}"
  else                                            awk "BEGIN{printf \"%.6f s\",  $val}"
  fi
}

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
    ref_date = datetime.datetime.fromtimestamp(ref_ts, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC') if ref_ts > 0 else '?'

    print(f'{t4+offset:.9f}|{offset:.9f}|{rtt:.9f}|{stratum}|{version}|{poll_s}|{prec_s:.9f}|{root_delay:.6f}|{root_dispersion:.6f}|{ref_id}|{ref_date}|{li_str}')
except:
    sys.exit(1)
PYTHON
}

_roughtime_query() {
  local server="$1"
  local port="${2:-2002}"
  local pubkey="${3:-}"
  local timeout=${TIMEOUT:-10}

  command_exists python3 || { error "python3 is required"; return 1; }

  python3 - "$server" "$port" "$pubkey" "$timeout" <<'PYTHON'
import socket, struct, os, sys, time, select, base64, subprocess, tempfile, datetime

server     = sys.argv[1]
port       = int(sys.argv[2])
pubkey_b64 = sys.argv[3]
timeout    = float(sys.argv[4])

def safe_utc(ts):
    try:
        return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except (OSError, OverflowError, ValueError):
        return ''

MAGIC = b'ROUGHTIM'

def tag(s):   return struct.unpack('<I', s.encode()[:4])[0]
def tag_b(b): return struct.unpack('<I', b)[0]

VER  = tag_b(b'VER\x00'); NONC = tag('NONC'); ZZZZ = tag('ZZZZ')
MIDP = tag('MIDP');        RADI = tag('RADI')
SIG  = tag_b(b'SIG\x00'); SREP = tag('SREP')
CERT = tag('CERT');        DELE = tag('DELE'); PUBK = tag('PUBK')

def parse_msg(data):
    if len(data) < 4: return {}
    n = struct.unpack('<I', data[:4])[0]
    if n == 0 or n > 256: return {}
    offsets = [0]
    for i in range(n - 1):
        o = 4 + i * 4
        if o + 4 > len(data): return {}
        offsets.append(struct.unpack('<I', data[o:o+4])[0])
    offsets.append(None)
    ts = 4 + (n - 1) * 4
    tags = [struct.unpack('<I', data[ts + i*4:ts + i*4 + 4])[0] for i in range(n)]
    vs = ts + n * 4
    res = {}
    for i, t in enumerate(tags):
        s = vs + offsets[i]
        e = vs + offsets[i+1] if offsets[i+1] is not None else len(data)
        res[t] = data[s:e]
    return res

def build_ietf(version, nonce32):
    # ROUGHTIM(8) + length(4) + message(1012) = 1024 bytes
    # Tags sorted: VER(0x00524556) < NONC(0x434E4F4E) < ZZZZ(0x5A5A5A5A)
    ver_val = struct.pack('<I', version)
    header  = struct.pack('<I', 3) + struct.pack('<II', 4, 36) + struct.pack('<III', VER, NONC, ZZZZ)
    core    = header + ver_val + nonce32
    msg     = core + bytes(1012 - len(core))
    return MAGIC + struct.pack('<I', len(msg)) + msg

def build_google(nonce64):
    # Original Google Roughtime: NONC only, 64B nonce, no framing, padded to 1024B
    header = struct.pack('<I', 1) + struct.pack('<I', NONC)
    msg    = header + nonce64
    return msg + bytes(1024 - len(msg))

def strip_framing(data):
    if len(data) >= 12 and data[:8] == MAGIC:
        return data[12:12 + struct.unpack('<I', data[8:12])[0]]
    return data

def verify_ed25519(pubkey_bytes, message, signature):
    der = bytes.fromhex('302a300506032b6570032100') + pubkey_bytes
    pem = "-----BEGIN PUBLIC KEY-----\n" + base64.b64encode(der).decode() + "\n-----END PUBLIC KEY-----\n"
    try:
        with tempfile.TemporaryDirectory() as d:
            open(d+'/k.pem', 'w').write(pem)
            open(d+'/s.bin', 'wb').write(signature)
            open(d+'/m.bin', 'wb').write(message)
            r = subprocess.run(['openssl','pkeyutl','-verify','-pubin','-inkey',d+'/k.pem',
                                '-sigfile',d+'/s.bin','-rawin','-in',d+'/m.bin'], capture_output=True)
            return r.returncode == 0
    except: return None

pubkey_bytes = base64.b64decode(pubkey_b64) if pubkey_b64 else None
nonce32 = os.urandom(32)
nonce64 = os.urandom(64)

# Send all formats simultaneously, take the first response
packets = [
    build_ietf(0x8000000c, nonce32),  # IETF draft-12
    build_ietf(0x8000000b, nonce32),  # IETF draft-11 (Cloudflare)
    build_google(nonce64),             # Google format (roughtime.int08h.com, etc.)
]

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
t1 = time.time()
try:
    for pkt in packets:
        s.sendto(pkt, (server, port))
    ready = select.select([s], [], [], timeout)
    if not ready[0]:
        print("FAIL:timed out"); sys.exit(1)
    data, _ = s.recvfrom(65536)
    t4 = time.time()
    s.close()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(1)

resp = parse_msg(strip_framing(data))
if SREP not in resp:
    print(f"FAIL:no SREP (got {len(data)}B)"); sys.exit(1)

srep = parse_msg(resp[SREP])
if MIDP not in srep or RADI not in srep:
    print("FAIL:no MIDP/RADI in SREP"); sys.exit(1)

midp_us   = struct.unpack('<Q', srep[MIDP])[0]
radi_us   = struct.unpack('<I', srep[RADI])[0]
# IETF MIDP = seconds since Unix epoch (~1.78e9), Google MIDP = µs since Unix epoch (~1.78e15)
# Threshold 1e12 separates these unambiguously.
midp_unix = midp_us if midp_us < 1e12 else midp_us / 1_000_000
radi_s    = radi_us / 1_000_000
rtt       = t4 - t1

chain_ok = None
verified = None
dele_mint = dele_maxt = ''
MINT = tag('MINT'); MAXT = tag('MAXT')
if pubkey_b64 and CERT in resp and SIG in resp:
    cert     = parse_msg(resp[CERT])
    dele_raw = cert.get(DELE, b'')
    cert_sig = cert.get(SIG, b'')
    if dele_raw and cert_sig:
        dele     = parse_msg(dele_raw)
        dk       = dele.get(PUBK, b'')
        chain_ok = (
            verify_ed25519(pubkey_bytes, b"RoughTime v1 delegation signature--\x00" + dele_raw, cert_sig) or
            verify_ed25519(pubkey_bytes, b"RoughTime v1 delegation signature\x00"   + dele_raw, cert_sig)
        )
        if chain_ok and dk:
            verified = verify_ed25519(dk, b"RoughTime v1 response signature\x00" + resp[SREP], resp[SIG])
        if MINT in dele and len(dele[MINT]) >= 8:
            mint_unix = struct.unpack('<Q', dele[MINT])[0]
            mint_unix = mint_unix if mint_unix < 1e12 else mint_unix / 1_000_000
            dele_mint = safe_utc(mint_unix)
        if MAXT in dele and len(dele[MAXT]) >= 8:
            maxt_unix = struct.unpack('<Q', dele[MAXT])[0]
            maxt_unix = maxt_unix if maxt_unix < 1e12 else maxt_unix / 1_000_000
            dele_maxt = safe_utc(maxt_unix)

ts = safe_utc(midp_unix).replace('T', ' ').replace('Z', ' UTC') or '?'
chain_status = 'OK' if chain_ok else 'UNVERIFIED' if chain_ok is None else 'FAIL'
sig_status   = 'VERIFIED' if verified else 'UNVERIFIED' if verified is None else 'FAIL'
print(f"{midp_unix:.3f}|{radi_s:.3f}|{rtt:.6f}|{sig_status}|{ts}|{chain_status}|{dele_mint}|{dele_maxt}")
PYTHON
}

_roughtime_dns_key() {
  local server="$1"
  command_exists dig || return 1
  dig TXT "$server" +short 2>/dev/null | tr -d '"' | grep -E '^[A-Za-z0-9+/]+=*$' | head -1
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
