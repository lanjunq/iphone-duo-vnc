#!/bin/zsh
# Creates a throwaway macOS account for testing Screen Sharing logins on your own Mac, so that tests
# never need a real account's password. Needs sudo. Safe to re-run.
#
#   zsh scripts/setup-test-account.sh            # account name: vnctest
#   DUOVNC_TEST_USER=myname zsh scripts/setup-test-account.sh
#
# The generated password is written to .test-account.env (gitignored, mode 600) as
# DUOVNC_USER / DUOVNC_PASS, the format rfbprobe and tools/rfbctl read with --env-file.
# Remove the account later with: sudo sysadminctl -deleteUser <name>
set -e
cd "$(dirname "$0")/.."
TEST_USER=${DUOVNC_TEST_USER:-vnctest}

if ! id "$TEST_USER" >/dev/null 2>&1; then
  TEST_PASS=$(openssl rand -base64 24 | tr -d '/+=')
  sudo sysadminctl -addUser "$TEST_USER" -fullName "VNC Test" -password "$TEST_PASS"
  ( umask 077; printf 'DUOVNC_USER=%s\nDUOVNC_PASS=%s\n' "$TEST_USER" "$TEST_PASS" > .test-account.env )
  echo "Created $TEST_USER; credentials are in .test-account.env"
fi

# Screen Sharing only admits members of this group (admins are nested in it by default).
if ! dseditgroup -o checkmember -m "$TEST_USER" com.apple.access_screensharing >/dev/null 2>&1; then
  sudo dseditgroup -o edit -a "$TEST_USER" -t user com.apple.access_screensharing
fi
dseditgroup -o checkmember -m "$TEST_USER" com.apple.access_screensharing
