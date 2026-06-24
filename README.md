# Voyager

## Development

- Run `mix setup` to install and setup dependencies.
- Start the Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`.

Now you can visit [localhost:4000](http://localhost:4000) from your browser.

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

Before creating desktop app first run 

```sh
mix setup
MIX_ENV=prod mix assets.deploy
```

Install the Tauri CLI:

```sh
cargo install tauri-cli --version "=2.8.0" --locked
```

#### Linux

Install system packages:

```sh
sudo apt-get update
sudo apt-get install -y \
  pkg-config \
  libglib2.0-dev \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  libssl-dev \
  patchelf \
  xdg-utils
```

Build the app:

```sh
./rel/app/tauri.sh build
```

#### macOS

Install Xcode Command Line Tools, then build:

```sh
./rel/app/tauri.sh build
```
