defmodule VoyagerWeb.ListPage do
  @moduledoc false

  import Phoenix.Component

  alias Phoenix.LiveView.Socket

  @page_sizes [10, 25, 50, 100]
  @default_page_size 25

  @doc "Assigns `page`, `page_size` and the sizes on offer as `page_sizes`."
  @spec init(Socket.t()) :: Socket.t()
  def init(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:page_size, @default_page_size)
    |> assign(:page_sizes, @page_sizes)
  end

  @doc "The page size a param names; anything but an offered size is the default."
  @spec page_size(term()) :: pos_integer()
  def page_size(param) do
    case parse_integer(param) do
      size when size in @page_sizes -> size
      _other -> @default_page_size
    end
  end

  @doc "Sets the page size a param names and goes back to the first page."
  @spec set_page_size(Socket.t(), term()) :: Socket.t()
  def set_page_size(socket, param) do
    socket
    |> assign(:page_size, page_size(param))
    |> assign(:page, 1)
  end

  @doc "Moves to the page a param names, within the `total` rows; a bad param stays put."
  @spec paginate(Socket.t(), term(), non_neg_integer()) :: Socket.t()
  def paginate(socket, param, total) do
    page = parse_integer(param) || socket.assigns.page
    assign(socket, :page, clamp(page, total, socket.assigns.page_size))
  end

  @spec clamp_page(Socket.t(), non_neg_integer()) :: Socket.t()
  def clamp_page(socket, total) do
    assign(socket, :page, clamp(socket.assigns.page, total, socket.assigns.page_size))
  end

  @doc "The page's slice of `entries`, as `{dom_id, entry}` rows."
  @spec rows([map()], pos_integer(), pos_integer(), (map() -> String.t())) ::
          [{String.t(), map()}]
  def rows(entries, page, page_size, dom_id) do
    entries
    |> Enum.slice((page - 1) * page_size, page_size)
    |> Enum.map(&{dom_id.(&1), &1})
  end

  defp clamp(page, total, page_size) do
    page |> max(1) |> min(max(div(total + page_size - 1, page_size), 1))
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
