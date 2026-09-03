defmodule VoyagerWeb.FormattersTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.Formatters

  describe "byte_parts/1" do
    test "returns bytes unchanged below 1 KiB" do
      assert Formatters.byte_parts(0) == {0, "B"}
      assert Formatters.byte_parts(512) == {512, "B"}
      assert Formatters.byte_parts(1_023) == {1_023, "B"}
    end

    test "rounds KB and MB to whole numbers" do
      assert Formatters.byte_parts(1_024) == {1, "KB"}
      assert Formatters.byte_parts(1_536) == {2, "KB"}
      assert Formatters.byte_parts(1_048_576) == {1, "MB"}
      assert Formatters.byte_parts(1_572_864) == {2, "MB"}
    end

    test "rounds GB and TB to one decimal" do
      assert Formatters.byte_parts(1_073_741_824) == {1.0, "GB"}
      assert Formatters.byte_parts(1_610_612_736) == {1.5, "GB"}
      assert Formatters.byte_parts(1_099_511_627_776) == {1.0, "TB"}
      assert Formatters.byte_parts(1_649_267_441_664) == {1.5, "TB"}
    end

    test "picks the largest fitting unit at boundaries" do
      assert Formatters.byte_parts(1_048_575) == {1_024, "KB"}
      assert Formatters.byte_parts(1_073_741_823) == {1_024, "MB"}
    end
  end

  describe "format_bytes/1" do
    test "returns an em dash for nil" do
      assert Formatters.format_bytes(nil) == "—"
    end

    test "joins value and unit with a space" do
      assert Formatters.format_bytes(0) == "0 B"
      assert Formatters.format_bytes(2_048) == "2 KB"
      assert Formatters.format_bytes(1_610_612_736) == "1.5 GB"
    end
  end

  describe "format_bytes_compact/1" do
    test "joins value and unit with no space" do
      assert Formatters.format_bytes_compact(0) == "0B"
      assert Formatters.format_bytes_compact(2_048) == "2KB"
      assert Formatters.format_bytes_compact(1_610_612_736) == "1.5GB"
    end
  end

  describe "count_parts/1" do
    test "returns a thousands-separated string with nil unit below ten million" do
      assert Formatters.count_parts(0) == {"0", nil}
      assert Formatters.count_parts(1_234) == {"1,234", nil}
      assert Formatters.count_parts(9_999_999) == {"9,999,999", nil}
    end

    test "abbreviates millions with one decimal" do
      assert Formatters.count_parts(10_000_000) == {10.0, "M"}
      assert Formatters.count_parts(12_500_000) == {12.5, "M"}
    end

    test "abbreviates billions with one decimal" do
      assert Formatters.count_parts(1_000_000_000) == {1.0, "B"}
      assert Formatters.count_parts(2_500_000_000) == {2.5, "B"}
    end
  end

  describe "format_count_compact/1" do
    test "joins value and unit with no space" do
      assert Formatters.format_count_compact(1_234) == "1,234"
      assert Formatters.format_count_compact(12_500_000) == "12.5M"
      assert Formatters.format_count_compact(2_500_000_000) == "2.5B"
    end
  end

  describe "format_integer/1" do
    test "leaves values below 1000 untouched" do
      assert Formatters.format_integer(0) == "0"
      assert Formatters.format_integer(999) == "999"
    end

    test "inserts thousands separators" do
      assert Formatters.format_integer(1_000) == "1,000"
      assert Formatters.format_integer(1_234_567) == "1,234,567"
    end

    test "handles negative integers" do
      assert Formatters.format_integer(-1_234) == "-1,234"
    end
  end

  describe "format_time/1" do
    test "renders an HH:MM:SS clock string" do
      {:ok, dt, 0} = DateTime.from_iso8601("2026-06-02T09:08:07Z")
      assert Formatters.format_time(dt) == "09:08:07"
    end
  end

  describe "duration_parts/1" do
    test "returns all zeros for zero duration" do
      assert Formatters.duration_parts(0) == {0, 0, 0, 0, 0}
    end

    test "truncates sub-second milliseconds" do
      assert Formatters.duration_parts(999) == {0, 0, 0, 0, 0}
      assert Formatters.duration_parts(1_500) == {0, 0, 0, 0, 1}
    end

    test "breaks a duration into years, days, hours, minutes, seconds" do
      assert Formatters.duration_parts(61_000) == {0, 0, 0, 1, 1}
      assert Formatters.duration_parts(3_661_000) == {0, 0, 1, 1, 1}
      assert Formatters.duration_parts(90_061_000) == {0, 1, 1, 1, 1}
    end

    test "counts years using a 365-day year" do
      {years, days, hours, minutes, seconds} = Formatters.duration_parts(31_536_000_000)
      assert {years, days, hours, minutes, seconds} == {1, 0, 0, 0, 0}
    end
  end

  describe "format_uptime/1" do
    test "picks the largest meaningful unit" do
      assert Formatters.format_uptime(42_000) == "42s"
      assert Formatters.format_uptime(123_456) == "2m"
      assert Formatters.format_uptime(3_661_000) == "1h 1m"
      assert Formatters.format_uptime(90_061_000) == "1d 1h"
      assert Formatters.format_uptime(31_536_000_000) == "1yr 0d"
    end
  end

  describe "format_pid/1" do
    test "formats a pid in its external form" do
      formatted = VoyagerWeb.Formatters.format_pid(self())

      assert "<" <> _rest = formatted
      assert :erlang.list_to_pid(String.to_charlist(formatted)) == self()
    end
  end

  describe "format_pid_local/1" do
    test "keeps a local pid unchanged" do
      assert VoyagerWeb.Formatters.format_pid_local(self()) ==
               VoyagerWeb.Formatters.format_pid(self())
    end

    test "zeroes the node index of a remote pid" do
      # NEW_PID_EXT for <45.6> on a node this one has never connected to; the
      # decoded pid gets a non-zero local node index.
      remote_pid =
        :erlang.binary_to_term(<<131, 88, 119, 17, "othernode@nowhere", 45::32, 6::32, 1::32>>)

      assert VoyagerWeb.Formatters.format_pid(remote_pid) != "<0.45.6>"
      assert VoyagerWeb.Formatters.format_pid_local(remote_pid) == "<0.45.6>"
    end
  end
end
