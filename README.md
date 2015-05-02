A Distributed Key-Value Ring Buffer
=========

The first thing you have to do is set up several nodes. To do this you pass in an integer ```m```, a node name, and optionally a node name of an existing node in the cluster (such that this node can connect to it and join a larger cluster). You might need to run chmod 755 on key_value_node first (or just run sh key_value_node)

```
./key_value_node <M> <NodeName> <OPTIONAL:NodeToConnectTo>
```