defmodule Voyager.Services.CodeInjectorTest do
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Services.CodeInjector

  @compile {:no_warn_undefined,
            [
              :voyager_remote_code_file,
              :voyager_remote_code_macro
            ]}

  setup do
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)

    on_exit(fn ->
      Application.put_env(:voyager, :erpc, Voyager.ErpcMock)
      unload(:voyager_remote_code_file)
      unload(:voyager_remote_code_macro)
      unload(:voyager_remote_code_bad)
      unload(:voyager_agent)
    end)

    :ok
  end

  describe "load/2" do
    test "reads an .erl file, compiles it on the node, and loads the module" do
      path =
        tmp_erl("voyager_remote_code_file.erl", """
        -module(voyager_remote_code_file).
        -export([ping/0]).
        ping() -> pong.
        """)

      assert {:ok, :voyager_remote_code_file} = CodeInjector.load(Node.self(), path)
      assert :voyager_remote_code_file.ping() == :pong
    end

    test "returns read_failed when the file is missing" do
      path = Path.join(System.tmp_dir!(), "voyager_remote_code_missing.erl")

      assert {:error, {:read_failed, {^path, :enoent}}} = CodeInjector.load(Node.self(), path)
    end

    test "returns parse_failed when a form is incomplete" do
      path = tmp_erl("voyager_remote_code_incomplete.erl", "-module(foo)")

      assert {:error, {:parse_failed, _errors}} = CodeInjector.load(Node.self(), path)
    end

    test "returns compile_failed when -module is absent" do
      path =
        tmp_erl("voyager_remote_code_nomodule.erl", """
        -export([ok/0]).
        ok() -> ok.
        """)

      assert {:error, {:compile_failed, {_errors, _warnings}}} =
               CodeInjector.load(Node.self(), path)
    end

    test "returns compile_failed for source that does not compile" do
      path =
        tmp_erl("voyager_remote_code_bad.erl", """
        -module(voyager_remote_code_bad).
        -export([ok/0]).
        ok() -> A.
        """)

      assert {:error, {:compile_failed, {_errors, _warnings}}} =
               CodeInjector.load(Node.self(), path)
    end

    test "expands preprocessor macros before sending forms" do
      path =
        tmp_erl("voyager_remote_code_macro.erl", """
        -module(voyager_remote_code_macro).
        -export([name/0]).
        name() -> ?MODULE.
        """)

      assert {:ok, :voyager_remote_code_macro} = CodeInjector.load(Node.self(), path)
      assert :voyager_remote_code_macro.name() == :voyager_remote_code_macro
    end

    test "returns load_failed when the binary cannot be loaded" do
      path =
        tmp_erl("voyager_remote_code_file.erl", """
        -module(voyager_remote_code_file).
        -export([ping/0]).
        ping() -> pong.
        """)

      Application.put_env(:voyager, :erpc, Voyager.ErpcMock)

      stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
        case {mod, fun, args} do
          {:compile, :forms, _} ->
            {:ok, :voyager_remote_code_file, "beam"}

          {:code, :load_binary, _} ->
            {:error, :badfile}
        end
      end)

      assert {:error, {:load_failed, :badfile}} = CodeInjector.load(Node.self(), path)
    end
  end

  defp tmp_erl(filename, source) do
    path = Path.join(System.tmp_dir!(), filename)
    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp unload(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end
end
