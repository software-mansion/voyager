defmodule Voyager.Services.CodeInjector do
  @moduledoc """
  Reads Erlang source, runs the preprocessor locally, then compiles and loads
  the forms on a remote node via `:erpc`.

  Macro such as `?MODULE` is expanded with :eep locally.
  Do not use `-if(?OTP_RELEASE ...)` since it shows Voyager's OTP version.
  """

  alias Voyager.Erpc

  @agent_file "voyager_agent.erl"
  @compile_timeout 15_000
  @load_timeout 5_000
  @compile_opts [:binary, :return_errors]

  @type error_reason ::
          {:read_failed, {Path.t(), File.posix()}}
          | {:parse_failed, term()}
          | {:compile_failed, term(), term()}
          | {:load_failed, term()}
          | {:unexpected_compile_result, term()}
          | Erpc.erpc_error()

  @doc """
  Preprocesses Erlang source from `path` on this node, compiles the forms on
  `node`, and loads the resulting module.
  """
  @spec load(node(), Path.t()) :: {:ok, module()} | {:error, error_reason()}
  def load(node, path) do
    with {:ok, forms} <- preprocess(path),
         {:ok, module, binary} <- remote_compile(node, forms) do
      remote_load(node, module, Path.basename(path), binary)
    end
  end

  @doc """
  Path to the Voyager agent source shipped in this application's `priv` directory.
  """
  @spec agent_path() :: Path.t()
  def agent_path do
    :voyager
    |> :code.priv_dir()
    |> Path.join(@agent_file)
  end

  defp preprocess(path) do
    path
    |> String.to_charlist()
    |> :epp.parse_file([])
    |> case do
      {:ok, forms} ->
        case Enum.filter(forms, &match?({:error, _}, &1)) do
          [] -> {:ok, forms}
          errors -> {:error, {:parse_failed, errors}}
        end

      {:error, reason} ->
        {:error, {:read_failed, {path, reason}}}
    end
  end

  defp remote_compile(node, forms) do
    case call(node, :compile, :forms, [forms, @compile_opts], @compile_timeout) do
      {:ok, {:ok, module, binary}} when is_atom(module) and is_binary(binary) ->
        {:ok, module, binary}

      {:ok, {:ok, module, binary, _warnings}} when is_atom(module) and is_binary(binary) ->
        {:ok, module, binary}

      {:ok, {:error, errors, warnings}} ->
        {:error, {:compile_failed, errors, warnings}}

      {:ok, :error} ->
        {:error, {:compile_failed, [], []}}

      {:ok, other} ->
        {:error, {:unexpected_compile_result, other}}

      {:error, _} = error ->
        error
    end
  end

  defp remote_load(node, module, filename, binary) do
    file = String.to_charlist(filename)

    case call(node, :code, :load_binary, [module, file, binary], @load_timeout) do
      {:ok, {:module, ^module}} ->
        {:ok, module}

      {:ok, {:module, other}} ->
        {:error, {:load_failed, {:module_mismatch, other}}}

      {:ok, {:error, reason}} ->
        {:error, {:load_failed, reason}}

      {:ok, other} ->
        {:error, {:load_failed, other}}

      {:error, _} = error ->
        error
    end
  end

  defp call(node, mod, fun, args, timeout) do
    {:ok, Erpc.call(node, mod, fun, args, timeout)}
  catch
    kind, reason -> Erpc.format_error(kind, reason)
  end
end
