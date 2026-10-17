#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture_dir="$PWD/build/ui-fixtures"
mkdir -p "$fixture_dir"
cat > "$fixture_dir/certificate.cnf" <<'CONFIG'
[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Boosty Apple TV UI Fixture
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
CONFIG
if python3 - "$fixture_dir" <<'PYTHON'
from datetime import datetime
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
cert, key = root / "cert.pem", root / "key.pem"
def openssl(*arguments):
    return subprocess.run(["openssl", *map(str, arguments)], check=True,
                          capture_output=True, text=True, timeout=5).stdout.strip()
try:
    openssl("x509", "-in", cert, "-checkend", "300", "-noout")
    openssl("verify", "-CAfile", cert, cert)
    assert openssl("x509", "-in", cert, "-subject", "-nameopt", "RFC2253", "-noout") == "subject=CN=Boosty Apple TV UI Fixture"
    san = openssl("x509", "-in", cert, "-ext", "subjectAltName", "-noout").splitlines()[-1].strip()
    assert san == "DNS:localhost, IP Address:127.0.0.1"
    dates = openssl("x509", "-in", cert, "-dates", "-noout").splitlines()
    start, end = [datetime.strptime(date.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z") for date in dates]
    assert 0 < (end - start).total_seconds() <= 86400
    assert openssl("x509", "-in", cert, "-pubkey", "-noout") == openssl("pkey", "-in", key, "-pubout")
except (subprocess.SubprocessError, AssertionError, ValueError, IndexError, OSError):
    sys.exit(1)
PYTHON
then
    echo "Reusing the valid one-day fixture certificate."
else
    if [[ "${FIXTURE_CERTIFICATE_READY:-0}" == 1 ]]; then
        echo "The existing fixture certificate/key is missing, expired, or does not match the fixture configuration. Unset FIXTURE_CERTIFICATE_READY to generate and import a new certificate." >&2
        exit 1
    fi
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$fixture_dir/key.pem" -out "$fixture_dir/cert.pem" \
        -config "$fixture_dir/certificate.cnf" > "$fixture_dir/certificate.log" 2>&1
fi
chmod 600 "$fixture_dir/key.pem"
openssl x509 -in "$fixture_dir/cert.pem" -outform DER -out "$fixture_dir/cert.der"
xcrun swift UITests/Fixtures/generate-images.swift.txt "$fixture_dir"
if [[ ! -s "$fixture_dir/test.mp4" ]]; then
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i 'testsrc2=size=640x360:rate=12' \
        -t 120 -an -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -movflags +faststart "$fixture_dir/test.mp4"
fi
