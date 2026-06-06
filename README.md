# ntp-tools

A NTP toolkit for Linux.

**Query servers**, **check health**, **monitor sync**, **compare offsets**, **audit NTS** and **verify Roughtime**.

Requires `python3` and `bash`. No other dependencies.

## Prerequisites

Optional: `openssl` (for NTS and Roughtime signature verification), `dig` (for Roughtime DNS key lookup)

## Install

**User install**
```bash
curl -fsSL https://github.com/TheHuman00/ntp-tools/releases/latest/download/ntp-tools -o ~/.local/bin/ntp-tools
chmod +x ~/.local/bin/ntp-tools
```

**System wide**
```bash
sudo curl -fsSL https://github.com/TheHuman00/ntp-tools/releases/latest/download/ntp-tools -o /usr/local/bin/ntp-tools
sudo chmod +x /usr/local/bin/ntp-tools
```

## Commands

### `ntp-tools time [SERVER...]`

Get current time from one or more NTP servers. Default: `pool.ntp.org`.

```bash
ntp-tools time -f iso time.google.com
```

<details>
<summary>Example output</summary>

```
2026-06-04T01:25:27+02:00
```

</details>

| Option | Values | Description |
|--------|--------|-------------|
| `-f, --format` | `human` (default), `iso`, `unix` | Output format |

---

### `ntp-tools check [SERVER...]`

Check NTP server health. Default: `pool.ntp.org`.

Output per server: DNS resolution, port 123/UDP, NTP response with offset / RTT / stratum / precision / root delay / reference ID, overall verdict HEALTHY / DEGRADED / UNHEALTHY.

```bash
ntp-tools check time.cloudflare.com
ntp-tools check -n time.cloudflare.com           # + NTS audit
ntp-tools check -r -n roughtime.cloudflare.com       # + Roughtime + NTS
```

<details>
<summary>Example output — NTS</summary>

```
=== NTP Server Check ===
Servers: 1

Checking: time.cloudflare.com
  DNS:      ✓ 2606:4700:f1::1
  Port 123: ✓
  NTP:      ✓  offset: -0.001488090s  RTT: 0.021376848s  stratum: 3
    Version:          3
    Poll interval:    1s
    Precision:        0.000000015s
    Root delay:       0.011261s
    Root dispersion:  0.000519s
    Reference ID:     10.16.8.4
    Reference time:   2026-06-03 23:22:51 UTC
    Leap indicator:   none
  NTS:
    ✓ KE_PORT_OK
    ✓ TLS_OK
    ✓ Certificate valid for 258d
    ✓ LOCAL_DAEMON_CAPABLE
  Overall:  HEALTHY
```

</details>

<details>
<summary>Example output — Roughtime + NTS</summary>

```
=== NTP Server Check ===
Servers: 1

Checking: roughtime.cloudflare.com
  DNS:      ✓ 2606:4700:f1::1
  Port 123: ✓
  NTP:      ✓  offset: 0.002061248s  RTT: 0.016512632s  stratum: 3
    Version:          3
    Poll interval:    1s
    Precision:        0.000000015s
    Root delay:       0.011261s
    Root dispersion:  0.000519s
    Reference ID:     10.16.8.4
    Reference time:   2026-06-06 01:05:18 UTC
    Leap indicator:   none
  Roughtime: ✓
    Time:      2026-06-06 01:05:20 UTC
    Radius:    ±0.000s
    RTT:       19.820 ms
    Auth:      Ed25519  ✓ chain  ·  ✓ response
    Delegate:  2026-06-05T23:10:03Z → 2026-06-06T23:10:03Z
    Δ vs NTP:  -0.002s
  NTS:
    ✓ KE_PORT_OK
    ✓ TLS_OK
    ✓ Certificate valid for 258d
    ✓ LOCAL_DAEMON_CAPABLE
  Overall:  HEALTHY
```

</details>

| Option | Description |
|--------|-------------|
| `-f, --file FILE` | Read server list from file |
| `-n, --nts` | Audit NTS support (requires `openssl`) |
| `-r, --roughtime` | Check Roughtime support |
| `--roughtime-port PORT` | Roughtime UDP port (default: `2002`) |
| `--roughtime-key KEY` | Public key in base64 for signature verification |

#### Roughtime signature verification

The `--roughtime` flag queries the server over UDP and verifies the cryptographic signature of the response (Ed25519).

**Public key resolution** — by default, the key is fetched automatically from the server's DNS TXT record:

```bash
# Key fetched automatically from DNS TXT record
ntp-tools check --roughtime roughtime.cloudflare.com --roughtime-port 2003

# Key provided explicitly
ntp-tools check --roughtime roughtime.cloudflare.com --roughtime-port 2003 \
  --roughtime-key "0GD7c3yP8xEc4Zl2zeuN2SlLvDVVocjsPSL8/Rl/7zg="
```

**Auth output:**
- `✓ chain · ✓ response` — the delegation certificate and the time response are both cryptographically valid
- `✓ chain · — response` — the root key is trusted but the response context is unknown (server uses a non-standard implementation)
- `no public key` — no DNS TXT record found and no `--roughtime-key` provided; time is still shown but not verified

**NTS audit** (`-n`) verifies:
- Port 4460 reachable
- TLS handshake valid
- Certificate matches the server hostname
- Certificate expiration (warns if < 10 days)
- Local NTP daemon NTS capability

---

### `ntp-tools monitor`

Monitor the local NTP daemon. Auto-detects `chronyd`, `ntpd`, `systemd-timesyncd` and `openntpd`.

```bash
ntp-tools monitor --watch --interval 10
```

<details>
<summary>Example output</summary>

```
=== Cycle #1 — 2026-06-04 01:22:06 ===

=== NTP Daemon ===
  chrony (chronyd): Running

=== Synchronization Status ===
Reference ID    : 5E8EF6C0 (meron.soleus.nu)
Stratum         : 4
System time     : 0.000827766 seconds fast of NTP time
Last offset     : +0.000907674 seconds
RMS offset      : 0.001846254 seconds

=== Time Sources ===
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
^* meron.soleus.nu               3  10   377   229  +2361us[+3269us] +/-   11ms

=== System Clock ===
  Local:    2026-06-04 01:22:06 CEST
  UTC:      2026-06-03 23:22:06 UTC

Next cycle in 10s...
```

</details>

| Option | Description |
|--------|-------------|
| `-w, --watch` | Run continuously until Ctrl+C |
| `-i, --interval N` | Seconds between cycles (default: 5) |
| `-n, --count N` | Number of cycles to run |

---

### `ntp-tools diff SERVER1 [SERVER2]`

Compare time offset between two servers. If SERVER2 is omitted, the local system clock is used as reference. Shows a qualitative rating: Excellent / Good / Acceptable / Poor / Very poor. With multiple samples: average, min, max, standard deviation.

```bash
ntp-tools diff pool.ntp.org time.cloudflare.com -n 3
```

<details>
<summary>Example output</summary>

```
=== NTP Time Diff ===
  Server 1: pool.ntp.org
  Server 2: time.cloudflare.com
  Samples:  3

Sample 1/3...
  Diff: 126.496 ms
Sample 2/3...
  Diff: 54.379 ms
Sample 3/3...
  Diff: 53.936 ms

Server comparison:
                       pool.ntp.org                 time.cloudflare.com
  Stratum:             2                            3
  RTT:                 31.525 ms                    49.899 ms
  Precision:           60 ns                        15 ns
  Root delay:          3.418 ms                     11.566 ms
  Root dispersion:     5.890 ms                     702.000 µs
  Reference ID:        85.199.214.102               10.16.8.4

Avg offset:  78.270 ms  (mean of 3 samples)
Jitter:      34.101 ms  (std deviation)

Interpretation:
  Acceptable (< 100ms)
  time.cloudflare.com is ahead of pool.ntp.org
```

</details>

| Option | Description |
|--------|-------------|
| `-n, --samples N` | Number of samples (default: 3) |

---

## Development

```bash
git clone https://github.com/TheHuman00/ntp-tools
cd ntp-tools
bash build.sh
./dist/ntp-tools --version
```

## License

CC0 1.0 Universal
