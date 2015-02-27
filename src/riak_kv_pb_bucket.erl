%% -------------------------------------------------------------------
%%
%% riak_kv_pb_bucket: Expose KV bucket functionality to Protocol Buffers
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc <p>The Bucket PB service for Riak KV. This covers the
%% following request messages in the original protocol:</p>
%%
%% <pre>
%% 15 - RpbListBucketsReq
%% 17 - RpbListKeysReq
%% </pre>
%%
%% <p>This service produces the following responses:</p>
%%
%% <pre>
%% 16 - RpbListBucketsResp
%% 18 - RpbListKeysResp{1,}
%% </pre>
%%
%% <p>The semantics are unchanged from their original
%% implementations.</p>
%% @end

-module(riak_kv_pb_bucket).

-type optional(A) :: A | undefined.
-include_lib("riak_pb/include/riak_kv_pb.hrl").

-behaviour(riak_api_pb_service).

-export([init/0,
         decode/2,
         encode/1,
         process/2,
         process_stream/3,
         bucket_type/2,
         maybe_create_bucket_type/2]).

-record(state, {client,    % local client
                req,       % current request (for multi-message requests like list keys)
                req_ctx}). % context to go along with request (partial results, request ids etc)

%% @doc init/0 callback. Returns the service internal start
%% state.
-spec init() -> any().
init() ->
    {ok, C} = riak:local_client(),
    #state{client=C}.

%% @doc decode/2 callback. Decodes an incoming message.
decode(Code, Bin) ->
    Msg = riak_pb_codec:decode(Code, Bin),
    case Msg of
        rpblistbucketsreq ->
            %% backwards compat
            {ok, Msg, {"riak_kv.list_buckets", <<"default">>}};
        #rpblistbucketsreq{} ->
            Type = case Msg#rpblistbucketsreq.type of
                       undefined ->
                           <<"default">>;
                       T ->
                           T
                   end,
            {ok, Msg, {"riak_kv.list_buckets", Type}};
        #rpblistkeysreq{} ->
            Type = case Msg#rpblistkeysreq.type of
                       undefined ->
                           <<"default">>;
                       T ->
                           T
                   end,
            {ok, Msg, {"riak_kv.list_keys", {Type,
                                                Msg#rpblistkeysreq.bucket}}}
    end.

%% @doc encode/1 callback. Encodes an outgoing response message.
encode(Message) ->
    {ok, riak_pb_codec:encode(Message)}.

%% @doc process/2 callback. Handles an incoming request message.
process(#rpblistbucketsreq{type = Type, timeout=T, stream=S}=Req, State) ->
    case check_bucket_type(Type) of
        {ok, GoodType} ->
            do_list_buckets(GoodType, T, S, Req, State);
        error ->
            {error, {format, "No bucket-type named '~s'", [Type]}, State}
    end;

%% this should remain for backwards compatibility
process(rpblistbucketsreq, State) ->
    process(#rpblistbucketsreq{}, State);

%% Start streaming in list keys
process(#rpblistkeysreq{type = Type, bucket=B,timeout=T}=Req, #state{client=C} = State) ->
    %% stream_list_keys results will be processed by process_stream/3
    case check_bucket_type(Type) of
        {ok, GoodType} ->
            Bucket = maybe_create_bucket_type(GoodType, B),
	    {ok, ReqId} = C:stream_list_keys(Bucket, T),
	    {reply, {stream, ReqId}, State#state{req = Req, req_ctx = ReqId}};
        error ->
            {error, {format, "No bucket-type named '~s'", [Type]}, State}
    end.

%% @doc process_stream/3 callback. Handles streaming keys messages and
%% streaming buckets.
process_stream({ReqId, done}, ReqId,
               State=#state{req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    {done, #rpblistkeysresp{done = 1}, State};
process_stream({ReqId, From, {keys, []}}, ReqId,
               State=#state{req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    _ = riak_kv_keys_fsm:ack_keys(From),
    {ignore, State};
process_stream({ReqId, {keys, []}}, ReqId,
               State=#state{req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    {ignore, State};
process_stream({ReqId, From, {keys, Keys}}, ReqId,
               State=#state{req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    _ = riak_kv_keys_fsm:ack_keys(From),
    {reply, #rpblistkeysresp{keys = Keys}, State};
process_stream({ReqId, {keys, Keys}}, ReqId,
               State=#state{req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    {reply, #rpblistkeysresp{keys = Keys}, State};
process_stream({ReqId, {error, Error}}, ReqId,
               State=#state{ req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    {error, {format, Error}, State#state{req = undefined, req_ctx = undefined}};
process_stream({ReqId, Error}, ReqId,
               State=#state{ req=#rpblistkeysreq{}, req_ctx=ReqId}) ->
    {error, {format, Error}, State#state{req = undefined, req_ctx = undefined}};
%% list buckets clauses.
process_stream({ReqId, done}, ReqId,
               State=#state{req=#rpblistbucketsreq{}, req_ctx=ReqId}) ->
    {done, #rpblistbucketsresp{done = 1}, State};
process_stream({ReqId, {buckets_stream, []}}, ReqId,
               State=#state{req=#rpblistbucketsreq{}, req_ctx=ReqId}) ->
    {ignore, State};
process_stream({ReqId, {buckets_stream, Buckets}}, ReqId,
               State=#state{req=#rpblistbucketsreq{}, req_ctx=ReqId}) ->
    {reply, #rpblistbucketsresp{buckets = Buckets}, State};
process_stream({ReqId, {error, Error}}, ReqId,
               State=#state{ req=#rpblistbucketsreq{}, req_ctx=ReqId}) ->
    {error, {format, Error}, State#state{req = undefined, req_ctx = undefined}};
process_stream({ReqId, Error}, ReqId,
               State=#state{ req=#rpblistbucketsreq{}, req_ctx=ReqId}) ->
    {error, {format, Error}, State#state{req = undefined, req_ctx = undefined}}.


-spec do_list_buckets(binary(), optional(pos_integer()), optional(boolean()), #rpblistbucketsreq{}, #state{}) ->
                             {reply, tuple(), #state{}} |
                             {error, {format, iodata()}, #state{}}.
do_list_buckets(Type, Timeout, true, Req, #state{client=C}=State) ->
    {ok, ReqId} = C:stream_list_buckets(none, Timeout, Type),
    {reply, {stream, ReqId}, State#state{req = Req, req_ctx = ReqId}};
do_list_buckets(Type, Timeout, _Stream, _Req, #state{client=C}=State) ->
    case C:list_buckets(none, Timeout, Type) of
        {ok, Buckets} ->
            {reply, #rpblistbucketsresp{buckets = Buckets}, State};
        {error, Reason} ->
            {error, {format, Reason}, State}
    end.

-spec check_bucket_type(optional(binary())) -> {ok, binary()} | error.
check_bucket_type(undefined) -> {ok, <<"default">>};
check_bucket_type(<<"default">>) -> {ok, <<"default">>};
check_bucket_type(Type) ->
    case riak_core_bucket_type:get(Type) of
        Props when is_list(Props) ->
            {ok, Type};
        _ ->
            error
    end.

-spec maybe_create_bucket_type(binary()|undefined, binary()) -> riak_core_bucket:bucket().
maybe_create_bucket_type(<<"default">>, Bucket) ->
    Bucket;
maybe_create_bucket_type(undefined, Bucket) ->
    Bucket;
maybe_create_bucket_type(Type, Bucket) when is_binary(Type) ->
    {Type, Bucket}.

%% always construct {Type, Bucket} tuple, filling in default type if needed
-spec bucket_type(binary()|undefined, binary()) -> riak_core_bucket:bucket().
bucket_type(undefined, B) ->
    {<<"default">>, B};
bucket_type(T, B) ->
    {T, B}.
