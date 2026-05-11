defmodule Voyager.Repo do
  use Ecto.Repo,
    otp_app: :voyager,
    adapter: Ecto.Adapters.SQLite3
end
