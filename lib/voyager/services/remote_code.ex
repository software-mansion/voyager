defmodule Voyager.Services.CodeInjector do
  @moduledoc """
  Reads Erlang source from a file, then compiles and loads it on a remote
  node via `:erpc`.

  The target runs `:compile.file/2`, so preprocessing (`?MODULE`, `-ifdef`,
  `?OTP_RELEASE`, includes) uses that node's compiler and OTP version.

  Source is written to a unique temp file on the target, compiled to an
  in-memory beam (`:binary`), loaded with `:code.load_binary/3`, then the
  temp file is deleted. Compile or load failure still deletes the file.

  Injected agent source lives in `priv/voyager_agent.erl` (see `agent_path/0`).
  """

  alias Voyager.Erpc

  @agent_file "voyager_agent.erl"
  @compile_timeout 15_000
  @io_timeout 5_000
  @compile_opts [:binary, :return_errors, :no_debug_info]
  @safe_filename ~r/\A[A-Za-z0-9._-]+\.erl\z/

  @type error_reason ::
          {:read_failed, Path.t(), File.posix()}
          | {:unsafe_filename, String.t()}
          | {:write_failed, charlist(), term()}
          | {:compile_failed, term(), term()}
          | {:load_failed, term()}
          | {:module_mismatch, module(), module()}
          | {:cleanup_failed, charlist(), term()}
          | {:unexpected_compile_result, term()}
          | :timeout
          | :noconnection
          | {:erpc, term()}
          | {:remote_exception, term()}
          | {:remote_exit, term()}
          | {:remote_throw, term()}
          | term()

  @doc """
  Reads Erlang source from `path` on this node, compiles it on `node`
  (including epp), and loads the resulting module.
  """
  @spec load(node(), Path.t()) :: {:ok, module()} | {:error, error_reason()}
  def load(node, path) do
    with {:ok, {expected_module, filename, source}} <- read_source(path),
         {:ok, file_path} <- send_source(node, source, filename) do
      try do
        with {:ok, module, binary} <- remote_compile(node, file_path),
             :ok <- verify_module(expected_module, module) do
          remote_load(node, module, filename, binary)
        end
      after
        _ = clear_source(node, file_path)
      end
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

  defp read_source(path) do
    filename = Path.basename(path)

    with {:ok, source} <- File.read(path),
         :ok <- validate_filename(filename) do
      {:ok, {extract_module(source), filename, source}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:read_failed, path, reason}}

      {:error, _} = error ->
        error
    end
  end

  defp validate_filename(filename) do
    if String.match?(filename, @safe_filename) do
      :ok
    else
      {:error, {:unsafe_filename, filename}}
    end
  end

  defp extract_module(source) do
    case :erl_scan.string(String.to_charlist(source)) do
      {:ok, tokens, _} ->
        find_module_attribute(tokens)

      {:error, _, _} ->
        nil
    end
  end

  defp find_module_attribute([{:-, _}, {:atom, _, :module}, {:"(", _}, {:atom, _, name} | _]) do
    name
  end

  defp find_module_attribute([_token | rest]), do: find_module_attribute(rest)
  defp find_module_attribute([]), do: nil

  defp verify_module(nil, _module), do: :ok
  defp verify_module(expected, expected), do: :ok

  defp verify_module(expected, actual) do
    {:error, {:module_mismatch, expected, actual}}
  end

  defp send_source(node, source, filename) do
    with {:ok, remote_path} <- remote_source_path(node, filename),
         :ok <- remote_write(node, remote_path, source) do
      {:ok, remote_path}
    end
  end

  defp remote_compile(node, file_path) do
    case call(node, :compile, :file, [file_path, @compile_opts], @compile_timeout) do
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

  defp clear_source(node, file_path) do
    case call(node, :file, :delete, [file_path], @io_timeout) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :enoent}} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, {:cleanup_failed, file_path, reason}}

      {:error, _} = error ->
        error
    end
  end

  defp remote_source_path(node, filename) do
    with {:ok, dir} <- remote_tmp_dir(node) do
      suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      name = "voyager_#{suffix}_#{filename}"
      {:ok, String.to_charlist(Path.join(dir, name))}
    end
  end

  defp remote_tmp_dir(node) do
    case call(node, :os, :getenv, [~c"TMPDIR"], @io_timeout) do
      {:ok, dir} when is_list(dir) and dir != [] ->
        {:ok, List.to_string(dir)}

      {:ok, _} ->
        case call(node, :os, :getenv, [~c"TEMP"], @io_timeout) do
          {:ok, dir} when is_list(dir) and dir != [] ->
            {:ok, List.to_string(dir)}

          {:ok, _} ->
            {:ok, "/tmp"}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp remote_write(node, remote_path, source) do
    case call(node, :file, :write_file, [remote_path, source, [:exclusive]], @io_timeout) do
      {:ok, :ok} ->
        _ = call(node, :file, :change_mode, [remote_path, 0o600], @io_timeout)
        :ok

      {:ok, {:error, reason}} ->
        {:error, {:write_failed, remote_path, reason}}

      {:error, _} = error ->
        error
    end
  end

  defp remote_load(node, module, filename, binary) do
    file = String.to_charlist(filename)

    case call(node, :code, :load_binary, [module, file, binary], @io_timeout) do
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
    :error, {:erpc, :timeout} ->
      {:error, :timeout}

    :error, {:erpc, :noconnection} ->
      {:error, :noconnection}

    :error, {:exception, reason, _stack} ->
      {:error, {:remote_exception, reason}}

    :error, {:erpc, _} = reason ->
      {:error, reason}

    :error, reason ->
      {:error, reason}

    :exit, reason ->
      {:error, {:remote_exit, reason}}

    :throw, value ->
      {:error, {:remote_throw, value}}
  end
end
