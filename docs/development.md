# Development

Voyager is a Phoenix app that ships as a desktop app through [Tauri](https://tauri.app/).

## Prerequisites

Required Elixir, Erlang, Node.js, and Rust versions are pinned in [`.tool-versions`](../.tool-versions). The desktop app also needs the Tauri CLI:

```sh
cargo install tauri-cli --version "=2.8.0" --locked
```

Install dependencies and set up the database:

```sh
mix setup
```

## Web app

Run the web app on its own:

```sh
mix phx.server
# or
iex -S mix phx.server
```

Then visit [localhost:4000](http://localhost:4000). SSH tunnel connections need Voyager's `proxy_epmd` module set at VM boot, so to try them in the web app start it with `dev/server.sh` instead.

## Desktop app

Run the desktop application in development:

```sh
mix tauri.dev
```

To build and open the production desktop app locally:

```sh
mix assets.deploy
mix tauri.app
```

To tell a locally built desktop app apart from a release, set `VOYAGER_DEV_BUILD=true` in
`rel/app/.env` (see [`.env.sample`](../rel/app/.env.sample)). Apps built or run through `mix tauri.*`
then show a `Dev Build` banner.

## Before opening a pull request

```sh
mix precommit
```
