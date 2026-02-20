#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB_DEFAULT="$HOME/Library/Android/sdk/platform-tools/adb"
ADB="${ADB:-$ADB_DEFAULT}"
DEVICE="${DEVICE:-emulator-5554}"
PKG="${PKG:-com.follow.clash.dev}"
SKIP_CA_INSTALL="${SKIP_CA_INSTALL:-1}"
REGEN_CA="${REGEN_CA:-0}"
CA_STORE_DIR="${CA_STORE_DIR:-$ROOT_DIR/.local/mitm_autotest_ca}"
CA_CERT_PEM="${CA_CERT_PEM:-$CA_STORE_DIR/ca_cert.pem}"
CA_KEY_PEM="${CA_KEY_PEM:-$CA_STORE_DIR/ca_key.pem}"
CA_CERT_DER="${CA_CERT_DER:-$CA_STORE_DIR/ca_cert.cer}"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
ANDROID_NDK="${ANDROID_NDK:-$ANDROID_SDK_ROOT/ndk/29.0.14206865}"

WORK_DIR="${WORK_DIR:-/tmp/flclash-mitm-autotest}"
mkdir -p "$WORK_DIR"
mkdir -p "$CA_STORE_DIR"

TEST_DOMAIN="${TEST_DOMAIN:-mitm.test}"

log() { printf "[mitm-autotest] %s\n" "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }
}

need openssl
need sqlite3
need python3

if [[ ! -x "$ADB" ]]; then
  if command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
  else
    echo "adb not found (expected $ADB_DEFAULT). set ADB=/path/to/adb" >&2
    exit 1
  fi
fi

log "Using adb: $ADB"
log "Using device: $DEVICE"

log "Waiting for device..."
"$ADB" -s "$DEVICE" wait-for-device

adb() { "$ADB" -s "$DEVICE" "$@"; }
adb_shell() { adb shell "$@"; }

CA_DOWNLOAD_PATH="/sdcard/Download/flclash_mitm_autotest_ca.cer"

log "Using persistent test CA:"
log "  cert: $CA_CERT_PEM"
log "  key:  $CA_KEY_PEM"

if [[ "$REGEN_CA" == "1" || ! -f "$CA_CERT_PEM" || ! -f "$CA_KEY_PEM" ]]; then
  log "Generating persistent test root CA (REGEN_CA=$REGEN_CA)..."
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=FlClash MITM Manual CA" \
    -keyout "$CA_KEY_PEM" -out "$CA_CERT_PEM" >/dev/null 2>&1
fi

openssl x509 -in "$CA_CERT_PEM" -outform DER -out "$CA_CERT_DER"
log "CA subject: $(openssl x509 -in "$CA_CERT_PEM" -noout -subject | sed 's/^subject=//')"
log "CA sha256:  $(openssl x509 -in "$CA_CERT_PEM" -noout -fingerprint -sha256 | sed -E 's/^[Ss][Hh][Aa]256 Fingerprint=//')"
log "CA notAfter: $(openssl x509 -in "$CA_CERT_PEM" -noout -enddate | sed 's/^notAfter=//')"

python3 - "$CA_CERT_PEM" <<'PY' || true
import subprocess
import sys
from datetime import datetime, timezone, timedelta

cert = sys.argv[1]
end = subprocess.check_output(["openssl", "x509", "-in", cert, "-noout", "-enddate"], text=True).strip()
if end.startswith("notAfter="):
    end = end[len("notAfter="):]
try:
    # Example: "Feb 21 09:42:34 2026 GMT"
    not_after = datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    if not_after - now < timedelta(days=30):
        print(f"[mitm-autotest] WARNING: CA expires soon ({not_after.isoformat()}). Consider running: REGEN_CA=1 bash scripts/mitm_autotest_android.sh and re-installing the CA once.", file=sys.stderr)
except Exception:
    pass
PY

if [[ "$SKIP_CA_INSTALL" != "1" ]]; then
  cat >&2 <<EOF

Manual step required (SKIP_CA_INSTALL=0): please install the CA on the emulator.

First, push the CA to Downloads:
  adb -s $DEVICE push "$CA_CERT_DER" "$CA_DOWNLOAD_PATH"

On the emulator:
  Settings -> Security & privacy -> More security settings ->
  Encryption & credentials -> Install a certificate -> CA certificate
  Then pick: Downloads/flclash_mitm_autotest_ca.cer

After installing, re-run:
  SKIP_CA_INSTALL=1 bash scripts/mitm_autotest_android.sh

EOF
  exit 2
fi

log "SKIP_CA_INSTALL=1: assuming CA is already installed on emulator."

log "Building libclash.so (arm64) ..."
cd "$ROOT_DIR"
export ANDROID_SDK_ROOT ANDROID_HOME ANDROID_NDK
dart ./setup.dart android --out core --arch arm64

log "Building FlClash debug APK..."
ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" ANDROID_HOME="$ANDROID_HOME" ANDROID_NDK="$ANDROID_NDK" \
  flutter build apk --debug >/dev/null

APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-debug.apk"
log "Installing FlClash: $APK"
adb install -r "$APK" >/dev/null

log "Pre-granting runtime permissions (best-effort)..."
adb_shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

log "Force-stopping FlClash to ensure START intent can boot the service..."
adb_shell "am force-stop $PKG" >/dev/null 2>&1 || true
sleep 1
adb logcat -c >/dev/null 2>&1 || true

log "Preparing MITM scripts/config..."
SCRIPTS_JSON="$WORK_DIR/scripts.json"
TEST_DOMAIN="$TEST_DOMAIN" python3 - <<'PY' >"$SCRIPTS_JSON"
import json
import os

test_domain = os.environ["TEST_DOMAIN"]

script_a = r"""
function handle(ctx) {
  var p = (ctx.request && ctx.request.path) ? String(ctx.request.path) : "";
  if (p === "/hits" || p === "/big") return {};
  if (ctx.phase === "request") {
    return { request: { setHeaders: { "X-FlClash-MITM": "1", "X-Req-Order": "A" } } };
  }
  if (ctx.phase === "response") {
    var obj = {};
    try { obj = JSON.parse(ctx.response.bodyText || "{}"); } catch (e) {}
    obj.order = "A";
    return { response: { setHeaders: { "X-Resp-Order": "A" }, bodyText: JSON.stringify(obj) } };
  }
  return {};
}
"""

script_b = r"""
function handle(ctx) {
  function getHeader(headers, name) {
    if (!headers) return null;
    var target = String(name || "").toLowerCase();
    for (var k in headers) {
      if (String(k).toLowerCase() === target) return String(headers[k]);
    }
    return null;
  }

  var p = (ctx.request && ctx.request.path) ? String(ctx.request.path) : "";
  if (p === "/hits") return {};
  if (ctx.phase === "request") {
    if (p === "/reply") {
      return {
        reply: {
          status: 200,
          setHeaders: { "Content-Type": "application/json", "X-Reply": "1" },
          bodyText: JSON.stringify({ reply: true, via: "script" })
        }
      };
    }
    if (p === "/kv") {
      var v = getHeader(ctx.request && ctx.request.headers, "X-KV-Set");
      if (v && String(v).trim() !== "") {
        var n = 0;
        try { n = Number(String(v).trim()); } catch (e) { n = 0; }
        if (!isFinite(n)) n = 0;
        return { kv: { set: { "count": n } } };
      }
      return {};
    }
    if (p === "/big") return {};
    return { request: { setHeaders: { "X-Req-Order": "B" } } };
  }
  if (ctx.phase === "response") {
    if (p === "/kv") {
      var cnt = (ctx.kv && ctx.kv.count !== undefined) ? String(ctx.kv.count) : "";
      return { response: { setHeaders: { "X-KV-Count": cnt } } };
    }
    var obj = {};
    try { obj = JSON.parse(ctx.response.bodyText || "{}"); } catch (e) {}
    obj.mitm_marker = "ok";
    obj.order = "B";
    return {
      response: {
        setHeaders: { "X-MITM": "ok", "X-Resp-Order": "B" },
        bodyText: JSON.stringify(obj)
      }
    };
  }
  return {};
}
"""

scripts = [
  {
    "id": "autotest_a",
    "name": "autotest_a",
    "enable": True,
    "domainsText": test_domain,
    "timeoutMs": 800,
    "content": script_a.strip() + "\n",
  },
  {
    "id": "autotest_b",
    "name": "autotest_b",
    "enable": True,
    "domainsText": test_domain,
    "timeoutMs": 800,
    "content": script_b.strip() + "\n",
  },
]

print(json.dumps(scripts, ensure_ascii=False, indent=2))
PY

MITM_SETTINGS_JSON="$WORK_DIR/mitm_settings.json"
cat >"$MITM_SETTINGS_JSON" <<'JSON'
{"enable":true,"captureMaxBytes":4096,"storeSize":200,"skipVerify":true}
JSON

PROFILE_ID="${PROFILE_ID:-1}"
PROFILE_YAML="$WORK_DIR/${PROFILE_ID}.yaml"
cat >"$PROFILE_YAML" <<YAML
mixed-port: 7890
allow-lan: true
mode: direct
log-level: debug
ipv6: false
hosts:
  $TEST_DOMAIN: 127.0.0.1
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
YAML

DB_PATH="$WORK_DIR/database.sqlite"
log "Creating minimal database with one file profile (id=$PROFILE_ID)..."
rm -f "$DB_PATH"
sqlite3 "$DB_PATH" <<SQL
PRAGMA foreign_keys=ON;
PRAGMA user_version=1;

CREATE TABLE IF NOT EXISTS profiles (
  id INTEGER NOT NULL PRIMARY KEY,
  label TEXT NOT NULL,
  current_group_name TEXT,
  url TEXT NOT NULL,
  last_update_date INTEGER,
  overwrite_type TEXT NOT NULL,
  script_id INTEGER,
  auto_update_duration_millis INTEGER NOT NULL,
  subscription_info TEXT,
  auto_update INTEGER NOT NULL CHECK (auto_update IN (0, 1)),
  selected_map TEXT NOT NULL,
  unfold_set TEXT NOT NULL,
  "order" INTEGER
);

CREATE TABLE IF NOT EXISTS scripts (
  id INTEGER NOT NULL PRIMARY KEY,
  label TEXT NOT NULL,
  last_update_time INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS rules (
  id INTEGER NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS profile_rule_mapping (
  id TEXT NOT NULL PRIMARY KEY,
  profile_id INTEGER REFERENCES profiles(id) ON DELETE CASCADE,
  rule_id INTEGER NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
  scene TEXT,
  "order" TEXT
);

CREATE INDEX IF NOT EXISTS idx_profile_scene_order
  ON profile_rule_mapping (profile_id, scene, "order");

INSERT OR REPLACE INTO profiles (
  id, label, current_group_name, url, last_update_date, overwrite_type,
  script_id, auto_update_duration_millis, subscription_info, auto_update,
  selected_map, unfold_set, "order"
) VALUES (
  $PROFILE_ID, 'autotest', NULL, '', NULL, 'standard',
  NULL, 86400000, NULL, 0, '{}', '[]', 0
);
SQL

CONFIG_JSON="$WORK_DIR/config.json"
cat >"$CONFIG_JSON" <<JSON
{
  "currentProfileId": $PROFILE_ID,
  "appSettingProps": {
    "disclaimerAccepted": true,
    "crashlytics": false,
    "crashlyticsTip": true,
    "autoCheckUpdate": false
  },
  "vpnProps": { "enable": false, "systemProxy": false },
  "themeProps": {}
}
JSON

SHARED_STATE_JSON="$WORK_DIR/shared_state.json"
cat >"$SHARED_STATE_JSON" <<'JSON'
{
  "setupParams": {
    "selected-map": {},
    "test-url": "https://www.gstatic.com/generate_204"
  },
  "vpnOptions": {
    "enable": false,
    "port": 7890,
    "ipv6": false,
    "dnsHijacking": false,
    "accessControlProps": {
      "enable": false,
      "mode": "rejectSelected",
      "acceptList": [],
      "rejectList": []
    },
    "allowBypass": true,
    "systemProxy": false,
    "bypassDomain": [],
    "stack": "mixed",
    "routeAddress": []
  },
  "stopTip": "Stopping VPN...",
  "startTip": "Starting VPN...",
  "currentProfileName": "FlClash",
  "stopText": "Stop",
  "onlyStatisticsProxy": false,
  "crashlytics": false
}
JSON

log "Pushing CA/script files into FlClash app storage..."
adb push "$CA_CERT_PEM" /data/local/tmp/ca_cert.pem >/dev/null
adb push "$CA_KEY_PEM" /data/local/tmp/ca_key.pem >/dev/null
adb push "$SCRIPTS_JSON" /data/local/tmp/scripts.json >/dev/null
adb push "$DB_PATH" /data/local/tmp/database.sqlite >/dev/null
adb push "$PROFILE_YAML" "/data/local/tmp/${PROFILE_ID}.yaml" >/dev/null

adb_shell "run-as $PKG sh -c '
  mkdir -p files/mitm files/profiles app_flutter/profiles
  cp /data/local/tmp/ca_cert.pem files/mitm/ca_cert.pem
  cp /data/local/tmp/ca_key.pem files/mitm/ca_key.pem
  cp /data/local/tmp/scripts.json files/mitm/scripts.json
  cp /data/local/tmp/database.sqlite files/database.sqlite
  cp /data/local/tmp/${PROFILE_ID}.yaml files/profiles/${PROFILE_ID}.yaml
  # Some Flutter builds use app_flutter as the app support dir.
  cp /data/local/tmp/database.sqlite app_flutter/database.sqlite 2>/dev/null || true
  cp /data/local/tmp/${PROFILE_ID}.yaml app_flutter/profiles/${PROFILE_ID}.yaml 2>/dev/null || true
'" >/dev/null

log "Updating SharedPreferences mitm_settings..."
PREFS_LOCAL="$WORK_DIR/FlutterSharedPreferences.xml"
if adb exec-out run-as "$PKG" cat shared_prefs/FlutterSharedPreferences.xml >"$PREFS_LOCAL" 2>/dev/null; then
  :
else
  cat >"$PREFS_LOCAL" <<'XML'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
</map>
XML
fi

python3 - "$PREFS_LOCAL" "$MITM_SETTINGS_JSON" "$CONFIG_JSON" "$SHARED_STATE_JSON" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

prefs_path, mitm_path, config_path, shared_state_path = sys.argv[1:]
prefs_file = Path(prefs_path)

values = {
    "flutter.mitm_settings": Path(mitm_path).read_text(encoding="utf-8").strip(),
    "flutter.config": Path(config_path).read_text(encoding="utf-8").strip(),
    "flutter.sharedState": Path(shared_state_path).read_text(encoding="utf-8").strip(),
}

try:
    tree = ET.parse(prefs_file)
    root = tree.getroot()
    if root.tag != "map":
        raise ValueError("root is not <map>")
except Exception:
    root = ET.Element("map")
    tree = ET.ElementTree(root)

for key, value in values.items():
    elem = None
    for child in root.findall("string"):
        if child.get("name") == key:
            elem = child
            break
    if elem is None:
        elem = ET.SubElement(root, "string", {"name": key})
    elem.text = value

tree.write(prefs_file, encoding="utf-8", xml_declaration=True)
PY

adb push "$PREFS_LOCAL" /data/local/tmp/FlutterSharedPreferences.xml >/dev/null
adb_shell "run-as $PKG sh -c 'mkdir -p shared_prefs && cp /data/local/tmp/FlutterSharedPreferences.xml shared_prefs/FlutterSharedPreferences.xml'" >/dev/null

is_listen_port() {
  local port="$1"
  local hex
  hex="$(printf '%04X' "$port")"
  adb_shell "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -i \":$hex\" | grep -i \" 0A \" >/dev/null 2>&1"
}

start_flclash_and_wait_ready() {
  local applied=0
  local saw_failed=0

  log "Launching FlClash UI..."
  adb_shell "am start -n ${PKG}/com.follow.clash.MainActivity" >/dev/null 2>&1 || true
  sleep 1

  log "Starting FlClash (via START quick action) and waiting for setMitmConfig..."
  for _ in $(seq 1 120); do
    adb_shell "am start -a ${PKG}.action.START -n ${PKG}/com.follow.clash.TempActivity" >/dev/null 2>&1 || true
    logs="$(adb logcat -d -s flutter:I || true)"
    if printf '%s' "$logs" | grep -Fq "[APP] setMitmConfig ok"; then
      applied=1
      break
    fi
    if printf '%s' "$logs" | grep -Fq "[APP] setMitmConfig failed"; then
      saw_failed=1
    fi
    sleep 2
  done

  if [[ "$applied" == "1" ]]; then
    log "MITM config applied (ok)."
  elif [[ "$saw_failed" == "1" ]]; then
    echo "Flutter reported setMitmConfig failed repeatedly." >&2
    adb logcat -d | tail -n 200 >&2 || true
    exit 1
  else
    echo "Flutter did not apply setMitmConfig successfully in time." >&2
    adb logcat -d | tail -n 200 >&2 || true
    exit 1
  fi

  log "Waiting for local proxy port 7890 to be LISTENING..."
  for _ in $(seq 1 180); do
    if is_listen_port 7890; then
      log "Proxy is ready."
      break
    fi
    sleep 1
  done
  if ! is_listen_port 7890; then
    echo "FlClash proxy did not start listening on port 7890 in time." >&2
    adb_shell "cat /proc/net/tcp | head -n 50" >&2 || true
    adb logcat -d | tail -n 200 >&2 || true
    exit 1
  fi
  sleep 2
}

log "Building and running MITM test client instrumentation..."
cd "$ROOT_DIR/android"
TEST_CLASS="com.follow.mitmtest.MitmE2ETest"
TEST_RETRY="${TEST_RETRY:-3}"
TEST_METHODS=(
  test01_http11_mitm_modifies_request_and_response
  test02_reply_short_circuit_returns_scripted_response
  test03_large_body_is_forwarded_without_script_response_mods
  test04_kv_store_is_exposed_to_scripts_and_persisted
)

for method in "${TEST_METHODS[@]}"; do
  ok=0
  for attempt in $(seq 1 "$TEST_RETRY"); do
    adb_shell "am force-stop $PKG" >/dev/null 2>&1 || true
    sleep 1
    adb logcat -c >/dev/null 2>&1 || true
    start_flclash_and_wait_ready

    log "Running ${TEST_CLASS}#${method} (attempt ${attempt}/${TEST_RETRY})..."
    args=(
      :mitm_test_client:connectedDebugAndroidTest
      --no-daemon
      "-Pandroid.testInstrumentationRunnerArguments.class=${TEST_CLASS}#${method}"
    )
    if [[ "$TEST_DOMAIN" != "mitm.test" ]]; then
      args+=("-Pandroid.testInstrumentationRunnerArguments.mitmHost=${TEST_DOMAIN}")
    fi
    if ./gradlew "${args[@]}"; then
      ok=1
      break
    fi
    if [[ "$attempt" -lt "$TEST_RETRY" ]]; then
      log "Retrying ${method}..."
      sleep 2
    fi
  done
  if [[ "$ok" != "1" ]]; then
    echo "Instrumentation test failed: ${TEST_CLASS}#${method}" >&2
    exit 1
  fi
done

log "Validating KV persistence..."
KV_LOCAL="$WORK_DIR/kv.json"
if adb exec-out run-as "$PKG" cat files/mitm/kv.json >"$KV_LOCAL" 2>/dev/null; then
  :
elif adb exec-out run-as "$PKG" cat app_flutter/mitm/kv.json >"$KV_LOCAL" 2>/dev/null; then
  :
else
  echo "kv.json not found in app storage (expected files/mitm/kv.json or app_flutter/mitm/kv.json)" >&2
  adb_shell "run-as $PKG ls -la files/mitm app_flutter/mitm 2>/dev/null || true" >&2 || true
  exit 1
fi

python3 - "$KV_LOCAL" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
count = data.get("count")
if str(count) != "2":
    raise SystemExit(f"kv count mismatch: expected 2, got {count!r}, kv={data!r}")
print("[mitm-autotest] KV ok:", data)
PY

log "DONE (PASS)"
