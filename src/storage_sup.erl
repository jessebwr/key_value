%%% ---------------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and David Scott
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc Storage supervisor. Starts storage processes and kills them. Yea.
%%% @end
%%%----------------------------------------------------------------------------

-module(storage_sup).
-behavior(supervisor).

%% API Exports
-export([start_link/0,
		 start_storage_process/4,
		 terminate_storage_process/1]).

%% Supervisor Callback Exports
-export([init/1]).


%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------

start_link() ->
	% We are globally registering the supervisor as the tuple {supervisor, NodeNum}
	supervisor:start_link({local, supervisor}, ?MODULE, []).

start_storage_process(NodeNum, M, I, TabId) ->
	supervisor:start_child(supervisor, [NodeNum, M, I, TabId]).

terminate_storage_process(ChildId) ->
	exit(ChildId,moo).


%%% Callbacks
init(_Args) ->
	Element =  {storage_process, {storage_process, start_link, []},
				temporary, brutal_kill, worker, [storage_process]},
	Children = [Element],
	RestartStrategy = {simple_one_for_one, 2, 10},
	{ok, {RestartStrategy, Children}}.
