%%% ---------------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and Patrick Lu
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved.
%%%
%%% @doc Implementation of a Node in a distributed key-value system. Each node
%%%      contains a portion of the storage processes in the system.
%%% @end
%%%----------------------------------------------------------------------------

-module(key_value_node).
-behavior(gen_server).

%% External exports
-export([main/1,
         get_neighbors/4,
         closest_neighbor/3,
         my_node_neighbors/2]).

%% gen_server callbacks
-export([init/1, 
         handle_call/3, 
         handle_cast/2, 
         handle_info/2, 
         code_change/3, 
         terminate/2]).

-define(BSUPERVISOR, bsupervisor).
-define(SUPERVISOR, supervisor).
-define(NODE(X), {node, X}).
-define(STORPROC(X), list_to_atom("storageProcess" ++ integer_to_list(X))).
-define(BSTORPROC(X), list_to_atom("backupStorageProcess" ++ integer_to_list(X))).
-define(PRNTSTR(X), timestamp(now()) ++ " [NODE " ++ integer_to_list(X) ++ "]: ").

-record(state, {m,
                nodeNum,
                storage_processes,
                bstorage_processes,
                aheadNodeNum,
                behindNode,
                behindNodeNum}).

%%%============================================================================
%%% API
%%%============================================================================

main(Args) ->
    [ MString, NodeName | NodeToConnectTo ] = Args,
    M = list_to_integer(MString),
    os:cmd("epmd -daemon"),
    net_kernel:start([list_to_atom(NodeName), shortnames]),
    io:format(timestamp (now()) ++ ": Initializing The Node ~p.~n", [node()]),
    
    case NodeToConnectTo of 

        %% Only 1 Node so far
        [] ->
            % List of all possible storage processes
            TotNum = round(math:pow(2,M)),
            Mseq = lists:seq(0, TotNum-1),
            io:format(?PRNTSTR(0) ++ "I'm the first node in this system, so I've made my node number 0.~n"),
            gen_server:start({global, ?NODE(0)}, key_value_node, {M, 0, Mseq, 0, 0}, []);
        
        %% There are nodes to connect to... if someone is stupid and puts more
        %% than one node, we ignore the rest of them.
        [Node | _Rest] -> 
            case net_adm:ping(list_to_atom(Node)) of
                pong ->
                    ok;
                pang ->
                    io:format(timestamp(now()) ++ ": You did not give an actual alive node to connect to.~n"),
                    erlang:halt()
            end,

            {MyNodeNum, AheadNodeNum, BehindNodeNum, MyStorageProcesses} = find_myself(M),
            io:format(?PRNTSTR(MyNodeNum) ++ "I've chosen my node number to be ~p; the node ahead of me is ~p; the node behind me is ~p.~n", [MyNodeNum, AheadNodeNum, BehindNodeNum]),

            gen_server:start({global, ?NODE(MyNodeNum)}, key_value_node, {M, MyNodeNum, MyStorageProcesses, AheadNodeNum, BehindNodeNum}, [])
        end.

%%%============================================================================
%%% GenServer Calls/Casts
%%%============================================================================


%%%============================================================================
%%% GenServer Callbacks 
%%%============================================================================

%% @spec init({M, NodeNum, MyStorageProcesses, AheadNodeNum, BehindNodeNum}) -> {ok, State}.
%% @doc Starts up the given new nodes storage processes. If it is the first
%%      node, then we can just start it with a whole bunch of empty storage
%%      processes. If not, we need to grab some ETS tables from the node
%%      behind us and update which processes (and backup storage processes
%%      the node behind us and in front of us are in control of.
init({M, NodeNum, MyStorageProcesses, AheadNodeNum, BehindNodeNum}) ->
    process_flag(trap_exit, true),
    storage_sup:start_link(),
    bstorage_sup:start_link(),
    TotNum = round(math:pow(2,M)),

    case NodeNum == 0 of
        %% If this is our first node, just give us everything
        true ->
            io:format(?PRNTSTR(NodeNum) ++ "Starting My Storage Processes (processes 0 to ~p).~n", [TotNum-1]),
            lists:foreach(fun(I) -> start_storage_process(NodeNum, M, I) end, MyStorageProcesses),


            io:format(?PRNTSTR(NodeNum) ++ "Starting My Backup Storage Processes (processes 0 to ~p).~n", [TotNum-1]),
            lists:foreach(fun(I) -> start_bstorage_process(M, I) end, MyStorageProcesses),

            io:format(?PRNTSTR(NodeNum) ++ "Done initiating Storage Processes and Backup Storage Processes!~n"),

            {ok, #state{m = M, 
                nodeNum = NodeNum,
                storage_processes = MyStorageProcesses,
                bstorage_processes = MyStorageProcesses,
                aheadNodeNum = AheadNodeNum,
                behindNode = node(),
                behindNodeNum = BehindNodeNum}};

        %% If this isnt the first node
        false ->
            % Ask the node right behind you for the ets tables of the processes that are now yours
            ClosestBack = closest_neighbor(MyStorageProcesses, BehindNodeNum, M),
            {ETS, BackupETS, Node} = gen_server:call({global, ?NODE(ClosestBack)},
                {updateBehind, MyStorageProcesses, BehindNodeNum}, 10000),


            % Tell the node ahead of you to update their processes.
            BackupProcesses = lists:map(fun({X, _ETS}) -> X end, BackupETS),
            gen_server:cast({global, ?NODE(AheadNodeNum)}, {updateAhead, MyStorageProcesses, node()}),


            % Starting backup and normal storage processes
            io:format(?PRNTSTR(NodeNum) ++ "Starting My Storage Processes (processes ~p to ~p).~n", 
                                                    [NodeNum, mod(AheadNodeNum - 1, TotNum)]),
            lists:foreach(fun({I, TabList}) -> 
                start_storage_process(NodeNum, M, I, TabList) end, ETS),

            io:format(?PRNTSTR(NodeNum) ++ "Starting My Backup Storage Processes (processes ~p to ~p).~n", 
                                                        [BehindNodeNum, mod(NodeNum - 1, TotNum)]),
            lists:foreach(fun({I, BTabList}) -> 
                start_bstorage_process(M, I, BTabList) end, BackupETS),
            io:format(?PRNTSTR(NodeNum) ++ "Done initiating Storage Processes and Backup Storage Processes!~n"),


            % Monitoring node behind you
            erlang:monitor_node(Node, true),
            {ok, #state{m = M, 
                nodeNum = NodeNum,
                storage_processes = MyStorageProcesses,
                bstorage_processes = BackupProcesses,
                aheadNodeNum = AheadNodeNum,
                behindNode = Node,
                behindNodeNum = BehindNodeNum}}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%% SYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_call({updateBehind, N, B}, _From, S) -> {reply, {Tabs, BTabs, node()}, State}
%% @doc Handling synchronous call when the node behind that we are trying to
%%      update is actually just our neighbor. So we can just do stuff and then
%%      reply.
handle_call({updateBehind, NewGuysStorageProcesses, BehindNodeNum}, _From, S = #state{nodeNum = BehindNodeNum}) ->
    NewNode = hd(NewGuysStorageProcesses),
    io:format(?PRNTSTR(BehindNodeNum) ++  "Node ~p has joined the system and I'm the node directly behind him, so I'm removing storage processes (~p to ~p).~n", [NewNode, NewNode, lists:last(NewGuysStorageProcesses)]),

    %% First work with the non-backups
    %% Get tuples of {X, Ets Table} for every storage process in a list
    Tabs = lists:map(fun(X) -> 
        {X, gen_server:call({global, ?STORPROC(X)},getTab)} end, NewGuysStorageProcesses),

    %% Terminate all storage processes in NewGuysStorageProcess
    lists:foreach(fun(ChildId) -> 
        storage_sup:terminate_storage_process(global:whereis_name(?STORPROC(ChildId))) end, NewGuysStorageProcesses),

    

    %% Now working with the backups
    MyNewStorage = lists:subtract(S#state.storage_processes,NewGuysStorageProcesses),
    BTabs = lists:map(fun(X) ->
        {X, gen_server:call({global, ?STORPROC(X)}, getTab)} end, MyNewStorage),
    

    {reply, {Tabs, BTabs, node()}, S#state{aheadNodeNum = hd(NewGuysStorageProcesses), 
                                   storage_processes = MyNewStorage}};


%% @spec handle_call({updateBehind, N, B}, From, S) -> {noreply, State}
%% @doc Handling synchronous call when the node behind that we are trying to
%%      update is NOT our neighbor. This means we passed the query to the closest
%%      node to the neighbor behind us, and it will keep being passed on through
%%      casts.
handle_call({updateBehind, NewGuysStorageProcesses, BehindNodeNum}, From, S) ->
    NewNode = hd(NewGuysStorageProcesses),
    io:format(?PRNTSTR(S#state.nodeNum) ++  "Node ~p has joined the system and I'm NOT the node directly behind him, so I'm passing off the update request to my node neighbor closest to the node behind Node ~p.~n", [NewNode, NewNode]),
    %% If this ISNT the one we are looking for.
    MyStorageProcesses = S#state.storage_processes,
    M = S#state.m,
    Closest = closest_neighbor(MyStorageProcesses, BehindNodeNum, M),
    gen_server:cast({global, ?NODE(Closest)},
        {updateBehind, NewGuysStorageProcesses, BehindNodeNum, From}),
    {noreply, S};


%% @spec handle_call({retrieveBackups, B}, _From, S) -> {reply, State}
%% @doc Handling synchronous call when the node behind that we are trying to
%%      get backups from our neighbor behind. We can just get the backups 
%%      from them and get a reply now (this happens when a node dies).
handle_call({retrieveBackups, BehindNodeNum}, _From, S = #state{nodeNum = BehindNodeNum}) ->
    io:format(?PRNTSTR(S#state.nodeNum) ++ "Retrieve backups after a node leaving.~n"),
    BTabs = lists:map(fun(X) ->
        {X, gen_server:call({global, ?STORPROC(X)}, getTab)} end, S#state.storage_processes),
    {reply, {BTabs, node()}, S};


%% @spec handle_call({retrieveBackups, B}, From, S) -> {reply, State}
%% @doc Handling synchronous call when the node behind that we are trying to
%%      get backups from is NOT our neighbor. We pass the request on through
%%      casts to our closest neighbor to the designated behind-node.
handle_call({retrieveBackups, BehindNodeNum}, From, S) ->
    MyStorageProcesses = S#state.storage_processes,
    M = S#state.m,
    Closest = closest_neighbor(MyStorageProcesses, BehindNodeNum, M),
    gen_server:cast({global, ?NODE(Closest)}, {retrieveBackups, BehindNodeNum, From}),
    {noreply, S};

handle_call(_Something, _From, S) ->
    {reply, idkyet, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%% END SYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%% ASYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_cast({updateBehind, N, B, From}, S) -> {reply, {Tabs, BTabs, node()}, State}
%% @doc Handling asynchronous call when we've finally reach the node behind
%%      the new node. So we can now update, and send our ets tables to the node
%%      in front of us (which we are allowed to do becasue the node in front
%%      of us is always our neighbor)
handle_cast({updateBehind, NewGuysStorageProcesses, BehindNodeNum, From}, S = #state{nodeNum = BehindNodeNum}) ->
    NewNode = hd(NewGuysStorageProcesses),
    io:format(?PRNTSTR(BehindNodeNum) ++  "Node ~p has joined the system and I'm the node directly behind him, so I'm removing storage processes (~p to ~p).~n", 
                [NewNode, NewNode, lists:last(NewGuysStorageProcesses)]),
    %% First work with the non-backups
    %% Get tuples of {X, Ets Table} for every storage process in a list
    Tabs = lists:map(fun(X) -> 
        {X, gen_server:call({global, ?STORPROC(X)},getTab)} end, NewGuysStorageProcesses),

    %% Terminate all storage processes in NewGuysStorageProcess
    lists:foreach(fun(ChildId) -> 
        storage_sup:terminate_storage_process(global:whereis_name(?STORPROC(ChildId))) end,
        NewGuysStorageProcesses),
    

    %% Now working with the backups
    MyNewStorage = lists:subtract(S#state.storage_processes,NewGuysStorageProcesses),
    BTabs = lists:map(fun(X) ->
        {X, gen_server:call({global, ?STORPROC(X)}, getTab)} end, MyNewStorage),

    gen_server:reply(From, {Tabs, BTabs, node()}),

    {noreply, S#state{aheadNodeNum = hd(NewGuysStorageProcesses), 
              storage_processes= MyNewStorage}};

%% @spec handle_cast({updateBehind, N, B, From}, S) -> {noreply, State}
%% @doc Handling asynchronous call when we are NOT at the node behind the
%%      currently joining node... so we pass the request on.
handle_cast({updateBehind, NewGuysStorageProcesses, BehindNodeNum, From}, S) ->
    NewNode = hd(NewGuysStorageProcesses),
    io:format(?PRNTSTR(S#state.nodeNum) ++  "Node ~p has joined the system and I'm NOT the node directly behind him, so I'm passing off the update request to my node neighbor closest to the node behind Node ~p.~n", [NewNode, NewNode]),
    %% If this ISNT the one we are looking for.
    MyStorageProcesses = S#state.storage_processes,
    M = S#state.m,
    Closest = closest_neighbor(MyStorageProcesses, BehindNodeNum, M),
    gen_server:cast({global, ?NODE(Closest)},
        {updateBehind, NewGuysStorageProcesses, BehindNodeNum, From}),
    {noreply, S};

%% @spec handle_cast({updateAhead, N, NN}, S) -> {noreply, State}
%% @doc Handling asynchronous call when updating the node ahead of the
%%      currently joining node.
handle_cast({updateAhead, NewGuysStorageProcesses, NewGuyNode}, S) ->
    NewNode = hd(NewGuysStorageProcesses),
    BehindNodeNum = hd(NewGuysStorageProcesses),
    BackupsToDelete = lists:subtract(S#state.bstorage_processes, NewGuysStorageProcesses),
    io:format(?PRNTSTR(S#state.nodeNum) ++  "Node ~p has joined the system and I'm the node directly ahead of him, so I'm removing backup processes (~p to ~p).~n", [NewNode, hd(BackupsToDelete), lists:last(BackupsToDelete)]),
    lists:foreach(fun(BackupID) -> bstorage_sup:terminate_bstorage_process(?BSTORPROC(BackupID)) end, BackupsToDelete),
    erlang:monitor_node(S#state.behindNode, false),
    erlang:monitor_node(NewGuyNode, true),

    {noreply, S#state{bstorage_processes = NewGuysStorageProcesses,
                     behindNode = NewGuyNode,
                     behindNodeNum = BehindNodeNum}};


%% @spec handle_cast({retrieveBackups, B, From}, S) -> {noreply, State}
%% @doc Asynchronous call to grab backup tables when the node previously
%%      ahead of us has died. We've finally reached the behindNode, so we can
%%      grab the backups and send them over.
handle_cast({retrieveBackups, BehindNodeNum, From}, S = #state{nodeNum = BehindNodeNum}) ->
    io:format(?PRNTSTR(S#state.nodeNum) ++ "Retrieve backups after a node leaving.~n"),
    BTabs = lists:map(fun(X) ->
        {X, gen_server:call({global, ?STORPROC(X)}, getTab)} end, S#state.storage_processes),
    gen_server:reply(From, {BTabs, node()}),
    {noreply, S};

%% @spec handle_cast({retrieveBackups, B, From}, S) -> {noreply, State}
%% @doc Asynchronous call to grab backup tables when a node has died.
%%      Unfortunately, we are not the node behind the one that died, so we
%%      pass on the message through casts.
handle_cast({retrieveBackups, BehindNodeNum, From}, S) ->
    MyStorageProcesses = S#state.storage_processes,
    M = S#state.m,
    Closest = closest_neighbor(MyStorageProcesses, BehindNodeNum, M),
    gen_server:cast({global, ?NODE(Closest)}, {retrieveBackups, BehindNodeNum, From}),
    {noreply, S};
 

%% @spec handle_cast({updateBackups, NewBackups, NewBehindNodeNum}, S) -> {noreply, State}
%% @doc We need to update our backups after a node has died (this is the node ahead of the
%%      node ahead of the node that died).
handle_cast({updateBackups, NewBackups, NewBehindNodeNum}, S = #state{m = M}) ->
    io:format(?PRNTSTR(S#state.nodeNum) ++ "Adding backups after a node leaving.~n"),
    lists:foreach(fun({I, TabList}) -> start_bstorage_process(M, I, TabList) end, NewBackups),
    BackupNums = lists:map(fun({X, _ETS}) -> X end, NewBackups) ++ S#state.bstorage_processes,

    {noreply, S#state{bstorage_processes = BackupNums,
                     behindNodeNum = NewBehindNodeNum}};

handle_cast(_Something, S) ->
    {noreply, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%% END ASYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% OTHER MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_info({nodedown, _}, S) -> {noreply, State}
%% @doc The node behind us has died, so we need to update our storage processes
%%      registered node number, and tell the new nodes ahead and behind us to
%%      update their stuff too.
handle_info({nodedown,_}, S = #state{nodeNum = MyOldNodeNum,
                                     behindNodeNum = OldBehindNodeNum,
                                     m = M,
                                     storage_processes = SP,
                                     bstorage_processes = BSP})->
    NodeNumList = get_nodes(),
    io:format(?PRNTSTR(MyOldNodeNum) ++ "Node ~p behind me just left (either fasionably or unfasionably) so I'm changing my Node to ~p and updating my processes, the processes of the node ahead of me, and the processes of the node behind me accordingly.~n",[OldBehindNodeNum, OldBehindNodeNum]),

    %% If we have reduced to one node...
    case length(NodeNumList) == 1 of
        true ->
            Procs = lists:seq(0, round(math:pow(2,M))-1),
            Tabs = lists:map(fun(X) -> 
                {X, gen_server:call({global, ?STORPROC(X)},getTab)} end, SP),
            BTabs = lists:map(fun(X) -> 
                {X, gen_server:call(?BSTORPROC(X),getTab)} end, BSP),
            lists:foreach(fun({I, TabList}) -> start_bstorage_process(M, I, TabList) end, Tabs),
            lists:foreach(fun({I, TabList}) -> start_storage_process(OldBehindNodeNum, M, I, TabList) end, BTabs),

            lists:foreach(fun(StorProc) -> 
                gen_server:call({global, ?STORPROC(StorProc)}, {changeNodeNum, OldBehindNodeNum}) end, SP),

            global:unregister_name(?NODE(MyOldNodeNum)),
            global:re_register_name(?NODE(OldBehindNodeNum), self()),

            {noreply, S#state{nodeNum = OldBehindNodeNum,
                      behindNodeNum = OldBehindNodeNum,
                      behindNode = node(),
                      storage_processes = Procs,
                      bstorage_processes = Procs}};

        %% If we havnt reduced to one node, then we need to update ourselves, the node behind us
        %% and the node ahead of us.
        false ->
            {_Min, BehindNodeNum} = lists:min(lists:map(fun(X) -> {mod((OldBehindNodeNum - X), round(math:pow(2,M))), X} end, NodeNumList)),


            BackupToRealTabs = lists:map(fun(X) ->
                {X, gen_server:call(?BSTORPROC(X), getTab)} end, BSP),

            lists:foreach(fun(BackupID) -> bstorage_sup:terminate_bstorage_process(?BSTORPROC(BackupID)) end, BSP),
            lists:foreach(fun({I, TabList}) -> start_storage_process(OldBehindNodeNum, M, I, TabList) end, BackupToRealTabs),

            lists:foreach(fun(StorProc) -> 
                gen_server:call({global, ?STORPROC(StorProc)}, {changeNodeNum, OldBehindNodeNum}) end, SP),

            MyStorageProcesses = BSP ++ SP,
            ClosestBack = closest_neighbor(MyStorageProcesses, BehindNodeNum, M),
            {BTabs, Node} = gen_server:call({global, ?NODE(ClosestBack)}, {retrieveBackups, BehindNodeNum}, 10000),


            global:unregister_name(?NODE(MyOldNodeNum)),
            global:re_register_name(?NODE(OldBehindNodeNum), self()),
            gen_server:cast({global, ?NODE(S#state.aheadNodeNum)},{updateBackups, BackupToRealTabs, OldBehindNodeNum}),


            erlang:monitor_node(Node, true),

            BackupProcesses = lists:map(fun({X, _BTabList}) -> X end, BTabs),
            lists:foreach(fun({I, BTabList}) -> start_bstorage_process(M, I, BTabList) end, BTabs),

            {noreply, S#state{nodeNum = OldBehindNodeNum,
                              behindNodeNum = BehindNodeNum,
                              behindNode = Node,
                              storage_processes = MyStorageProcesses,
                              bstorage_processes = BackupProcesses}}
    end;

handle_info({'EXIT', _Port, Reason}, State) ->
    {stop, {port_terminated_unexpectedly, Reason}, State};

handle_info(Else,S) ->
    io:format(?PRNTSTR(S#state.nodeNum) ++ "Got unexpected message, ~p.~n", [Else]),
    {noreply, S}. 
    
terminate(_Blah, _State) ->
    ok.
%% Unused Callbacks
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%                               Other Functions                               %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% Start storage process
start_storage_process(NodeNum, M, I) ->
    TabId = ets:new(undefined, [ordered_set, public]),
    storage_sup:start_storage_process(NodeNum, M, I, TabId).

start_storage_process(NodeNum, M, I, TabList) ->
    TabId = ets:new(undefined, [ordered_set, public]),
    lists:foreach(fun(Tuple) -> ets:insert(TabId, Tuple) end, TabList),
    storage_sup:start_storage_process(NodeNum, M, I, TabId).

%% Start backup storage process
start_bstorage_process(M, I) ->
    TabId = ets:new(undefined, [ordered_set, public]),
    bstorage_sup:start_bstorage_process(M, I, TabId).

start_bstorage_process(M, I, BTabList) ->
    TabId = ets:new(undefined, [ordered_set, public]),
    lists:foreach(fun(Tuple) -> ets:insert(TabId, Tuple) end, BTabList),
    bstorage_sup:start_bstorage_process(M, I, TabId).


%% @spec timestamp(Now) -> string()
%% @doc Generates a fancy looking timestamp, found on:
%%        http://erlang.2086793.n4.nabble.com/formatting-timestamps-td3594191.html
timestamp(Now) -> 
    {_, _, Micros} = Now, 
    {{YY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(Now), 
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w.~p", 
                  [YY, MM, DD, Hour, Min, Sec, Micros]).


%% Used in get_nodes... filter out things that are not of the form
%% {node, Nodenum}
filter(X) ->
    case X of 
        {node, _NodeNum} ->
            true;
        _Else ->
            false
    end.

%% Get the numbers of all nodes in our system
get_nodes() ->
    global:sync(),
    lists:sort(lists:map(
        fun({node, NodeNum}) -> NodeNum end, 
        lists:filter(fun(X) -> filter(X) end, global:registered_names())
        )).


%% Choosing a random node
find_myself(M) ->
    % List of all possible storage processes
    TotNum = round(math:pow(2,M)),
    Mseq = lists:seq(0, TotNum-1),

    % Find availible ones
    NodeNumList = get_nodes(),
    OpenNodes = lists:subtract(Mseq, NodeNumList),

    % Randomly Choose one
    {A1,A2,A3} = now(),
    random:seed(A1,A2,A3),
    Index = random:uniform(length(OpenNodes)),
    ChosenNodeNum = lists:nth(Index, OpenNodes),

    % Find the node ahead of me, find the node behind me
    {_Min, AheadNodeNum} = lists:min(lists:map(fun(X) -> {mod((X - ChosenNodeNum), TotNum), X} end, NodeNumList)),
    {_Min2, BehindNodeNum} = lists:min(lists:map(fun(X) -> {mod((ChosenNodeNum - X), TotNum), X} end, NodeNumList)),

    % Find all the processes I'm in charge of

    case AheadNodeNum < ChosenNodeNum of
        true ->
            SP = lists:seq(ChosenNodeNum, TotNum - 1) ++ lists:seq(0, AheadNodeNum - 1),
            {ChosenNodeNum, AheadNodeNum, BehindNodeNum, SP};
        false ->
            SP = lists:seq(ChosenNodeNum, AheadNodeNum - 1),
            {ChosenNodeNum, AheadNodeNum, BehindNodeNum, SP}
    end.

closest_neighbor(MyStorageProcesses, J, M) ->
    NodeNeighbors = my_node_neighbors(M, MyStorageProcesses),
    TotNum = round(math:pow(2,M)),
    {_Dist, Node} = lists:min(lists:map(fun(X) -> {mod((J - X), TotNum), X} end, NodeNeighbors)),
    Node.

my_node_neighbors(M, MyStorageProcesses) ->
    NodeNumList = get_nodes(),
    ProcessNeighbors = sets:to_list(sets:from_list(
            lists:flatten(lists:map(fun(I) -> get_neighbors(M, I, 0, []) end, 
                            MyStorageProcesses)))),
    ClosestNodesToNeighbors = lists:map(fun(I) -> closest_node(M, NodeNumList, I) end, ProcessNeighbors),
    lists:flatten(ClosestNodesToNeighbors).

closest_node(M, NodeNumList, ProcessNum) ->
    TotNum = round(math:pow(2,M)),
    {_Min2, BehindNodeNum} = lists:min(lists:map(fun(X) -> {mod((ProcessNum - X), TotNum), X} end, NodeNumList)),
    BehindNodeNum.

get_neighbors(_M, _I, _M, L) ->
    L;

get_neighbors(M, I, K, L) ->
    TotNum = round(math:pow(2,M)),
    NewL = lists:append(L, [mod(I + round(math:pow(2,K)), TotNum)]),
    get_neighbors(M, I, K+1, NewL).


% Calculate Modulo
mod(X,Y) when X > 0 -> X rem Y;
mod(X,Y) when X < 0 -> Y + X rem Y;
mod(0,_Y) -> 0.