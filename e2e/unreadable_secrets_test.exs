defmodule Voyager.E2E.UnreadableSecretsTest do
  use Voyager.E2E.Case,
    async: false,
    projects: [{"unreadable-secrets", "Desktop Chrome"}]

  @db_path Path.expand("../priv/db/voyager_e2e.db", __DIR__)
  @unreadable_node "unreadable@127.0.0.1"

  # Encrypted with a different key than the one in config/e2e.exs.
  @other_key_ciphertext Base.decode64!(
                          "AQpBRVMuR0NNLlYxJwdV9kEk66LvQixtRLdrgLL0CDrm9h0RazYjUIM902WRIFvnyxztAdQFuG1w"
                        )

  defp run_sql(statement) do
    {:ok, db} = Exqlite.Sqlite3.open(@db_path)

    try do
      :ok = Exqlite.Sqlite3.execute(db, statement)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  describe "ConnectLive › secrets saved under another vault key" do
    setup %{page: page} do
      ensure_disconnected(page)

      run_sql("""
      INSERT INTO connections (node_name, cookie, last_connected_at, inserted_at, updated_at)
      VALUES ('#{@unreadable_node}', X'#{Base.encode16(@other_key_ciphertext)}',
              datetime('now'), datetime('now'), datetime('now'))
      """)

      on_exit(fn ->
        run_sql("DELETE FROM connections WHERE node_name = '#{@unreadable_node}'")
      end)

      :ok
    end

    test "warns, asks for the cookie again and clears after delete", %{page: page} do
      Page.goto!(page, "/")
      wait_for_live_view(page)

      warning = Page.locator(page, sel(:unreadable_secrets))

      row =
        Page.locator(page, "#{sel(:recent_connections)} li", has_text: @unreadable_node)

      Expect.to_be_visible!(warning)

      row
      |> Locator.locator(~s|[title="Cookie saved"]|)
      |> Expect.to_have_count!(0)

      row |> Locator.locator(~s|[data-testid="fill-recent-btn"]|) |> Locator.click!()
      Expect.to_have_value!(Page.locator(page, sel(:node_name_input)), @unreadable_node)
      Expect.to_have_value!(Page.locator(page, sel(:cookie_input)), "")

      row |> Locator.locator(~s|button[title="Remove"]|) |> Locator.click!()
      Expect.to_have_count!(row, 0)
      Expect.to_be_hidden!(warning)
    end
  end
end
