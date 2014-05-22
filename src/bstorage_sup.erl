%%% ---------------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and David Scott
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc Storage supervisor. Starts backup storage processes and kills them.
%%%			yea.
%%% @end
%%%----------------------------------------------------------------------------

-module(bstorage_sup).
-behavior(supervisor).

%% API Exports
-export([start_link/0,
		 start_bstorage_process/3,
		 terminate_bstorage_process/1]).

%% Supervisor Callback Exports
-export([init/1]).


%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------

start_link() ->
	% We are globally registering the supervisor as the tuple {supervisor, NodeNum}
	supervisor:start_link({local, bsupervisor}, ?MODULE, []).

start_bstorage_process(M, I, TabId) ->
	supervisor:start_child(bsupervisor, [M, I, TabId]).

terminate_bstorage_process(ChildId) ->
	exit(whereis(ChildId),moo).

%%% Callbacks
init(_Args) ->
	Element =  {bstorage_process, {bstorage_process, start_link, []},
				temporary, brutal_kill, worker, [bstorage_process]},
	Children = [Element],
	RestartStrategy = {simple_one_for_one, 2, 10},
	{ok, {RestartStrategy, Children}}.
