#!/usr/bin/env bash
# Local sandbox for the desktop updater.
#
#   dev/updater_sandbox.sh build            build a signed "next" release and a current app
#                                           that checks a local update server
#   dev/updater_sandbox.sh run [scenario]   serve the scenario and launch the current app
#
# Scenarios:
#   available   (default) the next version is offered and installs
#   up-to-date  the server reports an older version
#   stall       the download sends 1 MB and hangs, so the read timeout fires
#   fail        the archive is corrupt, so signature verification fails
#
# Every `run` starts from a pristine copy of the current app, so the sandbox can be
# reused after an install. Close any `cargo tauri dev` instance first: the app is
# single-instance.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sandbox="$root/tmp/updater-sandbox"
server_dir="$sandbox/server"
key_file="$sandbox/sandbox.key"
port=8765
next_version="9.9.9"
endpoint="http://127.0.0.1:$port/latest.json"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform="darwin-aarch64"; bundle="app" ;;
  Darwin-x86_64) platform="darwin-x86_64"; bundle="app" ;;
  Linux-x86_64) platform="linux-x86_64"; bundle="appimage" ;;
  Linux-aarch64) platform="linux-aarch64"; bundle="appimage" ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac

build() {
  mkdir -p "$server_dir"

  if [ ! -f "$key_file" ]; then
    (cd "$root/rel/app" && cargo tauri signer generate --ci -p "" -w "$key_file")
  fi
  pubkey="$(cat "$key_file.pub")"

  log "Building next version $next_version"
  (
    cd "$root/rel/app"
    TAURI_SIGNING_PRIVATE_KEY="$(cat "$key_file")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="" \
      ./tauri.sh build --bundles "$bundle" --config "{\"version\":\"$next_version\"}"
  )
  collect_next_artifacts

  log "Building current app against $endpoint"
  (
    cd "$root/rel/app"
    ./tauri.sh build --bundles "$bundle" --config "{\"plugins\":{\"updater\":{\"pubkey\":\"$pubkey\",\"endpoints\":[\"$endpoint\"],\"dangerousInsecureTransportProtocol\":true}}}"
  )
  rm -rf "$sandbox/pristine"
  mkdir -p "$sandbox/pristine"
  cp -R "$(built_app)" "$sandbox/pristine/"

  log "Sandbox ready: $sandbox"
}

collect_next_artifacts() {
  local bundle_dir="$root/rel/app/src-tauri/target/release/bundle"
  local archive
  case "$bundle" in
    app) archive="$bundle_dir/macos/Voyager.app.tar.gz" ;;
    appimage) archive="$(ls "$bundle_dir"/appimage/*.AppImage | head -1)" ;;
  esac

  rm -f "$server_dir"/*
  cp "$archive" "$server_dir/update"
  cp "$archive.sig" "$server_dir/update.sig"

  python3 - "$server_dir" "$platform" "$next_version" "$port" <<'EOF'
import json, sys
server_dir, platform, version, port = sys.argv[1:]
signature = open(f"{server_dir}/update.sig").read().strip()
manifest = {
    "version": version,
    "pub_date": "2026-01-01T00:00:00Z",
    "platforms": {platform: {"url": f"http://127.0.0.1:{port}/update", "signature": signature}},
}
json.dump(manifest, open(f"{server_dir}/latest.json", "w"), indent=2)
EOF
}

built_app() {
  local bundle_dir="$root/rel/app/src-tauri/target/release/bundle"
  case "$bundle" in
    app) echo "$bundle_dir/macos/Voyager.app" ;;
    appimage) ls "$bundle_dir"/appimage/*.AppImage | head -1 ;;
  esac
}

run() {
  local scenario="${1:-available}"
  [ -d "$sandbox/pristine" ] || { echo "run \`$0 build\` first" >&2; exit 1; }

  if pgrep -f "target/debug/Voyager" >/dev/null; then
    echo "a \`cargo tauri dev\` instance is running; close it first" >&2
    exit 1
  fi

  rm -rf "$sandbox/app"
  mkdir -p "$sandbox/app"
  cp -R "$sandbox/pristine/." "$sandbox/app/"

  SCENARIO="$scenario" python3 - "$server_dir" "$port" <<'EOF' &
import http.server, json, os, sys, time
server_dir, port = sys.argv[1], int(sys.argv[2])
scenario = os.environ["SCENARIO"]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.lstrip("/")
        if name == "latest.json":
            manifest = json.load(open(f"{server_dir}/latest.json"))
            if scenario == "up-to-date":
                manifest["version"] = "0.0.1"
            self.reply(json.dumps(manifest).encode())
        elif name == "update":
            data = open(f"{server_dir}/update", "rb").read()
            if scenario == "fail":
                self.reply(b"not an update" * 1000)
            elif scenario == "stall":
                self.reply(data, send=data[:1_000_000])
                print("[server] stalling the download", flush=True)
                time.sleep(3600)
            else:
                self.reply(data)
        else:
            self.send_error(404)

    def reply(self, data, send=None):
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data if send is None else send)
        self.wfile.flush()

    def log_message(self, fmt, *args):
        print("[server]", fmt % args, flush=True)

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
EOF
  server_pid=$!
  trap 'kill $server_pid 2>/dev/null' EXIT

  log "Scenario: $scenario"
  case "$bundle" in
    app) "$sandbox/app/Voyager.app/Contents/MacOS/Voyager" ;;
    appimage) "$(ls "$sandbox"/app/*.AppImage)" ;;
  esac
}

log() {
  printf '[sandbox] %s\n' "$*"
}

case "${1:-}" in
  build) build ;;
  run) shift; run "$@" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
