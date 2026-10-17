#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
for tool in python3 openssl curl ffmpeg xcodegen xcrun xcodebuild; do
    command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
[[ -d "$DEVELOPER_DIR/Platforms/AppleTVSimulator.platform" ]] || {
    echo "Set DEVELOPER_DIR to a full Xcode installation with tvOS Simulator support." >&2
    exit 1
}
fixture_dir="$PWD/build/ui-fixtures"
mkdir -p "$fixture_dir"
xcrun simctl list devices available --json > "$fixture_dir/devices.json"
simulator_id=$(python3 - "$fixture_dir/devices.json" "${SIMULATOR_UDID:-}" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    inventory = json.load(stream)
devices = [device for runtime, entries in inventory["devices"].items()
           if ".tvOS-" in runtime for device in entries if device.get("isAvailable")]
requested = sys.argv[2]
selected = next((device for device in devices if device["udid"] == requested), None) if requested else next(
    (device for device in devices if device["state"] == "Booted"), None)
if selected is None:
    sys.exit("Set SIMULATOR_UDID to an available tvOS simulator, or boot a tvOS simulator first.")
print(selected["udid"])
PY
)
xcrun simctl bootstatus "$simulator_id" -b
bash UITests/Fixtures/prepare.sh
bash scripts/generate.sh
scheme=BoostyAppleTV
broker_arguments=(--directory "$fixture_dir")
if [[ "${UI_FIXTURE_HOST:-0}" == 1 ]]; then
    scheme=BoostyParity
    broker_arguments+=(--apple-sample-media)
    xcodegen generate --spec project-fixtures.yml
    echo "Using the separate fixture app host with its bundled certificate anchor."
elif [[ "${FIXTURE_CERTIFICATE_READY:-0}" == 1 ]]; then
    echo "Using the fixture certificate already trusted by simulator $simulator_id."
else
    python3 - "$simulator_id" "$fixture_dir/cert.pem" <<'PYTHON'
import subprocess
import sys
command = ["xcrun", "simctl", "keychain", sys.argv[1], "add-root-cert", sys.argv[2]]
try:
    subprocess.run(command, check=True, timeout=30)
except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
    detail = "timed out after 30 seconds" if isinstance(error, subprocess.TimeoutExpired) else f"failed with status {error.returncode}"
    sys.exit(f"Simulator certificate import {detail}. Retry after the simulator finishes starting. "
             "If this exact certificate is already confirmed trusted in this simulator, "
             "rerun with FIXTURE_CERTIFICATE_READY=1. HTTPS verification remains enabled.")
PYTHON
fi
python3 UITests/Fixtures/broker.py "${broker_arguments[@]}" > "$fixture_dir/broker.log" 2>&1 &
broker_pid=$!
cleanup() {
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ready=false
for attempt in {1..60}; do
    if ! kill -0 "$broker_pid" 2>/dev/null; then
        cat "$fixture_dir/broker.log" >&2
        exit 1
    fi
    if curl --silent --fail --max-time 1 --cacert "$fixture_dir/cert.pem" \
        https://localhost:18765/health > "$fixture_dir/health.json"; then
        ready=true
        break
    fi
    sleep 0.25
done
[[ "$ready" == true ]] || { echo "Fixture broker did not become ready; see $fixture_dir/broker.log" >&2; exit 1; }
python3 - "$fixture_dir/health.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    assert json.load(stream) == {"status": "ok", "fixture": "boosty-appletv"}
PY
result_path="$PWD/build/ParityTests-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
echo "Running tvOS UI tests on $simulator_id; result: $result_path"
xcodebuild test -project BoostyAppleTV.xcodeproj -scheme "$scheme" \
    -destination "platform=tvOS Simulator,id=$simulator_id" \
    -derivedDataPath DerivedData -resultBundlePath "$result_path" "$@"
