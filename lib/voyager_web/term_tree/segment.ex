defmodule VoyagerWeb.TermTree.Segment do
  @moduledoc """
  A fragment of rendered term text together with what that fragment is.

  A single line of a term is a run of differently coloured pieces — `name:` is
  an atom, the `" => "` after it is punctuation, `"voyager"` is a string — and
  each piece is one segment.

  Segments carry meaning, never styling. Turning a `:string` into a colour is
  the renderer's job, so the same tree can be drawn in a panel, a table cell or
  a test without the term logic knowing anything about CSS.
  """

  defstruct [:text, :kind]

  @type kind ::
          :atom
          | :number
          | :string
          | :special
          | :module
          | :punctuation
          | :muted
          | :other

  @type t :: %__MODULE__{text: String.t(), kind: kind()}

  @spec atom(String.t()) :: t()
  def atom(text), do: %__MODULE__{text: text, kind: :atom}

  @spec number(String.t()) :: t()
  def number(text), do: %__MODULE__{text: text, kind: :number}

  @spec string(String.t()) :: t()
  def string(text), do: %__MODULE__{text: text, kind: :string}

  @doc "A literal with its own syntax colour — `nil`, `true` and `false`."
  @spec special(String.t()) :: t()
  def special(text), do: %__MODULE__{text: text, kind: :special}

  @spec module(String.t()) :: t()
  def module(text), do: %__MODULE__{text: text, kind: :module}

  @spec punctuation(String.t()) :: t()
  def punctuation(text), do: %__MODULE__{text: text, kind: :punctuation}

  @doc "Text standing in for data that is not here, such as a truncation marker."
  @spec muted(String.t()) :: t()
  def muted(text), do: %__MODULE__{text: text, kind: :muted}

  @doc """
  A term with no syntax of its own, rendered through `inspect/2` — pids, ports,
  references, functions.
  """
  @spec other(String.t()) :: t()
  def other(text), do: %__MODULE__{text: text, kind: :other}
end
