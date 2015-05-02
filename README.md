A Distributed Key-Value Ring Buffer
=========

The first thing you have to do is set up several nodes. To do this you pass in an integer ```m```, a node name, and optionally a node name of an existing node in the cluster (such that this node can connect to it and join a larger cluster). You might need to run chmod 755 on key_value_node first (or just run sh key_value_node)

```
./key_value_node <M> <NodeName> <OPTIONAL:NodeToConnectTo>
```


There are ```2^m``` storage processes that will be on the cluster (so ```m``` needs to be the same for every node you set up), and those storage processes are divided amongst the nodes in the cluster.

Once you have several nodes set up you can use our nice controller to make queries to the storage processes. To start up the controller, you just give it one of the nodes in the cluster to connect to.

```
% ./controller <NodeToConnectTo>

  Eshell V5.10.4  (abort with ^G)
  (IVw5VVnNMF@lothlorien)1>
```

Then there are several queries you can make:

```erlang
  % Store a key (string) and its value. The storage number doesn't matter
  % as long as it is under 2^m, the system will figure out which storage
  % process it is stupposed to be on (given our internal hash function).
  controller:store(Key, Value, StorageProcessNumber)

  % Retrieve a key's value from the cluster
  controller:retrieve(Key, StorageProcessNumber)

  % Get the lexicographical first key in the cluster
  controller:first_key(StorageProcessNumber)

  % Get the lexicographical last key in the cluster
  controller:last_key(StorageProcessNumber)

  % Get the total number of keys in the cluster
  controller:num_keys(StorageProcessNumber)

  % Get our node list
  controller:node_list(StorageProcessNumber)

  % Kill the node that holds this storage
  controller:leave(StorageProcessNumber)                  

  % Get Storage Process State
  controller:getSPstate(StorageProcessNumber)             

  % Get Node State
  controller:getNodestate(NodeNumber)                     
```

Try it out?
