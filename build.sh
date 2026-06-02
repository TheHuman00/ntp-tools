#!/usr/bin/env bash
# Bundle all scripts into a single executable

set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SRC/dist/ntp-tools"

mkdir -p "$SRC/dist"

{
  echo '#!/usr/bin/env bash'
  echo

  # Common library (strip shebang line)
  sed '1{/^#!/d}' "$SRC/lib/ntp_common.sh"
  echo

  # Commands: rename show_help() and main() to avoid conflicts
  for cmd in time check monitor diff; do
    sed \
      -e "s/\bshow_help\b/show_help_${cmd}/g" \
      -e "s/^main()/main_${cmd}()/" \
      "$SRC/lib/commands/${cmd}.sh"
    echo
  done

  # Dispatcher
  cat <<'EOF'
_show_help() {
  cat <<HELP
Usage: ntp-tools <command> [options]

Commands:
  time     Get current time from NTP servers
  check    Check NTP server health
  monitor  Monitor system NTP synchronization
  diff     Compare time between two servers

Options:
  -h, --help    Show this help
  --version     Show version

Run 'ntp-tools <command> --help' for command-specific help.
HELP
}

[[ $# -eq 0 ]] && { _show_help; exit 0; }

cmd="$1"; shift

case "$cmd" in
  time)         main_time    "$@" ;;
  check)        main_check   "$@" ;;
  monitor)      main_monitor "$@" ;;
  diff)         main_diff    "$@" ;;
  --version|-V) echo "ntp-tools v$VERSION" ;;
  --help|-h)    _show_help ;;
  *)
    echo "ntp-tools: unknown command '$cmd'" >&2
    echo "Run 'ntp-tools --help' for usage." >&2
    exit 1
    ;;
esac
EOF

} > "$OUT"

chmod +x "$OUT"
echo "Built: $OUT ($(wc -l < "$OUT") lines)"
