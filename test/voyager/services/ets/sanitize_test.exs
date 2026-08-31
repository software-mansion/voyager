defmodule Voyager.Services.Ets.SanitizeTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Ets.Sanitize
  alias Voyager.Test.EtsSanitizeFixture

  describe "term/1" do
    test "matches the shared fixture of sample terms" do
      for {input, expected} <- EtsSanitizeFixture.samples() do
        assert Sanitize.term(input) == expected
      end
    end

    test "is idempotent on fixture outputs and truncated markers" do
      for {_input, expected} <- EtsSanitizeFixture.samples() do
        assert Sanitize.term(expected) == expected
      end
    end

    test "does not redact secret-looking keys" do
      term = %{password: "hunter2", token: "abc", secret: "s"}
      assert Sanitize.term(term) == term
    end

    test "keeps atoms, numbers, pids, refs, ports, and functions" do
      fun = &Function.identity/1
      pid = self()
      ref = make_ref()

      assert Sanitize.term(:ok) == :ok
      assert Sanitize.term(42) == 42
      assert Sanitize.term(1.5) == 1.5
      assert Sanitize.term(pid) == pid
      assert Sanitize.term(ref) == ref
      assert Sanitize.term(fun) == fun
    end

    test "keeps binaries at the 512-byte cap" do
      bin = :binary.copy(<<"b">>, Sanitize.max_binary_bytes())
      assert Sanitize.term(bin) == bin
    end

    test "keeps collections of 50 elements" do
      list = Enum.to_list(1..Sanitize.max_collection())
      assert Sanitize.term(list) == list
    end
  end
end
