#!/usr/bin/env bash
# Create an SSH key (ed25519 / Curve25519) and install it for passwordless login.
# Works on Linux and macOS. Safe defaults, strict mode, and helpful output.
#
# Usage:
#   ./nopass.ed25519.sh -u <user> -H <host> [-k <key_path>] [-c <comment>] [--no-add]
# Examples:
#   ./nopass.ed25519.sh -u brian -H server.example.com
#   ./nopass.ed25519.sh -u ubuntu -H 203.0.113.7 -k ~/.ssh/id_ed25519_personal
#
# Notes:
# - Generates an ed25519 key (Curve25519) with strong KDF (argon via -a rounds).
# - Defaults to NO PASSPHRASE (for non-interactive use). You can set PASSPHRASE env var.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.2.0"

function die() { echo "error: $*" >&2; exit 1; }
function need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

function usage() {
  sed -n '1,35p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

USER_NAME="${USER:-$(id -un)}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_HOST="${REMOTE_HOST:-}"
KEY_PATH_DEFAULT="${HOME}/.ssh/id_ed25519"
KEY_PATH="${KEY_PATH_DEFAULT}"
COMMENT="${COMMENT:-${USER_NAME}@$(hostname -s) $(date +%F)}"
ADD_TO_AGENT=1
PASSPHRASE="${PASSPHRASE:-}"   # empty = no passphrase

# Parse args
while (( "$#" )); do
  case "$1" in
    -u|--user)        REMOTE_USER="${2:-}"; shift 2;;
    -H|--host)        REMOTE_HOST="${2:-}"; shift 2;;
    -k|--key-path)    KEY_PATH="${2:-}"; shift 2;;
    -c|--comment)     COMMENT="${2:-}"; shift 2;;
    --no-add)         ADD_TO_AGENT=0; shift;;
    -h|--help)        usage 0;;
    *) die "unknown arg: $1 (use -h)";;
  esac
done

[[ -n "${REMOTE_USER}" ]] || die "missing --user; try: -u brian"
[[ -n "${REMOTE_HOST}" ]] || die "missing --host; try: -H server.example.com"

need ssh
need ssh-keygen

echo ">>> Using key path: ${KEY_PATH}"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ -f "${KEY_PATH}" ]]; then
  echo ">>> Key already exists at ${KEY_PATH} — skipping generation."
else
  echo ">>> Generating ed25519 key (Curve25519) ..."
  # -a: KDF rounds (increase to make brute forcing harder)
  # -N: passphrase (empty by default for 'no password' use case)
  ssh-keygen -t ed25519 -a 100 -C "${COMMENT}" -f "${KEY_PATH}" -N "${PASSPHRASE}"
fi

chmod 600 "${KEY_PATH}"
chmod 644 "${KEY_PATH}.pub"

# Optionally add to ssh-agent
if [[ "${ADD_TO_AGENT}" -eq 1 ]]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    need ssh-agent; need ssh-add
    eval "$(ssh-agent -s)" >/dev/null
    # macOS keychain integration
    if ssh-add -l >/dev/null 2>&1; then
      echo ">>> Adding key to ssh-agent with macOS keychain"
      ssh-add --apple-use-keychain "${KEY_PATH}" || true
    else
      echo ">>> Adding key to ssh-agent"
      ssh-add "${KEY_PATH}" || true
    fi
  else
    # Linux and others
    need ssh-agent; need ssh-add
    if ! pgrep -u "$(id -u)" ssh-agent >/dev/null 2>&1; then
      eval "$(ssh-agent -s)"
    fi
    echo ">>> Adding key to ssh-agent"
    ssh-add "${KEY_PATH}" || true
  fi
fi

PUBKEY_CONTENT="$(cat "${KEY_PATH}.pub")"

echo ">>> Installing key on ${REMOTE_USER}@${REMOTE_HOST}"
# Prefer ssh-copy-id if available
if command -v ssh-copy-id >/dev/null 2>&1; then
  echo ">>> Using ssh-copy-id"
  ssh-copy-id -i "${KEY_PATH}.pub" "${REMOTE_USER}@${REMOTE_HOST}" || die "ssh-copy-id failed"
else
  echo ">>> ssh-copy-id not found, using manual method"
  ssh -o StrictHostKeyChecking=accept-new "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  # Append key safely
  printf '%s\n' "${PUBKEY_CONTENT}" | ssh "${REMOTE_USER}@${REMOTE_HOST}" 'cat >> ~/.ssh/authorized_keys'
fi

echo ">>> Testing login (read-only check)"
ssh -o BatchMode=yes -o PasswordAuthentication=no "${REMOTE_USER}@${REMOTE_HOST}" 'echo "SSH key auth OK on $(hostname -f)"' || die "key auth test failed"

cat <<EOF

All set!

- Private key : ${KEY_PATH}
- Public key  : ${KEY_PATH}.pub
- Installed to: ${REMOTE_USER}@${REMOTE_HOST}:~/.ssh/authorized_keys

Tips:
  • To make Git use a specific host alias, add to ~/.ssh/config:
      Host github-personal
        HostName github.com
        User git
        IdentityFile ${KEY_PATH}
        AddKeysToAgent yes
  • To change the default key name/path: rerun with -k <path>.
  • To use a passphrase: run with environment variable PASSPHRASE='your passphrase'.
  • To skip ssh-agent step: add --no-add.
EOF
