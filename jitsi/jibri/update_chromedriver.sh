#!/bin/bash
#
# Install the chromedriver matching the locally installed google-chrome.
#
# The old chromedriver.storage.googleapis.com endpoint is frozen: it still
# answers HTTP 200 but LATEST_RELEASE has returned 114.0.5735.90 since Chrome
# moved to the Chrome for Testing infrastructure in mid-2023. Since jibri
# tracks google-chrome-stable via pkg.latest, that endpoint would silently
# install a driver dozens of majors behind the browser, and chromedriver
# refuses to drive a Chrome it does not match.
#
set -euo pipefail

CFT_BASE="https://googlechromelabs.github.io/chrome-for-testing"
DL_BASE="https://storage.googleapis.com/chrome-for-testing-public"
VERSION_FILE="/etc/jitsi/jibri/chromedriver.version"
TARGET="/usr/local/bin/chromedriver"

# Pin the driver to the installed browser's major version rather than to
# whatever is newest, so an out-of-step Chrome upgrade cannot break jibri.
chrome_version="$(google-chrome --version | grep -oE '[0-9]+(\.[0-9]+)+')"
chrome_major="${chrome_version%%.*}"

driver_version="$(curl -fsS --retry 3 --max-time 30 \
    "${CFT_BASE}/LATEST_RELEASE_${chrome_major}")"

if [ -z "$driver_version" ]; then
    echo "No chromedriver published for Chrome ${chrome_major}" >&2
    exit 1
fi

if [ -f "$VERSION_FILE" ] && [ -x "$TARGET" ] \
   && grep -qFx "$driver_version" "$VERSION_FILE"; then
    echo "chromedriver ${driver_version} already installed"
    exit 0
fi

workdir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand workdir now, not at trap time
trap "rm -rf '$workdir'" EXIT

curl -fsS --retry 3 --max-time 300 -o "${workdir}/chromedriver.zip" \
    "${DL_BASE}/${driver_version}/linux64/chromedriver-linux64.zip"
unzip -q "${workdir}/chromedriver.zip" -d "$workdir"

# Chrome for Testing archives nest the binary in chromedriver-linux64/,
# unlike the old flat chromedriver_linux64.zip.
install -o root -g root -m 0755 \
    "${workdir}/chromedriver-linux64/chromedriver" "$TARGET"

# Record the version only after the binary is actually in place. The previous
# script wrote it first, so a failed download made every later run report
# "already installed" and the breakage went unnoticed.
echo "$driver_version" > "$VERSION_FILE"
echo "Installed chromedriver ${driver_version} for Chrome ${chrome_version}"
