%%% -------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and Patrick Lu
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc A Generic Server implementation of a controller that talks to 
%%%		 philosophers, telling them to become hungry, stop eating and
%%%      leave with nice commands (and receive their output and
%%%		 formatting that response nicely). It also supplies some extr
%%%		 info commands such as get_state, get_neighbors, and list_forks
%%% @end
%%%--------------------------------------------------------------------

-module(controller).
-behavior(gen_server).

%% External exports
-export([start/1,
		 store/3,
		 retrieve/2,
		 first_key/1,
		 last_key/1,
		 num_keys/1,
		 node_list/1,
		 leave/1,
		 getSPstate/1,
		 getNodestate/1]).

%% gen_server callbacks
-export([init/1, 
		 handle_call/3, 
		 handle_cast/2, 
		 handle_info/2, 
		 code_change/3, 
		 terminate/2]).

-define(STORPROC(X), list_to_atom("storageProcess" ++ integer_to_list(X))).
-define(BSTORPROC(X), list_to_atom("backupStorageProcess" ++ integer_to_list(X))).
-define(PRNTSTR, timestamp (now()) ++ ": ").
-define(CTRLID, controller).
-define(MYNAME, random_atom(10)).
-record(state, {m,
				storeRefs,
				retrieveRefs,
				first_keyRefs,
				last_keyRefs,
				num_keysRefs,
				node_listRefs
				}).


%%%============================================================================
%%% API
%%%============================================================================

start(Node) when is_atom(Node) ->
	os:cmd("epmd -daemon"),
	net_kernel:start([?MYNAME, shortnames]),
	case net_adm:ping(Node) of
		pong ->
			gen_server:start({local, ?CTRLID}, controller, {}, []);
		pang ->
			io:format("Give me a valid node to connect to...~n"),
			erlang:halt()
	end;

start([Node]) when is_list(Node) ->
	os:cmd("epmd -daemon"),
	net_kernel:start([?MYNAME, shortnames]),
	case net_adm:ping(list_to_atom(Node)) of
		pong ->
			gen_server:start({local, ?CTRLID}, controller, {}, []);
		pang ->
			io:format("Give me a valid node to connect to...~n"),
			erlang:halt()
	end.
%% @spec become_hungry(Node) -> ok.
%% @doc Casts our server to tell the philosopher to become hungry (and 
%%		store the hungry reference).
store(Key, Value, StorageProcessNumber) ->
	gen_server:cast(controller, {store, Key, Value, StorageProcessNumber}).

retrieve(Key, StorageProcessNumber) ->
	gen_server:cast(controller, {retrieve, Key, StorageProcessNumber}).

first_key(StorageProcessNumber) ->
	gen_server:cast(controller, {first_key, StorageProcessNumber}).

last_key(StorageProcessNumber) ->
	gen_server:cast(controller, {last_key, StorageProcessNumber}).

num_keys(StorageProcessNumber) ->
	gen_server:cast(controller, {num_keys, StorageProcessNumber}).

node_list(StorageProcessNumber) ->
	gen_server:cast(controller, {node_list, StorageProcessNumber}).

leave(StorageProcessNumber) ->
	global:send(?STORPROC(StorageProcessNumber), {self(), make_ref(), leave}).

getSPstate(SPN) ->
	try {state, M, I, TabId, NodeNum} = sys:get_state({global, ?STORPROC(SPN)}),
		io:format("The State of Storage Process ~p is...~n"
			++ "M: ~p~n"
			++ "I: ~p~n"
			++ "ETS Table Id: ~p~n"
			++ "Node Number: ~p~n", [SPN, M, I, TabId, NodeNum])
	catch
		_Error:_Reason ->
			io:format("That wasn't a valid Storage Process. Make sure you actually have that storage process...~n")
	end.


getNodestate(NodeNum) ->
	try {state,
	 M,
     NodeNum,
     Storage_processes,
     Bstorage_processes,
     AheadNodeNum,
     BehindNode,
     BehindNodeNum} = sys:get_state({global, {node, NodeNum}}),
     io:format("The State of Node ~p is...~n"
			  ++ "M: ~p~n" 
			  ++ "Storage Processes: ~p~n"
			  ++ "Backup Storage Processes: ~p~n"
			  ++ "Ahead Node Number: ~p~n"
			  ++ "Behind Node Name: ~p~n"
			  ++ "Behind Node Number: ~p~n", [NodeNum, M, Storage_processes, Bstorage_processes, AheadNodeNum, BehindNode, BehindNodeNum])
    catch
    	_Error:_Reason ->
    		io:format("That wasn't a valid Node. Try getting the node_list first.~n")
    end.

%%%============================================================================
%%% GenServer Callbacks (For the rest of the code)
%%%============================================================================

init(_Args) ->
	global:sync(),
	{ok, #state{storeRefs = dict:new(),
				retrieveRefs = dict:new(),
				first_keyRefs = dict:new(),
				last_keyRefs = dict:new(),
				num_keysRefs = dict:new(),
				node_listRefs = dict:new()
				}}.

handle_cast({store, Key, Value, StorageProcessNumber}, S) ->
	case is_list(Key) of
		true ->
			Pid = self(),
			Ref = make_ref(),
			NewStoreRefs = dict:store(Ref, {StorageProcessNumber, Value, Key}, S#state.storeRefs),
			try global:send(?STORPROC(StorageProcessNumber), {Pid, Ref, store, Key, Value}),
				{noreply, S#state{storeRefs = NewStoreRefs}}
			catch
				_Error:_Reason ->
					io:format("You didn't give a valid Storage Process Number (Or the key-value store system went down in which case you need to start it up again and connect by typing \"net_adm:ping(Node)\" or just restarting the controller).~n"),
					{noreply, S}
			end;
		false ->
			io:format("Your key must be a string!~n"),
			{noreply, S}
	end;


handle_cast({retrieve, Key, StorageProcessNumber}, S) ->
	case is_list(Key) of
		true ->
			Pid = self(),
			Ref = make_ref(),
			NewRetrieveRefs = dict:store(Ref, {StorageProcessNumber, Key}, S#state.retrieveRefs),
			try global:send(?STORPROC(StorageProcessNumber), {Pid, Ref, retrieve, Key}),
				{noreply, S#state{retrieveRefs = NewRetrieveRefs}}
			catch
				_Error:_Reason ->
					io:format("You didn't give a valid Storage Process Number (Or the key-value store system went down in which case you need to start it up again and connect by typing \"net_adm:ping(Node)\" or just restarting the controller).~n"),
					{noreply, S}
			end;
		false ->
			io:format("Your key must be a string!~n"),
			{noreply, S}
	end;


handle_cast({first_key, StorageProcessNumber}, S) ->
	Pid = self(),
	Ref = make_ref(),
	NewFirstKeyRefs = dict:store(Ref, StorageProcessNumber, S#state.first_keyRefs),
	try global:send(?STORPROC(StorageProcessNumber), {Pid, Ref, first_key}),
		{noreply, S#state{first_keyRefs = NewFirstKeyRefs}}
	catch
		_Error:_Reason ->
			io:format("You didn't give a valid Storage Process Number (Or the key-value store system went down in which case you need to start it up again and connect by typing \"net_adm:ping(Node)\" or just restarting the controller).~n"),
			{noreply, S}
	end;

handle_cast({last_key, StorageProcessNumber}, S) ->
	Pid = self(),
	Ref = make_ref(),
	NewLastKeyRefs = dict:store(Ref, StorageProcessNumber, S#state.last_keyRefs),
	try global:send(?STORPROC(StorageProcessNumber), {Pid, Ref, last_key}),
		{noreply, S#state{last_keyRefs = NewLastKeyRefs}}
	catch
		_Error:_Reason ->
			io:format("You didn't give a valid Storage Process Number (Or the key-value store system went down in which case you need to start it up again and connect by typing \"net_adm:ping(Node)\" or just restarting the controller).~n"),
			{noreply, S}
	end;

handle_cast({num_keys, StorageProcessNumber}, S) ->
	Pid = self(),
	Ref = make_ref(),
	NewNumKeysRefs = dict:store(Ref, StorageProcessNumber, S#state.num_keysRefs),
	try global:send(?STORPROC(StorageProcessNumber), {Pid, Ref, num_keys}),
		{noreply, S#state{num_keysRefs = NewNumKeysRefs}}
	catch
		_Error:_Reason ->
			io:format("You didn't give a valid Storage Process Number (Or the key-value store system went down in which case you need to start it up again and connect by typing \"net_adm:ping(Node)\" or just restarting the controller).~n"),
			{noreply, S}
	end;

handle_cast({node_list, StorageProcessNumber}, S) ->
	Pid = self(),
	Ref = make_ref(),
	NewNodeListRefs = dict:store(Ref, StorageProcessNumber, S#state.node_listRefs),
	try global:send(?STORPROC(StorageProcessNumber), {Pid, Ref, node_list}),
		{noreply, S#state{node_listRefs = NewNodeListRefs}}
	catch
		_Error:_Reason ->
			io:format("You didn't give a valid Storage Process Number (Or the key-value store system went down in which case you need to start it up again and connect by typing \"net_adm:ping(Node)\" or just restarting the controller).~n"),
			{noreply, S}
	end.


%% ---------------------------------------------------------------------------

handle_info({Ref, stored, OldValue}, S) ->
	{StorageProcessNumber, Value, Key} = dict:fetch(Ref, S#state.storeRefs),
	NewStoreRefs = dict:erase(Ref, S#state.storeRefs),
	case OldValue == no_value of
		true ->
			io:format(?PRNTSTR ++ "[Store Query to Storage Process ~p] Sucessfully stored value (~p) at key ~p and there was no previously stored value there.~n", [StorageProcessNumber, Value, Key]);
		false ->
			io:format(?PRNTSTR ++ "[Store Query to Storage Process ~p] Sucessfully stored value (~p) at key ~p and the previously stored value at that key was ~p.~n", [StorageProcessNumber, Value, Key, OldValue])
	end,
	{noreply, S#state{storeRefs = NewStoreRefs}};


handle_info({Ref, retrieved, Value}, S) ->
	{StorageProcessNumber, Key} = dict:fetch(Ref, S#state.retrieveRefs),
	NewRetrieveRefs = dict:erase(Ref, S#state.retrieveRefs),
	case Value == no_value of
		true ->
			io:format(?PRNTSTR ++ "[Retrieve Query to Storage Process ~p] There was no stored value at key ~p.~n", [StorageProcessNumber, Key]);
		false ->
			io:format(?PRNTSTR ++ "[Retrieve Query to Storage Process ~p] The value (~p) was stored at key ~p.~n", [StorageProcessNumber, Value, Key])
	end,
	{noreply, S#state{retrieveRefs = NewRetrieveRefs}};


handle_info({Ref, result, Result}, S)->
	case dict:is_key(Ref, S#state.first_keyRefs) of
		true ->
			StorageProcessNumber = dict:fetch(Ref, S#state.first_keyRefs),
			NewFirstKeyRefs = dict:erase(Ref, S#state.first_keyRefs),
			case Result == empty of
				true ->
					io:format(?PRNTSTR ++ "[First_Key Query to Storage Process ~p] There are no key-value pairs in the system.~n", [StorageProcessNumber]);
				false ->
					io:format(?PRNTSTR ++ "[First_Key Query to Storage Process ~p] The first key (lecicographically) in the system is ~p.~n", [StorageProcessNumber, Result])
			end,
			{noreply, S#state{first_keyRefs = NewFirstKeyRefs}};

		false ->
			case dict:is_key(Ref, S#state.last_keyRefs) of
				true ->
					StorageProcessNumber = dict:fetch(Ref, S#state.last_keyRefs),
					NewLastKeyRefs = dict:erase(Ref, S#state.last_keyRefs),
					case Result == empty of
						true ->
							io:format(?PRNTSTR ++ "[Last_Key Query to Storage Process ~p] There are no key-value pairs in the system.~n", [StorageProcessNumber]);
						false ->
							io:format(?PRNTSTR ++ "[Last_Key Query to Storage Process ~p] The last key (lecicographically) in the system is ~p.~n", [StorageProcessNumber, Result])
					end,
					{noreply, S#state{last_keyRefs = NewLastKeyRefs}};

				false ->
					case dict:is_key(Ref, S#state.num_keysRefs) of 
						true ->
							StorageProcessNumber = dict:fetch(Ref, S#state.num_keysRefs),
							NewNumKeysRefs = dict:erase(Ref, S#state.num_keysRefs),
							io:format(?PRNTSTR ++ "[Num_Keys Query to Storage Process ~p] There are ~p keys for which values are stored in the system.~n", [StorageProcessNumber, Result]),
							{noreply, S#state{num_keysRefs = NewNumKeysRefs}};
						false ->
							case dict:is_key(Ref, S#state.node_listRefs) of 
								true ->
									StorageProcessNumber = dict:fetch(Ref, S#state.node_listRefs),
									NewNodeListRefs = dict:erase(Ref, S#state.node_listRefs),
									io:format(?PRNTSTR ++ "[Node_List Query to Storage Process ~p] Nodes ~p are in the system.~n", [StorageProcessNumber, Result]),
									{noreply, S#state{node_listRefs = NewNodeListRefs}};
								false ->
									{noreply, S}
							end
					end
			end
	end;


handle_info(_Else, S) ->
	{noreply, S}.


%%%% UNUSED CALLBACKS

handle_call(_, _, S) ->
	{reply, ok, S}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    io:format(timestamp (now()) ++ ": terminate reason: ~p~n", [_Reason]).



%%%% OTHER STUFF


random_atom(Len) ->
    Chrs = list_to_tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
    ChrsSize = size(Chrs),
    {A1, A2, A3} = now(),
    random:seed(A1,A2,A3),
    F = fun(_, R) -> [element(random:uniform(ChrsSize), Chrs) | R] end,
    List = lists:foldl(F, "", lists:seq(1, Len)),
    list_to_atom(List).

%% @spec timestamp(Now) -> string()
%% @doc Generates a fancy looking timestamp, found on:
%%		http://erlang.2086793.n4.nabble.com/formatting-timestamps-td3594191.html
timestamp(Now) -> 
    {_, _, Micros} = Now, 
    {{YY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(Now), 
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w.~p", 
                  [YY, MM, DD, Hour, Min, Sec, Micros]).