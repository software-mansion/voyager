# Seeds a node with call traffic for the tracing session page: a shop with steady calls and
# exceptions, a mailer with irregular payloads and timing, and a publisher that bursts.
#
# Run:
#   dev/mock_nodes/tracing.sh
#
# Then in Voyager connect to tracing@127.0.0.1 with cookie "demo".

defmodule TracingDemo.Shop do
  @items ~w(rocket fuel suit helmet probe antenna)

  def visit(user) do
    cart = Enum.reduce(1..:rand.uniform(3), [], fn _, cart -> add_item(cart, Enum.random(@items)) end)
    checkout(user, cart)
  end

  def add_item(cart, item), do: [{item, price(item)} | cart]

  def checkout(user, cart) do
    charge(user, total(cart))
  rescue
    error in RuntimeError -> {:declined, user, error.message}
  end

  def charge(user, amount) do
    if :rand.uniform(8) == 1, do: raise("card declined")
    Process.sleep(:rand.uniform(20))
    {:ok, user, amount}
  end

  defp price(item), do: :erlang.phash2(item, 90) + 10
  defp total(cart), do: cart |> Enum.map(&elem(&1, 1)) |> Enum.sum()
end

defmodule TracingDemo.Mailer do
  def deliver(to, payload) do
    send(to, {:mail, payload})
    {:sent, :erlang.external_size(payload)}
  end

  def payload do
    case :rand.uniform(6) do
      1 -> :ping
      2 -> %{id: :rand.uniform(1_000), subject: "hello", read: false}
      3 -> Enum.to_list(1..skewed(5_000))
      4 -> Map.new(1..skewed(300), &{"key_#{&1}", {&1, :rand.uniform()}})
      5 -> :crypto.strong_rand_bytes(skewed(65_536))
      6 -> Enum.reduce(1..skewed(40), :leaf, &{&1, &2})
    end
  end

  # Mostly small, occasionally huge.
  defp skewed(max), do: max(1, trunc(max * :math.pow(:rand.uniform(), 4)))
end

defmodule TracingDemo.Burst do
  def publish(topic, event), do: {:ok, topic, event}
end

defmodule TracingDemo do
  def start do
    shoppers = for n <- 1..4, do: worker(:"shopper_#{n}", fn -> shopper("user-#{n}") end)

    workers =
      shoppers ++
        [
          worker(:mail_inbox, &inbox/0),
          worker(:mail_sender, &mail_sender/0),
          worker(:burst_scheduler, &burst_scheduler/0)
        ]

    {:ok, sup} = Supervisor.start_link(workers, strategy: :one_for_one, name: TracingDemo.Supervisor)
    # Unlinked so an error in the iex shell does not take the workers down with it.
    Process.unlink(sup)
  end

  defp worker(name, fun) do
    run = fn ->
      Process.register(self(), name)
      fun.()
    end

    Supervisor.child_spec({Task, run}, id: name, restart: :permanent)
  end

  defp shopper(user) do
    TracingDemo.Shop.visit(user)
    Process.sleep(200 + :rand.uniform(600))
    shopper(user)
  end

  defp inbox do
    receive do
      _mail -> inbox()
    end
  end

  defp mail_sender do
    count = if :rand.uniform(15) == 1, do: 60 + :rand.uniform(140), else: 1
    for _ <- 1..count, do: TracingDemo.Mailer.deliver(:mail_inbox, TracingDemo.Mailer.payload())
    Process.sleep(trunc(-:math.log(:rand.uniform()) * 150))
    mail_sender()
  end

  defp burst_scheduler do
    Process.sleep(2_000 + :rand.uniform(3_000))

    for worker <- 1..8, do: spawn(fn -> burst(worker) end)
    burst_scheduler()
  end

  # Unpaced, the agent's tracer mailbox overflows and stops the run instead of dropping events.
  defp burst(worker) do
    for i <- 1..1_500 do
      TracingDemo.Burst.publish("orders", %{worker: worker, seq: i})
      if rem(i, 200) == 0, do: Process.sleep(1)
    end
  end
end

TracingDemo.start()
