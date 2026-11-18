# Seeds a node with a supervised app whose workers cover every link, monitor and
# monitored-by kind the supervision tree and its details panel render.
#
# Run:
#   dev/mock_nodes/relations.sh
#
# Then in Voyager connect to relations@127.0.0.1 with cookie "demo" and open the
# relations_demo app in the supervision tree.

Code.require_file("../../priv/demo/relations_demo.exs", __DIR__)
{:ok, _} = RelationsDemo.start()
