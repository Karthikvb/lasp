%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(lasp_register_fsm).
-author('Christopher Meiklejohn <cmeiklejohn@basho.com>').

-behaviour(gen_fsm).

-include("lasp.hrl").

%% API
-export([start_link/4,
         register/2]).

%% Callbacks
-export([init/1,
         code_change/4,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4,
         terminate/3]).

%% States
-export([prepare/2,
         execute/2,
         waiting/2]).

-record(state, {preflist,
                req_id,
                coordinator,
                from,
                module,
                file,
                responses}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqId, From, Group, Pid) ->
    gen_fsm:start_link(?MODULE, [ReqId, From, Group, Pid], []).

%% @doc Register a program.
register(Module, File) ->
    ReqId = ?REQID(),
    _ = lasp_register_fsm_sup:start_child([ReqId, self(), Module, File]),
    {ok, ReqId}.

%%%===================================================================
%%% Callbacks
%%%===================================================================

handle_info(_Info, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop, badmsg, StateData}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% States
%%%===================================================================

%% @doc Initialize the request.
init([ReqId, From, Module, File]) ->
    lager:info("Register FSM initialized!"),
    State = #state{preflist=undefined,
                   req_id=ReqId,
                   coordinator=node(),
                   from=From,
                   module=Module,
                   file=File,
                   responses=0},
    {ok, prepare, State, 0}.

%% @doc Prepare request by retrieving the preflist.
prepare(timeout, #state{module=Module}=State) ->
    Preflist = lasp_vnode:preflist(?PROGRAM_N, Module, ?VNODE),
    Preflist2 = [{Index, Node} || {{Index, Node}, _Type} <- Preflist],
    lager:info("Register FSM preflist2: ~p", [Preflist2]),
    {next_state, execute, State#state{preflist=Preflist2}, 0}.

%% @doc Execute the request.
execute(timeout, #state{preflist=Preflist,
                        req_id=ReqId,
                        coordinator=Coordinator,
                        module=Module,
                        file=File}=State) ->
    lasp_vnode:register(Preflist, {ReqId, Coordinator}, Module, File, []),
    {next_state, waiting, State}.

%% @doc Attempt to write to every single node responsible for this
%%      group.
waiting({ok, ReqId}, #state{responses=Responses0, from=From}=State0) ->
    lager:info("Response received!"),
    Responses = Responses0 + 1,
    State = State0#state{responses=Responses},
    case Responses =:= ?PROGRAM_W of
        true ->
            From ! {ReqId, ok},
            {stop, normal, State};
        false ->
            {next_state, waiting, State}
    end;
waiting(Message, State) ->
    lager:info("Unhandled message received: ~p", [Message]),
    {next_state, waiting, State}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================
