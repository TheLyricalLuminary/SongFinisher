#!/usr/bin/env bash
# Fails if anything in the app can reach a network.
#
# The privacy policy does not say "we promise not to upload your audio" — it says the app
# has no networking code in it. That is a claim about the source, so it should be checked
# against the source rather than trusted to review. Run it locally before a release, and
# let CI run it on every pull request.
#
#   ./tools/check_no_network.sh
#
# Two things get checked: that no Swift file imports a networking framework or names a
# networking API, and that no package pulls a dependency from a URL. Both matter — a remote
# dependency could bring networking in without a single line of it appearing here.

set -uo pipefail
cd "$(dirname "$0")/.."

status=0

report() {
    echo "FAIL: $1"
    shift
    printf '%s\n' "$@" | sed 's/^/    /'
    status=1
}

# Frameworks whose entire purpose is a network connection. `FoundationModels` is
# deliberately absent: on-device inference, no server, and it is what the premium tier
# runs on.
frameworks='Network|NetworkExtension|CFNetwork|CloudKit|WebKit|MultipeerConnectivity|SystemConfiguration'
hits=$(grep -rnE "^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+($frameworks)\b" \
    --include='*.swift' . 2>/dev/null)
[ -n "$hits" ] && report "a networking framework is imported" "$hits"

# Foundation ships networking alongside everything else, so importing Foundation is fine
# but naming these is not. Plain `URL` is deliberately absent — file URLs are everywhere
# and are not networking.
symbols='URLSession|URLRequest|NSURLConnection|URLProtocol|URLCredential|NWConnection|NWListener|NWBrowser|WKWebView|CFStreamCreate|getaddrinfo'
hits=$(grep -rnE "\b($symbols)\b" --include='*.swift' . 2>/dev/null)
[ -n "$hits" ] && report "a networking API is referenced" "$hits"

# Every dependency is a local path. A remote one could reintroduce all of the above.
hits=$(grep -rn '\.package(url:' --include='Package.swift' . 2>/dev/null)
[ -n "$hits" ] && report "a package dependency is fetched from a URL" "$hits"

if [ "$status" -eq 0 ]; then
    echo "OK: no networking imports, no networking APIs, no remote package dependencies."
fi
exit "$status"
