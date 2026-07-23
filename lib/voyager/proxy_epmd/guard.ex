defmodule Voyager.ProxyEpmd.Guard do
  defmacro require_epmd(do: block) do
    quote do
      if Voyager.ProxyEpmd.active?() do
        unquote(block)
      else
        {:error, :proxy_epmd_not_active}
      end
    end
  end
end
