#!/usr/bin/env bash
#
# brevo-keepalive.sh — keep Brevo SMTP and API keys counted as "in use".
#
# Brevo expires SMTP keys and API keys after 90 days without activity. For an
# SMTP key the only activity is sending, so one tiny message goes through the
# relay. For an API key any authenticated request counts, so a read-only
# GET /v3/account is enough. Run this on a schedule (monthly is plenty).
#
# Requires: bash 4+ and curl. Nothing else.

set -euo pipefail

readonly DEFAULT_HOST="smtp-relay.brevo.com"
readonly DEFAULT_PORT="587"
readonly DEFAULT_SUBJECT="Brevo SMTP keep-alive"
readonly DEFAULT_API_URL="https://api.brevo.com/v3/account"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dry_run=0

usage() {
  cat <<'EOF'
Usage: brevo-keepalive.sh [-n|--dry-run] [recipient@example.com]

Keeps Brevo keys from expiring after 90 days of inactivity: sends one dummy
email per SMTP key and one GET /v3/account per API key. Set BREVO_SMTP_KEY,
BREVO_API_KEY, or both.

Options:
  -n, --dry-run   Print the message and settings, send nothing.
  -h, --help      Show this help.

Configuration (environment, or a .env file next to the script):
  BREVO_SMTP_KEY     SMTP key. Comma-separated for several keys.
  BREVO_API_KEY      API key. Comma-separated for several keys.
  BREVO_API_URL      Default: https://api.brevo.com/v3/account

Required only when BREVO_SMTP_KEY is set:
  BREVO_SMTP_LOGIN   Brevo SMTP login (usually your account email).
  MAIL_FROM          Sender address, must be a verified Brevo sender.
  MAIL_TO            Recipient of the dummy message.
  BREVO_SMTP_HOST    Default: smtp-relay.brevo.com
  BREVO_SMTP_PORT    Default: 587 (587/2525 = STARTTLS, 465 = TLS)
  MAIL_SUBJECT       Default: Brevo SMTP keep-alive

Exit codes: 0 = all keys used, 1 = configuration error, 2 = a key failed.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Read KEY=value lines from a .env file. The file is parsed, never sourced, so
# it cannot execute code. Values already present in the environment win, which
# keeps CI secrets authoritative over a stray local file.
load_env_file() {
  local file="$1" key val
  [[ -r $file ]] || return 0
  while IFS='=' read -r key val || [[ -n $key ]]; do
    key="${key#"${key%%[![:space:]]*}"}"
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val%$'\r'}"
    if [[ $val == \"*\" || $val == \'*\' ]]; then
      val="${val:1:${#val}-2}"
    fi
    [[ -n ${!key:-} ]] || export "$key=$val"
  done <"$file"
}

# Split a comma-separated key list into the array named by $1, dropping blanks.
split_keys() {
  local -n out="$1"
  local parts part
  out=()
  IFS=',' read -r -a parts <<<"${2:-}"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [[ -n $part ]] && out+=("$part")
  done
  return 0
}

# Show only the tail of a secret, never the secret itself.
mask() {
  local s="$1"
  if ((${#s} <= 4)); then printf '****'; else printf '****%s' "${s: -4}"; fi
}

# Reject anything that is not a plain address. This also blocks CR/LF, so a
# hostile value cannot inject extra SMTP commands or mail headers.
require_address() {
  local name="$1" value="$2"
  [[ -n $value ]] || die "$name is not set (see --help)"
  [[ $value =~ ^[^[:space:]@\<\>,\;]+@[^[:space:]@\<\>,\;]+\.[^[:space:]@\<\>,\;]+$ ]] ||
    die "$name must be a bare email address, got: $value"
}

# curl config values are double-quoted, so backslashes and quotes need escaping.
escape_conf() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Build a fresh message for one key. Every send gets its own Message-ID and a
# numbered subject: mail systems collapse messages that share a Message-ID, so
# reusing one would make all but the first copy vanish from the inbox.
build_message() {
  local index="$1" total="$2" key_hint="$3"
  cat >"$message" <<EOF
From: $MAIL_FROM
To: $MAIL_TO
Subject: $subject ($index/$total)
Date: $(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")
Message-ID: <$(date +%s).$$.$index.$RANDOM@${MAIL_FROM##*@}>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Auto-Submitted: auto-generated
X-Auto-Response-Suppress: All

Automated keep-alive message for SMTP key $index of $total ($key_hint).

Brevo deletes SMTP keys that stay unused for 90 days. This message was sent
only to mark the key as active. No action is required.

Sent by brevo-keepalive.sh at $(LC_ALL=C date -u "+%Y-%m-%dT%H:%M:%SZ").
EOF
}

while (($# > 0)); do
  case "$1" in
  -n | --dry-run) dry_run=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*) die "unknown option: $1" ;;
  *) MAIL_TO="$1" ;;
  esac
  shift
done

load_env_file "$script_dir/.env"

smtp_host="${BREVO_SMTP_HOST:-$DEFAULT_HOST}"
smtp_port="${BREVO_SMTP_PORT:-$DEFAULT_PORT}"
subject="${MAIL_SUBJECT:-$DEFAULT_SUBJECT}"
subject="${subject//[$'\r\n']/ }"
login="${BREVO_SMTP_LOGIN:-}"
api_url="${BREVO_API_URL:-$DEFAULT_API_URL}"

command -v curl >/dev/null || die "curl is required but not installed"

split_keys keys "${BREVO_SMTP_KEY:-}"
split_keys api_keys "${BREVO_API_KEY:-}"
((${#keys[@]} + ${#api_keys[@]} > 0)) ||
  die "set BREVO_SMTP_KEY and/or BREVO_API_KEY (see --help)"

if ((${#keys[@]})); then
  [[ -n $login ]] || die "BREVO_SMTP_LOGIN is not set (see --help)"
  require_address MAIL_FROM "${MAIL_FROM:-}"
  require_address MAIL_TO "${MAIL_TO:-}"
fi

if [[ $smtp_port == "465" ]]; then
  url="smtps://$smtp_host:$smtp_port"
else
  url="smtp://$smtp_host:$smtp_port"
fi

umask 077
message="$(mktemp "${TMPDIR:-/tmp}/brevo-keepalive.XXXXXX")"
trap 'rm -f "$message"' EXIT

if ((${#keys[@]})); then
  printf 'relay:     %s\n' "$url"
  printf 'login:     %s\n' "$login"
  printf 'from:      %s\n' "$MAIL_FROM"
  printf 'to:        %s\n' "$MAIL_TO"
  printf 'smtp keys: %d\n' "${#keys[@]}"
fi
if ((${#api_keys[@]})); then
  printf 'api url:   %s\n' "$api_url"
  printf 'api keys:  %d\n' "${#api_keys[@]}"
fi

if ((dry_run)); then
  if ((${#keys[@]})); then
    build_message 1 "${#keys[@]}" "$(mask "${keys[0]}")"
    printf '\n--- message (dry run, nothing sent) ---\n'
    cat "$message"
  fi
  exit 0
fi

failed=0
index=0
for key in "${keys[@]}"; do
  index=$((index + 1))
  printf '\nsending with key %s ... ' "$(mask "$key")"
  build_message "$index" "${#keys[@]}" "$(mask "$key")"

  # The credentials are handed to curl on stdin instead of argv, so they never
  # show up in the process list of a shared machine. AUTH is pinned to PLAIN
  # because that is what ordinary SMTP clients use; left to itself curl picks
  # CRAM-MD5, which is a rarely exercised path on the relay. ssl-reqd above
  # guarantees the session is already encrypted.
  if curl --config - <<EOF
url = "$(escape_conf "$url")"
ssl-reqd
login-options = "AUTH=PLAIN"
user = "$(escape_conf "$login"):$(escape_conf "$key")"
mail-from = "$(escape_conf "$MAIL_FROM")"
mail-rcpt = "$(escape_conf "$MAIL_TO")"
upload-file = "$(escape_conf "$message")"
connect-timeout = 15
max-time = 60
silent
show-error
EOF
  then
    printf 'ok\n'
  else
    printf 'FAILED\n'
    failed=1
  fi
done

for key in "${api_keys[@]}"; do
  printf '\npinging API with key %s ... ' "$(mask "$key")"
  # Same stdin trick as above: the key goes through a curl config, not argv.
  # --fail turns a 401/403 into a non-zero exit, so a dead key is reported.
  if curl --config - <<EOF
url = "$(escape_conf "$api_url")"
header = "api-key: $(escape_conf "$key")"
header = "accept: application/json"
output = "/dev/null"
connect-timeout = 15
max-time = 30
fail
silent
show-error
EOF
  then
    printf 'ok\n'
  else
    printf 'FAILED\n'
    failed=1
  fi
done

if ((failed)); then
  printf '\nat least one key failed — check the errors above\n' >&2
  exit 2
fi

printf '\nall %d key(s) used, expiry clock reset\n' "$((${#keys[@]} + ${#api_keys[@]}))"
