# Aggregates the per-run logs of bench-flakiness.sh into a per-test flakiness report.
#
# Reads every run-*.jsonl in the directory (default: ./flakiness-results). Each line is one
# attempt of one test (see Voyager.E2E.FlakinessFormatter). Per test, across the batch:
#
#   runs      runs in which the test executed
#   pass      runs it passed on the first attempt
#   flaky     runs it failed, then passed on a retry
#   fail      runs it never passed, even after retries
#   failures  flaky + fail: runs that were not a clean first-attempt pass
#   score     failures / runs
#
# Usage:
#   elixir dev/aggregate_e2e_flakiness.exs [results-dir] [--write] [--threshold=N]
#
#   --write         also write summary.txt and summary.json into the directory, append the
#                   report to $GITHUB_STEP_SUMMARY and emit workflow annotations
#   --threshold=N   exit 1 if any test's `failures` exceed N

defmodule Voyager.E2E.Flakiness do
  @moduledoc false

  def read_runs(dir) do
    for file <- dir |> File.ls!() |> Enum.sort(),
        String.starts_with?(file, "run-"),
        String.ends_with?(file, ".jsonl") do
      dir |> Path.join(file) |> File.stream!() |> Enum.flat_map(&decode_line/1)
    end
  end

  # A line the run cut off (a killed VM) is skipped, not fatal.
  defp decode_line(line) do
    case JSON.decode(line) do
      {:ok, entry} when is_map(entry) -> [entry]
      _ -> []
    end
  end

  # A run's attempts of one test, in order.
  def classify(statuses) do
    cond do
      hd(statuses) == "passed" -> :pass
      "passed" in statuses -> :flaky
      true -> :fail
    end
  end

  def stats(runs) do
    Enum.reduce(runs, %{}, fn run, acc ->
      run
      |> Enum.sort_by(& &1["attempt"])
      |> Enum.group_by(& &1["test"], & &1["status"])
      |> Enum.reduce(acc, fn {test, statuses}, acc ->
        row =
          Map.get(acc, test, %{
            test: test,
            runs: 0,
            pass: 0,
            flaky: 0,
            fail: 0,
            attempts: 0,
            failed_attempts: 0
          })

        kind = classify(statuses)

        row = %{
          row
          | runs: row.runs + 1,
            attempts: row.attempts + length(statuses),
            failed_attempts: row.failed_attempts + Enum.count(statuses, &(&1 != "passed"))
        }

        Map.put(acc, test, Map.update!(row, kind, &(&1 + 1)))
      end)
    end)
  end

  def rows(stats) do
    stats
    |> Map.values()
    |> Enum.map(fn row ->
      failures = row.flaky + row.fail

      Map.merge(row, %{
        failures: failures,
        score: if(row.runs > 0, do: failures / row.runs, else: 0)
      })
    end)
    |> Enum.sort_by(&{-&1.score, -&1.flaky, -&1.fail})
  end

  def report(rows, runs, threshold) do
    flaky = Enum.filter(rows, &(&1.failures > 0))
    attempts = Enum.sum_by(rows, & &1.attempts)
    failed = Enum.sum_by(rows, & &1.failed_attempts)

    table =
      if flaky == [] do
        ["No flaky or failing tests detected across the batch."]
      else
        header = "SCORE  PASS  FLAKY  FAIL  RUNS  TEST"
        lines = for r <- flaky, do: line(r)
        [header, String.duplicate("-", String.length(header)) | lines]
      end

    breached = if threshold, do: Enum.count(rows, &(&1.failures > threshold)), else: 0

    Enum.join(
      table ++
        [
          "",
          "Summary",
          "  runs:              #{length(runs)}",
          "  tests tracked:     #{length(rows)}",
          "  flaky/failing:     #{length(flaky)}",
          "  attempt failure:   #{failed}/#{attempts} (#{percent(failed, attempts)}%)"
        ] ++
        if(threshold,
          do: [
            "  threshold:         #{threshold} failure(s) per test",
            "  over threshold:    #{breached} test(s)"
          ],
          else: []
        ),
      "\n"
    )
  end

  defp percent(_part, 0), do: "0.00"
  defp percent(part, whole), do: :erlang.float_to_binary(part / whole * 100, decimals: 2)

  # Column widths 7, 6, 7, 6, 6, as the JS report.
  defp line(r) do
    score = r.score |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

    [{score, 7}, {r.pass, 6}, {r.flaky, 7}, {r.fail, 6}, {r.runs, 6}]
    |> Enum.map_join(fn {value, width} -> String.pad_trailing(to_string(value), width) end)
    |> Kernel.<>(r.test)
  end
end

{opts, args, _invalid} =
  OptionParser.parse(System.argv(), strict: [write: :boolean, threshold: :integer])

dir = List.first(args) || Path.join(File.cwd!(), "flakiness-results")
threshold = opts[:threshold]

runs = Voyager.E2E.Flakiness.read_runs(dir)

if runs == [] do
  IO.puts(:stderr, "No run-*.jsonl logs found in #{dir}")
  System.halt(1)
end

rows = runs |> Voyager.E2E.Flakiness.stats() |> Voyager.E2E.Flakiness.rows()
report = Voyager.E2E.Flakiness.report(rows, runs, threshold)
breached = if threshold, do: Enum.filter(rows, &(&1.failures > threshold)), else: []
IO.puts(report)

if opts[:write] do
  File.write!(Path.join(dir, "summary.txt"), report <> "\n")

  File.write!(
    Path.join(dir, "summary.json"),
    JSON.encode!(%{
      runs: length(runs),
      threshold: threshold,
      tests: rows,
      breached: Enum.map(breached, & &1.test)
    }) <> "\n"
  )

  if summary = System.get_env("GITHUB_STEP_SUMMARY") do
    File.write!(summary, "## E2E flakiness benchmark\n\n```\n#{report}\n```\n", [:append])
  end

  for r <- breached do
    IO.puts(
      "::error title=Flaky e2e test::#{r.test}: #{r.failures}/#{r.runs} runs not a clean pass (threshold #{threshold})"
    )
  end
end

if opts[:write] && threshold && breached == [] && Enum.any?(rows, &(&1.failures > 0)) do
  flaky = Enum.count(rows, &(&1.failures > 0))

  IO.puts(
    "::warning::#{flaky} flaky/failing test(s) observed but within the threshold of #{threshold}."
  )
end

if breached != [] do
  IO.puts(
    "::error::E2E flakiness benchmark failed: #{length(breached)} test(s) exceeded the threshold of #{threshold} failure(s) over #{length(runs)} runs."
  )

  System.halt(1)
end
