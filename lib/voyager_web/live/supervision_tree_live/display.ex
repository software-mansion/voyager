defmodule VoyagerWeb.SupervisionTreeLive.Display do
  @moduledoc "Builds the per-node labels pushed to the supervision tree hook, in the current term syntax."

  alias Voyager.Services.SupervisionTree.TreeNode
  alias VoyagerWeb.Formatters

  @typedoc "What the client shows for a node, in the term syntax and PID format settings."
  @type t :: %{
          name: String.t(),
          app: String.t() | nil,
          pid: String.t() | nil,
          initial_call: String.t() | nil,
          current_function: String.t() | nil
        }

  @doc "Each node as a map of its raw fields plus `:display`, ready to push to the client."
  @spec put_all(%{String.t() => TreeNode.t()}) :: %{String.t() => map()}
  def put_all(nodes) do
    Map.new(nodes, fn {key, node} ->
      {key, node |> Map.from_struct() |> Map.put(:display, build(node))}
    end)
  end

  @spec build(TreeNode.t()) :: t()
  def build(%TreeNode{} = node) do
    info = if is_map(node.info), do: node.info, else: %{}

    %{
      name: name(node),
      app: node.app && Formatters.format_term(node.app),
      pid: node.pid && Formatters.pid(node.pid),
      initial_call: mfa(info[:initial_call]),
      current_function: mfa(info[:current_function])
    }
  end

  @spec name(TreeNode.t()) :: String.t()
  def name(%TreeNode{name: pid}) when is_pid(pid), do: Formatters.pid(pid)
  def name(%TreeNode{name: name}), do: Formatters.format_term(name)

  defp mfa(nil), do: nil
  defp mfa(mfa), do: Formatters.format_mfa(mfa)
end
