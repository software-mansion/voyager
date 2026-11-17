defmodule Voyager.Services.UsedRequestStatesTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.UsedRequestStates

  test "consumes an id once" do
    id = make_ref()

    assert UsedRequestStates.consume(id) == :ok
    assert UsedRequestStates.consume(id) == :used
  end

  test "forgets an id past its expiry" do
    id = make_ref()
    :ets.insert(UsedRequestStates, {id, 0})

    assert UsedRequestStates.consume(id) == :ok
  end
end
