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

-module(lasp_bind_to_fsm).
-author('Christopher Meiklejohn <cmeiklejohn@basho.com>').

-behaviour(gen_fsm).

-include("lasp.hrl").

%% API
-export([start_link/4,
         bind_to/2]).

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
         waiting/2,
         waiting_n/2,
         finalize/2]).

-record(state, {preflist,
                req_id,
                coordinator,
                from,
                id,
                their_id,
                num_responses,
                replies}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqId, From, Id, TheirId) ->
    gen_fsm:start_link(?MODULE, [ReqId, From, Id, TheirId], []).

%% @doc Bind a variable.
bind_to(Id, TheirId) ->
    ReqId = ?REQID(),
    _ = lasp_bind_to_fsm_sup:start_child([ReqId, self(), Id, TheirId]),
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
init([ReqId, From, Id, TheirId]) ->
    State = #state{preflist=undefined,
                   req_id=ReqId,
                   coordinator=node(),
                   from=From,
                   id=Id,
                   their_id=TheirId,
                   num_responses=0,
                   replies=[]},
    {ok, prepare, State, 0}.

%% @doc Prepare request by retrieving the preflist.
prepare(timeout, #state{id=Id}=State) ->
    Preflist = lasp_vnode:preflist(?N, Id, ?VNODE),
    Preflist2 = [{Index, Node} || {{Index, Node}, _Type} <- Preflist],
    {next_state, execute, State#state{preflist=Preflist2}, 0}.

%% @doc Execute the request.
execute(timeout, #state{preflist=Preflist,
                        req_id=ReqId,
                        id=Id,
                        their_id=TheirId,
                        coordinator=Coordinator}=State) ->
    lasp_vnode:bind_to(Preflist, {ReqId, Coordinator}, Id, TheirId),
    {next_state, waiting, State}.

waiting({ok, _ReqId, Reply},
        #state{from=From,
               req_id=ReqId,
               num_responses=NumResponses0,
               replies=Replies0}=State0) ->
    NumResponses = NumResponses0 + 1,
    Replies = [Reply|Replies0],
    State = State0#state{num_responses=NumResponses, replies=Replies},

    case NumResponses =:= ?R of
        true ->
            From ! {ReqId, ok, Reply},

            case NumResponses =:= ?N of
                true ->
                    {next_state, finalize, State, 0};
                false ->
                    {next_state, waiting_n, State}
            end;
        false ->
            {next_state, waiting, State}
    end.

waiting_n({ok, _ReqId, Reply},
        #state{num_responses=NumResponses0,
               replies=Replies0}=State0) ->
    NumResponses = NumResponses0 + 1,
    Replies = [Reply|Replies0],
    State = State0#state{num_responses=NumResponses, replies=Replies},

    case NumResponses =:= ?N of
        true ->
            {next_state, finalize, State, 0};
        false ->
            {next_state, waiting_n, State}
    end.

% finalize({ok, _ReqId, _Reply}, State) ->
%     %% Ignore additional replies, if they happen to come in late.
%     {stop, normal, State};

finalize(timeout, State) ->
    {stop, normal, State}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================
