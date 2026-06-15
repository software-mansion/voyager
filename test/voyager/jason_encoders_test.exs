defmodule Voyager.JasonEncodersTest do
  use ExUnit.Case, async: true

  describe "PID encoder" do
    test "encodes a pid as its :erlang.pid_to_list/1 string" do
      pid = self()
      expected = pid |> :erlang.pid_to_list() |> List.to_string()

      assert Jason.encode!(pid) == ~s("#{expected}")
      assert Jason.decode!(Jason.encode!(pid)) == expected
    end

    test "encodes a pid nested inside a map" do
      pid = self()
      expected = pid |> :erlang.pid_to_list() |> List.to_string()

      assert Jason.decode!(Jason.encode!(%{pid: pid})) == %{"pid" => expected}
    end
  end

  describe "Tuple encoder" do
    test "encodes a tuple as a JSON array" do
      assert Jason.encode!({1, 2, 3}) == "[1,2,3]"
    end

    test "encodes an empty tuple as an empty array" do
      assert Jason.encode!({}) == "[]"
    end

    test "recursively encodes tuple elements, including atoms and pids" do
      pid = self()
      pid_str = pid |> :erlang.pid_to_list() |> List.to_string()

      assert Jason.decode!(Jason.encode!({:ok, "value", pid})) == ["ok", "value", pid_str]
    end

    test "encodes nested tuples" do
      assert Jason.decode!(Jason.encode!({1, {2, 3}})) == [1, [2, 3]]
    end
  end

  describe "Reference encoder" do
    test "encodes a reference as its inspected string" do
      ref = make_ref()

      assert Jason.encode!(ref) == ~s("#{inspect(ref)}")
      assert Jason.decode!(Jason.encode!(ref)) == inspect(ref)
    end
  end

  describe "Port encoder" do
    test "encodes a port as its inspected string" do
      port = hd(Port.list())

      assert Jason.encode!(port) == ~s("#{inspect(port)}")
      assert Jason.decode!(Jason.encode!(port)) == inspect(port)
    end
  end
end
