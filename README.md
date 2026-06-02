# ntp-tools

A NTP toolkit for Linux. 

**Query servers**, **check health**, **monitor sync**, **compare offsets** and **audit NTS**. 

Requires `python3` and `bash`. No other dependencies.

## Prerequisites

Optional: `openssl` (for NTS check)

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
ntp-tools time 0.pool.ntp.org -f iso
```

| Option | Values | Description |
|--------|--------|-------------|
| `-f, --format` | `human` (default), `iso`, `unix` | Output format |

---

### `ntp-tools check [SERVER...]`

Check NTP server health. Default: `pool.ntp.org`. Output per server: DNS resolution, port 123/UDP, NTP response with offset, RTT and stratum, overall verdict HEALTHY / DEGRADED / UNHEALTHY.

`openssl` required for `--nts`.

```bash
ntp-tools check --detail time.google.com
```

| Option | Values | Description |
|--------|--------|-------------|
| `-f, --file` | `FILE` | Read server list from file |
| `-n, --nts` | | Check NTS support: TLS handshake, certificate validity and expiration, local daemon capability |

---

### `ntp-tools monitor`

Monitor the local NTP daemon. Auto detects `chronyd`, `ntpd`, `systemd-timesyncd` and `openntpd`.

```bash
ntp-tools monitor --watch --interval 10
```

| Option | Values | Description |
|--------|--------|-------------|
| `-w, --watch` | | Run continuously until Ctrl+C |
| `-i, --interval` | `N` | Seconds between cycles (default: 5) |
| `-n, --count` | `N` | Number of cycles to run |

---

### `ntp-tools diff SERVER1 [SERVER2]`

Compare time offset between two servers. If SERVER2 is omitted, local system clock is used as reference. Shows a qualitative rating: Excellent / Good / Acceptable / Poor / Very poor. With multiple samples: average, min, max, standard deviation.

```bash
ntp-tools diff pool.ntp.org time.google.com -n 5
```

| Option | Values | Description |
|--------|--------|-------------|
| `-n, --samples` | `N` | Number of samples (default: 3) |

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
