defmodule Voyager.Test.Recursive do
  @moduledoc false

  def countdown(0), do: :done
  def countdown(n), do: __MODULE__.countdown(n - 1)
end
