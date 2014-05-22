%%% ---------------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and Patrick
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc Very Very Very basic backup generic server for a storage process
%%% @end
%%%----------------------------------------------------------------------------

-module(bstorage_process).
-behavior(gen_server).

%% External exports
-export([start_link/3]).

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
-define(PRNTSTR(X), timestamp(now()) ++ " [BackupStorageProcess " ++ integer_to_list(X) ++ "]: ").

-record(state, {m,
                i,
                tabId}).

%%%============================================================================
%%% API
%%%============================================================================

start_link(M, I, TabId) ->
    %io:format(?PRNTSTR(I) ++ "Starting Backup Storage Process.~n"),
    % We are registering the storage process as the tuple {storproc, I}
    gen_server:start_link({local, ?BSTORPROC(I)}, ?MODULE, {M, I, TabId}, []).

%%%============================================================================
%%% GenServer Callbacks
%%%============================================================================

%% Just initialization
init({M, I, TabId}) ->
    process_flag(trap_exit, true),
    {ok, #state{m = M, i = I, tabId = TabId}}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%% SYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_call(getTab, _From, S) -> {reply, list(), S};
%% @doc Grab the ETS table from this process.
handle_call(getTab, _From, S) ->
    {reply, ets:tab2list(S#state.tabId), S};

handle_call(_Something, _From, S) ->
    {reply, idkyet, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%% END SYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%% ASYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_cast({store, Key, Value, Pid, Ref}, S) -> {noreply, State}
%% @doc Cast from real storage process to store the key-value pair as a backup.
%%      Then we can tell the controller it has been stored.
handle_cast({store, Key, Value, Pid, Ref}, S) when is_list(Key) ->
    io:format(?PRNTSTR(S#state.i) ++ "Backup Storing (~p, ~p) in our table.~n", [Key, Value]),
    OldValue = store(S#state.tabId, Key, Value),
    Pid ! {Ref, stored, OldValue},
    {noreply, S};

handle_cast(leave, S) ->
    {stop, normal, S};

handle_cast(_Something, S) ->
    {noreply, S}.


%%%%%%%%%%%%%%%%%%%%%%%%%% END ASYNCRHONOUS MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%### OTHER MESSAGES %%%##%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Catch
handle_info({'EXIT', _Port, _Reason}, State) ->
    {stop, normal, State};

handle_info(Msg, S) ->
    io:format(?PRNTSTR(S#state.i) ++ "Got unrecognized message, ~p.~n",
        [Msg]),
    {noreply, S}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%% END OTHER MESSAGES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%% UNUSED STUFF AND EXTRA ERROR CATCHING %%%%%%%%%%%%%%%%%%%%%

terminate(normal, S) ->
    ets:delete(S#state.tabId),
    ok;
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