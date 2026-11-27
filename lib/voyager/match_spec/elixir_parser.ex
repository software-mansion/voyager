defmodule Voyager.MatchSpec.ElixirParser do
  @moduledoc false

  alias Voyager.MatchSpec
  alias Voyager.MatchSpec.Utils

  # Expanding a macro runs its code on this node, so only these Kernel ones are in scope.
  @macros Enum.sort(and: 2, in: 2, is_nil: 1, is_struct: 1, is_struct: 2, or: 2, ..: 2)
  @bitwise Bitwise.__info__(:functions)

  @spec parse_fun(String.t(), :table | :trace) ::
          {:ok, MatchSpec.t()} | {:error, MatchSpec.reason()}
  def parse_fun(source, type) do
    case Code.string_to_quoted(source, emit_warnings: false) do
      {:ok, {:fn, _meta, _clauses} = ast} ->
        with :ok <- check_forms(ast),
             {:ok, clauses} <- erlang_clauses(ast),
             do: Utils.transform(clauses, type)

      {:ok, _other} ->
        {:error, {:syntax, "expected one fn ... end"}}

      {:error, {_location, message, token}} ->
        {:error, {:syntax, syntax_message(message, token)}}
    end
  end

  # `env/0` limits local macros only: `import`/`require` add others, a remote call expands a
  # required module's (`Kernel.binding()`), and `%Name{}` calls `Name.__struct__/1`.
  defp check_forms(ast) do
    case ast |> Macro.prewalker() |> Enum.find(&runs_code?/1) do
      nil -> :ok
      form -> {:error, {:unsupported, "`#{Macro.to_string(form)}` is not supported"}}
    end
  end

  defp runs_code?({form, _meta, args}) when form in [:import, :require, :%] and is_list(args),
    do: true

  # `Mod.fun()` and `map.key` share this AST, so only the receiver tells them apart.
  defp runs_code?({{:., _dot, [receiver, _name]}, _meta, _args}), do: may_have_macros?(receiver)
  defp runs_code?(_ast), do: false

  # A variable or an `a.b` result is only known at runtime; the walk checks the inner `a.b` itself.
  defp may_have_macros?(:erlang), do: false
  defp may_have_macros?({{:., _dot, _target}, _meta, _args}), do: false
  defp may_have_macros?({name, _meta, context}) when is_atom(name) and is_atom(context), do: false
  defp may_have_macros?(_ast), do: true

  # `:elixir.quoted_to_erl/2` is private to Elixir: it expands and translates, never evaluates.
  defp erlang_clauses(ast) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, ast |> :elixir.quoted_to_erl(env()) |> elem(0)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case result do
      {:ok, {:fun, _anno, {:clauses, clauses}}} ->
        {:ok, clauses}

      {:error, message} ->
        error = Enum.find(diagnostics, &(&1.severity == :error))
        {:error, {:unsupported, if(error, do: error.message, else: message)}}
    end
  end

  defp env do
    env = Code.env_for_eval([])

    %{
      env
      | requires: [Kernel],
        macros: [{Kernel, @macros}],
        functions: [{Bitwise, @bitwise} | env.functions],
        # Never called, only non-nil: with `function: nil` Elixir refuses an unknown call such as
        # `return_trace()`; with one set it stays the local call `:ms_transform` reads as an action.
        function: {:placeholder, 0}
    }
  end

  defp syntax_message({prefix, suffix}, token), do: prefix <> token <> suffix
  defp syntax_message(message, token), do: message <> token
end
