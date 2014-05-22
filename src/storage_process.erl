%%% ---------------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and Patrick
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc Very Very Very basic generic server for a storage process
%%% @end
%%%----------------------------------------------------------------------------

-module(storage_process).
-behavior(gen_server).

%% External exports
-export([start_link/4,
         closest_neighbor/3,
         timestamp/1,
         get_neighbors/2
         ]).

%% gen_server callbacks
-export([init/1, 
         handle_call/3, 
         handle_cast/2, 
         handle_info/2, 
         code_change/3, 
         terminate/2]).

-define(NODE(X), {node, X}).
-define(STORPROC(X), list_to_atom("storageProcess" ++ integer_to_list(X))).
-define(BSTORPROC(X), list_to_atom("backupStorageProcess" ++ integer_to_list(X))).
-define(PRNTSTR(X,Y), timestamp(now()) ++ " [NODE " ++ integer_to_list(X) ++ 
                                ", StorageProcess " ++ integer_to_list(Y) ++ "]: ").

-record(state, {m,
                i,
                tabId,
                nodeNum}).

%%%============================================================================
%%% API
%%%============================================================================

start_link(NodeNum, M, I, TabId) ->
    % We are registering the storage process as the tuple {storproc, I}
    %io:format(?PRNTSTR(NodeNum, I) ++ "Initializing Storage Process.~n"),
    gen_server:start_link({global, ?STORPROC(I)}, ?MODULE, {M, I, TabId, NodeNum}, []).

%%%============================================================================
%%% GenServer Callbacks
%%%============================================================================

init({M, I, TabId, NodeNum}) ->
    process_flag(trap_exit, true),
    {ok, #state{m = M, i = I, tabId = TabId, nodeNum = NodeNum}}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%% SYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_call(getTab, _From, S) -> {reply, list(), S};
%% @doc Grab the ETS table from this process.
handle_call(getTab, _From, S) ->
    {reply, ets:tab2list(S#state.tabId), S};


%% @spec handle_call({changeNodeNum, NodeNum}, _From, S)  -> {reply, moo, S};
%% @doc Change what the current process thinks its node is.
handle_call({changeNodeNum, NodeNum}, _From, S) ->
    {reply, moo, S#state{nodeNum = NodeNum}};

handle_call(_Something, _From, S) ->
    {reply, idkyet, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%% END SYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%% ASYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_cast({Pid, Ref, store, Key, Value, Hash}, S) -> {noreply, State}
%% @doc Cast that has been forwarded on to store a value at a certain key on
%%      storageProcess with number Hash. The request could be forwarded on
%%      if this isnt the right storageProcess, or it could be the right node
%%      in which case we store the value in our storageProcess ETS table and
%%      then tell the backup storage process on the node ahead of us to store
%%      it too. (ONLY AFTER it has been stored on the backup storage process
%%      do we send the "stored" message back to the controller).
handle_cast({Pid, Ref, store, Key, Value, Hash}, S) when is_pid(Pid) and 
                                                         is_reference(Ref) and
                                                         is_list(Key) ->
    case Hash == S#state.i of
        %% This is the correct storage process
        true -> 
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a storage request" ++
                    " with hash key ~p, so inserting (~p,~p) into our table.~n", 
                    [Hash, Key, Value]),

            store(S#state.tabId, Key, Value),
            {state, _, _, _, _, AheadNodeNum, _, _} = sys:get_state({global, ?NODE(S#state.nodeNum)}),
            AheadNode = node(global:whereis_name(?NODE(AheadNodeNum))),
            gen_server:cast({?BSTORPROC(S#state.i), AheadNode},{store, Key, Value, Pid, Ref});

        %% Well... if the previous comment said "This is the correct storage process"
        %% what do YOU think this corresponds too? Shouldn't be too hard to guess.
        false ->
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a storage request" ++
                    " with hash key ~p, so handing it over.~n", [Hash]),
            hand_over(Pid, Ref, store, Key, Value, Hash, S)
    end,
    {noreply, S};

%% @spec handle_cast({Pid, Ref, retrieve, Key, Hash}, S) -> {noreply, State}
%% @doc Cast that has been forwarded on to retrieve a value at a certain key on
%%      storageProcess with number Hash. The request could be forwarded on
%%      if this isnt the right storageProcess, or it could be the right node
%%      in which case we find the value in our storageProcess ETS table and
%%      send a message back to the controller with the key in that position.
handle_cast({Pid, Ref, retrieve, Key, Hash}, S) when is_pid(Pid) and
                                                     is_reference(Ref) ->
    case Hash == S#state.i of
        %% This is the correct storage process
        true -> 
            Value = retrieve(S#state.tabId, Key),
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a retrieve request" ++
                    " with hash key ~p, and I found its value was ~p.~n", 
                    [Hash, Value]),
            Pid ! {Ref, retrieved, Value};

        %% This is not the right storage process. So we forward the message on.
        false ->
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a retrieve request" ++
                    " with hash key ~p, so handing it over.~n", [Hash]),
            hand_over(Pid, Ref, retrieve, Key, Hash, S)
    end,
    {noreply, S};


%% @spec handle_cast({Pid, Ref, first_key, CurrentFK, OriginalI}, S) -> {noreply, State}
%% @doc Cast that has been forwarded on to get a full snapshot of the system.
%%      We keep track of the first_key we've seen and if anything is more
%%      "lexicographically first" than it, we change our understanding of
%%      the first key. Once we get back around to our starting storageProcess
%%      we know the snapshot of the system and can return the first_key in the
%%      system. If there are NO keys in the system, we return the atom "empty".
handle_cast({Pid, Ref, first_key, CurrentFK, OriginalI}, S) ->
    Filtered = lists:filter(fun(X) -> X /= '$end_of_table' end, 
                                [ets:first(S#state.tabId), CurrentFK]),

    case S#state.i == OriginalI of 
        %% Back at the starting storage process
        true ->
            case Filtered of
                [] ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the first_key request" ++
                        " and found there were no keys.~n"),
                    Pid ! {Ref, result, empty};
                _Else ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the first_key request" ++
                        " and found the first_key to be ~p.~n", [CurrentFK]),
                    Pid ! {Ref, result, CurrentFK}
            end;

        %% still goin around the loop.
        false ->
            NextProcess = ?STORPROC(mod(S#state.i + 1, round(math:pow(2,S#state.m)))),
            case Filtered of 
                [] ->
                    gen_server:cast({global, NextProcess}, {Pid, Ref, first_key, CurrentFK, OriginalI});
                _Else ->
                    NewFK = lists:min(Filtered),
                    gen_server:cast({global, NextProcess}, {Pid, Ref, first_key, NewFK, OriginalI})
            end
    end,
    {noreply, S};

%% @spec handle_cast({Pid, Ref, last_key, CurrentLK, OriginalI}, S) -> {noreply, State}
%% @doc Cast that has been forwarded on to get a full snapshot of the system.
%%      We keep track of the last_key we've seen and if anything is more
%%      "lexicographically last" than it, we change our understanding of
%%      the last key. Once we get back around to our starting storageProcess
%%      we know the snapshot of the system and can return the last_key in the
%%      system. If there are NO keys in the system, we return the atom "empty".
handle_cast({Pid, Ref, last_key, CurrentLK, OriginalI}, S) ->
    NewLK = lists:max([ets:last(S#state.tabId), CurrentLK]),
    case S#state.i == OriginalI of 
        %% Back at the starting storage process
        true ->
            case NewLK == '$end_of_table' of
                true ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the last_key request" ++
                        " and found there were no keys.~n"),
                    Pid ! {Ref, result, empty};
                false ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the last_key request" ++
                        " and found the last_key to be ~p.~n", [CurrentLK]),
                    Pid ! {Ref, result, NewLK}
            end;
        %% still goin around the loop.
        false ->
            NextProcess = ?STORPROC(mod(S#state.i + 1, round(math:pow(2,S#state.m)))),
            gen_server:cast({global, NextProcess}, {Pid, Ref, last_key, NewLK, OriginalI})
    end,
    {noreply, S};


%% @spec handle_cast({Pid, Ref, num_keys, TotKeys, OriginalI}, S) -> {noreply, State}
%% @doc Cast that has been forwarded on to get a full snapshot of the system.
%%      We keep track of the number of keys we've seen and keep adding on
%%      the number of keys at each process. Once we get back to the original
%%      storageProcess, we know the snapshot of the system and can return the
%%      number of keys in the system.
handle_cast({Pid, Ref, num_keys, TotKeys, OriginalI}, S) ->
    case S#state.i == OriginalI of 
        %% Back at the starting storage process
        true ->
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the num_keys request" ++
                        " and found there were ~p keys.~n", [TotKeys]),
            Pid ! {Ref, result, TotKeys};
        %% still goin around the loop.
        false ->
            NewTotKeys = TotKeys + ets:info(S#state.tabId, size),
            NextProcess = ?STORPROC(mod(S#state.i + 1, round(math:pow(2,S#state.m)))),
            gen_server:cast({global, NextProcess}, {Pid, Ref, num_keys, NewTotKeys, OriginalI})
    end,
    {noreply, S};


handle_cast(_Something, S) ->
    {noreply, S}.


%%%%%%%%%%%%%%%%%%%%%%%%%% END ASYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%% CONTROLLER MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_info({Pid, Ref, store, Key, Value}, S) -> {noreply, State}
%% @doc Initial asynchronous request to store a value at a certain key on
%%      storageProcess with number Hash. The request could be forwarded on
%%      if this isnt the right storageProcess, or it could be the right node
%%      in which case we store the value in our storageProcess ETS table and
%%      then tell the backup storage process on the node ahead of us to store
%%      it too. (ONLY AFTER it has been stored on the backup storage process
%%      do we send the "stored" message back to the controller).
handle_info({Pid, Ref, store, Key, Value}, S) when is_pid(Pid) and 
                                                   is_reference(Ref) and
                                                   is_list(Key) ->
    Hash = hash(Key, S#state.m),
    case Hash == S#state.i of
        %% We could have gotten REALLY lucky and queried the correct
        %% process on the first try.
        true -> 
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a storage request" ++
                    " with hash key ~p, so inserting (~p,~p) into our table.~n", 
                    [Hash, Key, Value]),
            store(S#state.tabId, Key, Value),
            {state, _, _, _, _, AheadNodeNum, _, _} = sys:get_state({global, ?NODE(S#state.nodeNum)}),
            AheadNode = node(global:whereis_name(?NODE(AheadNodeNum))),
            gen_server:cast({?BSTORPROC(S#state.i), AheadNode},{store, Key, Value, Pid, Ref});

        %% OR not and we have to forward the request.
        false ->
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a storage request" ++
                    " with hash key ~p, so handing it over.~n", [Hash]),
            hand_over(Pid, Ref, store, Key, Value, Hash, S)
    end,
    {noreply, S};


%% @spec handle_info({Pid, Ref, retrieve, Key}, S) -> {noreply, State}
%% @doc Initial asynchronous request to retrieve a certain key on
%%      storageProcess with number Hash. The request could be forwarded on
%%      if this isnt the right storageProcess, or it could be the right node
%%      in which case we find the value in our storageProcess ETS table and
%%      send a message back to the controller with the key in that position.
handle_info({Pid, Ref, retrieve, Key}, S) when is_pid(Pid) and
                                               is_reference(Ref) ->
    Hash = hash(Key, S#state.m),
    case Hash == S#state.i of
        %% We could have gotten REALLY lucky and queried the correct
        %% process on the first try.
        true -> 
            Value = retrieve(S#state.tabId, Key),
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a retrieve request" ++
                    " with hash key ~p, and I found its value was ~p.~n", 
                    [Hash, Value]),
            Pid ! {Ref, retrieved, Value};
        %% OR not and we have to forward the request.
        false ->
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got a retrieve request" ++
                    " with hash key ~p, so handing it over.~n", [Hash]),
            hand_over(Pid, Ref, retrieve, Key, Hash, S)
    end,
    {noreply, S};


%% @spec handle_info({Pid, Ref, first_key}, S) -> {noreply, State}
%% @doc Initial asynchronous request to be forwarded on to get a full snapshot of the system.
%%      We keep track of the first_key we've seen and if anything is more
%%      "lexicographically first" than it, we change our understanding of
%%      the first key. Once we get back around to our starting storageProcess
%%      we know the snapshot of the system and can return the first_key in the
%%      system. If there are NO keys in the system, we return the atom "empty".
%%
%%      Or... If the system is just one process we can just return now.
handle_info({Pid, Ref, first_key}, S = #state{tabId = T, m = M, i = I}) 
                                when is_pid(Pid) and is_reference(Ref) ->
    CurrentFK = ets:first(T),
    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Initializing first_key query.~n"),
    case M == 0 of
        %% One Process
        true ->
            case CurrentFK == '$end_of_table' of
                true ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the first_key request" ++
                        " and found there were no keys.~n"),
                    Pid ! {Ref, result, empty};
                false ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the first_key request" ++
                        " and found the first_key to be ~p.~n", [CurrentFK]),
                    Pid ! {Ref, result, CurrentFK}
            end;

        %% More than one process, forward request around.
        false ->
            % Name ahead storage process using macro
            NextProcess = ?STORPROC(mod(I + 1, round(math:pow(2,M)))),
            gen_server:cast({global, NextProcess}, {Pid, Ref, first_key, CurrentFK, I})
    end,
    {noreply, S};

%% @spec handle_info({Pid, Ref, last_key}, S) -> {noreply, State}
%% @doc Initial asynchronous request to be forwarded on to get a full snapshot of the system.
%%      We keep track of the last_key we've seen and if anything is more
%%      "lexicographically last" than it, we change our understanding of
%%      the last key. Once we get back around to our starting storageProcess
%%      we know the snapshot of the system and can return the last_key in the
%%      system. If there are NO keys in the system, we return the atom "empty".
%%
%%      Or... If the system is just one process we can just return now.
handle_info({Pid, Ref, last_key}, S = #state{tabId = T, m = M, i = I}) 
                                when is_pid(Pid) and is_reference(Ref) ->
    CurrentLK = ets:last(T),
    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Initializing last_key query.~n"),
    case M == 0 of
        %% One Process
        true ->
            case CurrentLK == '$end_of_table' of
                true ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the last_key request" ++
                        " and found there were no keys.~n"),
                    Pid ! {Ref, result, empty};
                false ->
                    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the last_key request" ++
                            " and found the last_key to be ~p.~n", [CurrentLK]),
                    Pid ! {Ref, result, CurrentLK}
            end;

        %% More than one process, forward request around.
        false ->
            % Name ahead storage process using macro
            NextProcess = ?STORPROC(mod(I + 1, round(math:pow(2,M)))),
            gen_server:cast({global, NextProcess}, {Pid, Ref, last_key, CurrentLK, I})
    end,
    {noreply, S};

%% @spec handle_info({Pid, Ref, num_keys}, S) -> {noreply, State}
%% @doc Initial asynchronous request to be forwarded on to get a full snapshot of the system.
%%      We keep track of the number of keys we've seen and keep adding on
%%      the number of keys at each process. Once we get back to the original
%%      storageProcess, we know the snapshot of the system and can return the
%%      number of keys in the system.
%%
%%      Or... If the system is just one process we can just return now.
handle_info({Pid, Ref, num_keys}, S = #state{tabId = T, m = M, i = I}) 
                                when is_pid(Pid) and is_reference(Ref) ->
    TotKeys = ets:info(T, size),
    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Initializing num_keys query.~n"),
    case M == 0 of
        %% One Process
        true ->
            io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Finished the num_keys request" ++
                        " and found there were ~p keys.~n", [TotKeys]),
            Pid ! {Ref, result, TotKeys};

        %% More than one process, forward request around.
        false ->
            % Name ahead storage process using macro
            NextProcess = ?STORPROC(mod(I + 1, round(math:pow(2,M)))),
            gen_server:cast({global, NextProcess}, {Pid, Ref, num_keys, TotKeys, I})
    end,
    {noreply, S};


%% @spec handle_info({Pid, Ref, node_list}, S) -> {noreply, State}
%% @doc Asynchronous request to get a list of all nodes in our system.
%%      We can just look at the global registry and filter out all
%%      non-node processes.
handle_info({Pid, Ref, node_list}, S) when is_pid(Pid) and
                                           is_reference(Ref) ->
    NodeList = get_nodes(),
    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "node_list query of all nodes in our system ~p.~n", [NodeList]),
    Pid ! {Ref, result, NodeList},
    {noreply, S};

%% @spec handle_info({Pid, Ref, leave}, S) -> {noreply, State}
%% @doc Asynchronous request to leave. We just halt and the other nodes
%%      pick up the slack.
handle_info({Pid, Ref, leave}, S) when is_pid(Pid) and
                                       is_reference(Ref) ->
    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "About to leave the system.~n"),
    erlang:halt(),
    {noreply, S};

%%%%%%%%%%%%%%%%%%%%%%%%%% END CONTROLLER MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%% UNUSED STUFF AND EXTRA ERROR CATCHING %%%%%%%%%%%%%%%%%%%%%
% Catch
handle_info({'EXIT', _Port, _Reason}, State) ->
    {stop, normal, State};

handle_info(Msg, S) ->
    io:format(?PRNTSTR(S#state.nodeNum, S#state.i) ++ "Got unrecognized message, ~p.~n",
        [Msg]),
    {noreply, S}.

terminate(_Blah, S) ->
    ets:delete(S#state.tabId),
    ok.
%% Unused Callbacks
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Other Useful Functions
%%%============================================================================


%% @spec timestamp(Now) -> string()
%% @doc Generates a fancy looking timestamp, found on:
%%        http://erlang.2086793.n4.nabble.com/formatting-timestamps-td3594191.html
timestamp(Now) -> 
    {_, _, Micros} = Now, 
    {{YY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(Now), 
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w.~p", 
                  [YY, MM, DD, Hour, Min, Sec, Micros]).


%% The hash function
hash(String, M) ->
    lists:foldl(fun(X, Sum) -> X + Sum end, 0, String) rem round(math:pow(2,M)).


%% Hand over a message you your neighbor that is closest to the hash.
hand_over(Pid, Ref, store, Key, Value, Hash, S) ->
    I = S#state.i,
    M = S#state.m,
    NeighborName = ?STORPROC(closest_neighbor(M, I, Hash)),
    gen_server:cast({global, NeighborName},{Pid, Ref, store, Key, Value, Hash}).

hand_over(Pid, Ref, retrieve, Key, Hash, S) ->
    I = S#state.i,
    M = S#state.m,
    NeighborName = ?STORPROC(closest_neighbor(M, I, Hash)),
    gen_server:cast({global, NeighborName},{Pid, Ref, retrieve, Key, Hash}).



%%% Finding the nieghbor of I that is closest to K (it could be K if K is
%%% I's neighbor)
closest_neighbor(_M, I, I) ->
    I;

closest_neighbor(M, I, K) ->
    case I > K of
        true ->
            closest_neighbor_ahead(M, I, K, 0, I);
        false -> 
            closest_neighbor_behind(M, I, K, 0, I)
    end.


closest_neighbor_ahead(_M, _I, _K, _M, Last) ->
    Last;
closest_neighbor_ahead(M, I, K, J, Last) ->
    CurrentPos = round(I + math:pow(2,J)) rem round(math:pow(2,M)),
    case CurrentPos < Last of
        true -> 
            case CurrentPos =< K of
                true ->
                    closest_neighbor_behind(M, I, K, J + 1, CurrentPos);
                false ->
                    Last
            end;
        false ->
            closest_neighbor_ahead(M, I, K, J + 1, CurrentPos)
    end.

closest_neighbor_behind(_M, _I, _K, _M, Last) ->
    Last;

closest_neighbor_behind(M, I, K, J, Last) ->
    CurrentPos = round(I + math:pow(2,J)) rem round(math:pow(2,M)),
    %io:format("~p~n", [CurrentPos]),
    case (CurrentPos > K) or (CurrentPos < Last) of
        true ->
            Last;
        false ->
            closest_neighbor_behind(M, I, K, J + 1, CurrentPos)
    end.


%%% Get all node neighbors, returns a set.
get_neighbors(M, I) ->
    sets:from_list(
        lists:map(
            fun(K) -> (I + round(math:pow(2, K))) rem round(math:pow(2, M)) end, 
            lists:seq(0, M-1)
        )
    ).

%%% Storing and retrieving {key, value}s or values respectively
store(TabId, Key, Value) ->

    case ets:lookup(TabId, Key) of
        [] -> 
            ets:insert(TabId, {Key, Value}),
            no_value;
        [{Key, OldValue}] ->
            ets:insert(TabId, {Key, Value}),
            OldValue
    end.

retrieve(TabId, Key) ->
    case ets:lookup(TabId, Key) of
        [] ->
            no_value;
        [{Key, Value}] ->
            Value
    end.


%% Filtering nodes for node_list query
filter(X) ->
    case X of 
        {node, _NodeNum} ->
            true;
        _Else ->
            false
    end.

%% get a list of all nodes in the system.
get_nodes() ->
    global:sync(),
    lists:sort(lists:map(
        fun({node, NodeNum}) -> NodeNum end, 
        lists:filter(fun(X) -> filter(X) end, global:registered_names())
        )).

% Calculate Modulo
mod(X,Y) when X > 0 -> X rem Y;
mod(X,Y) when X < 0 -> Y + X rem Y;
mod(0,_Y) -> 0.