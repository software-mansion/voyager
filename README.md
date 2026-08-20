# Voyager

## Development

- Run `mix setup` to install and setup dependencies.
- Start the Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`.

Now you can visit [localhost:4000](http://localhost:4000) from your browser.

For running desktop application in development use:

```sh
mix tauri.dev
```

To check production app locally use

```sh
mix assets.deploy
mix tauri.app
```

## Telemetry

Voyager can export telemetry events to a remote ingest server. Export mode needs both:

| Variable | Purpose |
| --- | --- |
| `TELEMETRY_PUSH_URL` | Ingest endpoint, e.g. `https://host/telemetry` |
| `TELEMETRY_API_KEY` | API Key sent as the `X-API-Key` request header |

In `:dev`, if either variable is missing, Voyager falls back to the logger handler instead of export.

### Desktop app

- **`mix tauri.dev`** — `tauri.sh` sources `rel/app/.env` and the Rust side forwards those vars to Elixir at runtime.
- **`mix tauri.app`** — the same `.env` must be present **at compile time**.
- **`mix tauri.build`** — requires those env vars to be exported in the shell when run. GitHub Actions pass `TELEMETRY_PUSH_URL` and `TELEMETRY_API_KEY` from repository secrets.

```sh
cp rel/app/.env.sample rel/app/.env
# edit rel/app/.env with TELEMETRY_PUSH_URL and TELEMETRY_API_KEY
mix tauri.dev
```

## How to build

### Mix release

Build the Phoenix release:

```sh
mix setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release voyager
```

The production release needs these environment variables when it starts:

- `DATABASE_PATH` - SQLite database path, for example `/etc/voyager/voyager.db`
- `SECRET_KEY_BASE` - Phoenix secret key base (see: [mix phx.gen.secret](https://phoenix.hexdocs.pm/Mix.Tasks.Phx.Gen.Secret.html))

### Tauri desktop app

Voyager uses [ElixirKit](https://hexdocs.pm/elixirkit/tauri.html) to bundle the Phoenix release into a Tauri desktop app.

Before creating the desktop app, first run:
```sh
mix setup
MIX_ENV=prod mix assets.deploy
```

#### Prerequisites

- `rust`
- `tauri-cli`

```sh
cargo install tauri-cli --version "=2.8.0" --locked
```

#### Linux

Install system packages:

```sh
sudo apt-get update
sudo apt-get install -y \
  libwebkit2gtk-4.1-dev \
  libappindicator3-dev \
  librsvg2-dev \
  patchelf
```

Build the app:

```sh
mix tauri.build
```

#### macOS

Install Xcode Command Line Tools, then build:

```sh
mix tauri.build
```

## Linux AppImage

See [docs/linux_appimage_guide.md](docs/linux_appimage_guide.md) for how to run and install the Voyager AppImage on Linux.
