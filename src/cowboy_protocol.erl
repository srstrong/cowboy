%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% @doc HTTP protocol handler.
%%
%% The available options are:
%% <dl>
%%  <dt>dispatch</dt><dd>The dispatch list for this protocol.</dd>
%%  <dt>max_empty_lines</dt><dd>Max number of empty lines before a request.
%%   Defaults to 5.</dd>
%%  <dt>timeout</dt><dd>Time in milliseconds before an idle
%%   connection is closed. Defaults to 5000 milliseconds.</dd>
%%  <dt>urldecode</dt><dd>Function and options argument to use when decoding
%%   URL encoded strings. Defaults to `{fun cowboy_http:urldecode/2, crash}'.
%%   </dd>
%% </dl>
%%
%% Note that there is no need to monitor these processes when using Cowboy as
%% an application as it already supervises them under the listener supervisor.
%%
%% @see cowboy_dispatcher
%% @see cowboy_http_handler
-module(cowboy_protocol).

%% API.
-export([start_link/4]).

%% Internal.
-export([init/4]).
-export([parse_request/1]).
-export([handler_loop/3]).

-type onrequest_fun() :: fun((Req) -> Req).
-type onresponse_fun() ::
	fun((cowboy_http:status(), cowboy_http:headers(), Req) -> Req).

-export_type([onrequest_fun/0]).
-export_type([onresponse_fun/0]).

-record(state, {
	listener :: pid(),
	socket :: inet:socket(),
	transport :: module(),
	dispatch :: cowboy_dispatcher:dispatch_rules(),
	handler :: {module(), any()},
	onrequest :: undefined | onrequest_fun(),
	onresponse = undefined :: undefined | onresponse_fun(),
	urldecode :: {fun((binary(), T) -> binary()), T},
	req_empty_lines = 0 :: integer(),
	max_empty_lines :: integer(),
	req_keepalive = 1 :: integer(),
	max_keepalive :: integer(),
	max_request_line_length :: integer(),
	max_header_name_length :: integer(),
	max_header_value_length :: integer(),
	timeout :: timeout(),
	buffer = <<>> :: binary(),
	host_tokens = undefined :: undefined | cowboy_dispatcher:tokens(),
	path_tokens = undefined :: undefined | '*' | cowboy_dispatcher:tokens(),
	hibernate = false :: boolean(),
	loop_timeout = infinity :: timeout(),
	loop_timeout_ref :: undefined | reference()
}).

%% API.

%% @doc Start an HTTP protocol process.
-spec start_link(pid(), inet:socket(), module(), any()) -> {ok, pid()}.
start_link(ListenerPid, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [ListenerPid, Socket, Transport, Opts]),
	{ok, Pid}.

%% Internal.

%% @doc Faster alternative to proplists:get_value/3.
%% @private
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.

%% @private
-spec init(pid(), inet:socket(), module(), any()) -> ok.
init(ListenerPid, Socket, Transport, Opts) ->
	Dispatch = get_value(dispatch, Opts, []),
	MaxEmptyLines = get_value(max_empty_lines, Opts, 5),
	MaxKeepalive = get_value(max_keepalive, Opts, infinity),
	MaxRequestLineLength = get_value(max_request_line_length, Opts, 4096),
	MaxHeaderNameLength = get_value(max_header_name_length, Opts, 64),
	MaxHeaderValueLength = get_value(max_header_value_length, Opts, 4096),
	OnRequest = get_value(onrequest, Opts, undefined),
	OnResponse = get_value(onresponse, Opts, undefined),
	Timeout = get_value(timeout, Opts, 5000),
	URLDecDefault = {fun cowboy_http:urldecode/2, crash},
	URLDec = get_value(urldecode, Opts, URLDecDefault),
	ok = ranch:accept_ack(ListenerPid),
	wait_request(#state{listener=ListenerPid, socket=Socket,
		transport=Transport, dispatch=Dispatch,
		max_empty_lines=MaxEmptyLines, max_keepalive=MaxKeepalive,
		max_request_line_length=MaxRequestLineLength,
		max_header_name_length=MaxHeaderNameLength,
		max_header_value_length=MaxHeaderValueLength,
		timeout=Timeout, onrequest=OnRequest, onresponse=OnResponse,
		urldecode=URLDec}).

-spec wait_request(#state{}) -> ok.
wait_request(State=#state{socket=Socket, transport=Transport,
		timeout=T, buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} -> parse_request(State#state{
			buffer= << Buffer/binary, Data/binary >>});
		{error, _Reason} -> terminate(State)
	end.

%% @private
-spec parse_request(#state{}) -> ok.
%% Empty lines must be using \r\n.
parse_request(State=#state{buffer= << "\n", _/binary >>}) ->
	error_terminate(400, State);
%% We limit the length of the Request-line to MaxLength to avoid endlessly
%% reading from the socket and eventually crashing.
parse_request(State=#state{buffer=Buffer, max_request_line_length=MaxLength,
		req_empty_lines=ReqEmpty, max_empty_lines=MaxEmpty}) ->
	case binary:match(Buffer, <<"\r\n">>) of
		nomatch when byte_size(Buffer) > MaxLength ->
			error_terminate(413, State);
		nomatch ->
			wait_request(State);
		{0, _} when ReqEmpty =:= MaxEmpty ->
			error_terminate(400, State);
		{0, _} ->
			<< _:16, Rest/binary >> = Buffer,
			parse_request(State#state{
				buffer=Rest, req_empty_lines=ReqEmpty + 1});
		{Pos, _} ->
			<< RequestLine:Pos/binary, _:16, Rest/binary >> = Buffer,
			case cowboy_http:request_line(RequestLine) of
				{Method, AbsPath, Version} ->
					request(State#state{buffer=Rest}, Method, AbsPath, Version);
				{error, _} ->
					error_terminate(400, State)
			end
	end.

-spec request(#state{}, binary(), binary(), cowboy_http:version()) -> ok.
request(State, _, _, Version)
		when Version =/= {1, 0}, Version =/= {1, 1} ->
	error_terminate(505, State);
request(State=#state{socket=Socket, transport=Transport,
		onresponse=OnResponse, urldecode=URLDec},
		Method, <<"*">>, Version) ->
	Connection = version_to_connection(State, Version),
	parse_header(State#state{path_tokens= '*'},
		cowboy_req:new(Socket, Transport, Connection, Method, Version,
			<<"*">>, <<>>, OnResponse, URLDec));
request(State=#state{socket=Socket, transport=Transport,
		onresponse=OnResponse, urldecode=URLDec={URLDecFun, URLDecArg}},
		Method, AbsPath, Version) ->
	Connection = version_to_connection(State, Version),
	{PathTokens, Path, Qs} = cowboy_dispatcher:split_path(AbsPath,
		fun(Bin) -> URLDecFun(Bin, URLDecArg) end),
	parse_header(State#state{path_tokens=PathTokens},
		cowboy_req:new(Socket, Transport, Connection, Method, Version,
			Path, Qs, OnResponse, URLDec)).

-spec parse_header(#state{}, cowboy_req:req()) -> ok.
parse_header(State=#state{buffer= << "\r\n", Rest/binary >>}, Req) ->
	header_end(State#state{buffer=Rest}, Req);
parse_header(State=#state{buffer=Buffer,
		max_header_name_length=MaxLength}, Req) ->
	case binary:match(Buffer, <<":">>) of
		nomatch when byte_size(Buffer) > MaxLength ->
			error_terminate(413, State);
		nomatch ->
			wait_header(State, Req, fun parse_header/2);
		{Pos, _} ->
			<< Name:Pos/binary, _:8, Rest/binary >> = Buffer,
			Name2 = cowboy_bstr:to_lower(Name),
			Rest2 = cowboy_http:whitespace(Rest, fun(D) -> D end),
			parse_header_value(State#state{buffer=Rest2}, Req, Name2, <<>>)
	end.

parse_header_value(State=#state{buffer=Buffer,
		max_header_value_length=MaxLength}, Req, Name, SoFar) ->
	case binary:match(Buffer, <<"\r\n">>) of
		nomatch when byte_size(Buffer) + byte_size(SoFar) > MaxLength ->
			error_terminate(413, State);
		nomatch ->
			wait_header(State, Req,
				fun(S, R) -> parse_header_value(S, R, Name, SoFar) end);
		{Pos, _} when Pos + 2 =:= byte_size(Buffer) ->
			wait_header(State, Req,
				fun(S, R) -> parse_header_value(S, R, Name, SoFar) end);
		{Pos, _} ->
			<< Value:Pos/binary, _:16, Rest/binary >> = Buffer,
			case binary:at(Buffer, Pos + 2) of
				C when C =:= $\s; C =:= $\t ->
					parse_header_value(State#state{buffer=Rest}, Req, Name,
						<< SoFar/binary, Value/binary >>);
				_ ->
					header(State#state{buffer=Rest}, Req, Name,
						<< SoFar/binary, Value/binary >>)
			end
	end.

-spec wait_header(#state{}, cowboy_req:req(), fun()) -> ok.
wait_header(State=#state{socket=Socket, transport=Transport,
		timeout=T, buffer=Buffer}, Req, Fun) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} -> Fun(State#state{
			buffer= << Buffer/binary, Data/binary >>}, Req);
		{error, timeout} -> error_terminate(408, State);
		{error, closed} -> terminate(State)
	end.

-spec header(#state{}, cowboy_req:req(), binary(), binary()) -> ok.
header(State=#state{host_tokens=undefined, transport=Transport},
		Req, <<"host">>, RawHost) ->
	RawHost2 = cowboy_bstr:to_lower(RawHost),
	case catch cowboy_dispatcher:split_host(RawHost2) of
		{HostTokens, Host, undefined} ->
			Port = default_port(Transport:name()),
			parse_header(State#state{host_tokens=HostTokens},
				cowboy_req:set_host(Host, Port, RawHost, Req));
		{HostTokens, Host, Port} ->
			parse_header(State#state{host_tokens=HostTokens},
				cowboy_req:set_host(Host, Port, RawHost, Req));
		{'EXIT', _Reason} ->
			error_terminate(400, State)
	end;
%% Ignore Host headers if we already have it.
header(State, Req, <<"host">>, _) ->
	parse_header(State, Req);
header(State=#state{req_keepalive=Keepalive, max_keepalive=MaxKeepalive},
		Req, <<"connection">>, Connection)
		when Keepalive < MaxKeepalive ->
	parse_header(State, cowboy_req:set_connection(Connection, Req));
header(State, Req, Name, Value) ->
	parse_header(State, cowboy_req:add_header(Name, Value, Req)).

%% The Host header is required in HTTP/1.1 and optional in HTTP/1.0.
header_end(State=#state{host_tokens=undefined,
		buffer=Buffer, transport=Transport}, Req) ->
	case cowboy_req:version(Req) of
		{{1, 1}, _} ->
			error_terminate(400, State);
		{{1, 0}, Req2} ->
			Port = default_port(Transport:name()),
			onrequest(
				cowboy_req:set_buffer(Buffer,
					cowboy_req:set_host(<<>>, Port, <<>>, Req2)),
				State#state{buffer= <<>>, host_tokens=[]})
	end;
header_end(State=#state{buffer=Buffer}, Req) ->
	onrequest(cowboy_req:set_buffer(Buffer, Req), State#state{buffer= <<>>}).

%% Call the global onrequest callback. The callback can send a reply,
%% in which case we consider the request handled and move on to the next
%% one. Note that since we haven't dispatched yet, we don't know the
%% handler, host_info, path_info or bindings yet.
-spec onrequest(cowboy_req:req(), #state{}) -> ok.
onrequest(Req, State=#state{onrequest=undefined}) ->
	dispatch(Req, State);
onrequest(Req, State=#state{onrequest=OnRequest}) ->
	Req2 = OnRequest(Req),
	case cowboy_req:get_resp_state(Req2) of
		waiting -> dispatch(Req2, State);
		_ -> next_request(Req2, State, ok)
	end.

-spec dispatch(cowboy_req:req(), #state{}) -> ok.
dispatch(Req, State=#state{dispatch=Dispatch,
		host_tokens=HostTokens, path_tokens=PathTokens}) ->
	case cowboy_dispatcher:match(HostTokens, PathTokens, Dispatch) of
		{ok, Handler, Opts, Bindings, HostInfo, PathInfo} ->
			Req2 = cowboy_req:set_bindings(HostInfo, PathInfo, Bindings, Req),
			handler_init(Req2, State#state{handler={Handler, Opts},
				host_tokens=undefined, path_tokens=undefined});
		{error, notfound, host} ->
			error_terminate(400, State);
		{error, notfound, path} ->
			error_terminate(404, State)
	end.

-spec handler_init(cowboy_req:req(), #state{}) -> ok.
handler_init(Req, State=#state{transport=Transport,
		handler={Handler, Opts}}) ->
	try Handler:init({Transport:name(), http}, Req, Opts) of
		{ok, Req2, HandlerState} ->
			handler_handle(HandlerState, Req2, State);
		{loop, Req2, HandlerState} ->
			handler_before_loop(HandlerState, Req2, State);
		{loop, Req2, HandlerState, hibernate} ->
			handler_before_loop(HandlerState, Req2,
				State#state{hibernate=true});
		{loop, Req2, HandlerState, Timeout} ->
			handler_before_loop(HandlerState, Req2,
				State#state{loop_timeout=Timeout});
		{loop, Req2, HandlerState, Timeout, hibernate} ->
			handler_before_loop(HandlerState, Req2,
				State#state{hibernate=true, loop_timeout=Timeout});
		{shutdown, Req2, HandlerState} ->
			handler_terminate(HandlerState, Req2, State);
		%% @todo {upgrade, transport, Module}
		{upgrade, protocol, Module} ->
			upgrade_protocol(Req, State, Module)
	catch Class:Reason ->
		error_terminate(500, State),
		PLReq = cowboy_req:to_list(Req),
		error_logger:error_msg(
			"** Handler ~p terminating in init/3~n"
			"   for the reason ~p:~p~n"
			"** Options were ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts, PLReq, erlang:get_stacktrace()])
	end.

-spec upgrade_protocol(cowboy_req:req(), #state{}, atom()) -> ok.
upgrade_protocol(Req, State=#state{listener=ListenerPid,
		handler={Handler, Opts}}, Module) ->
	case Module:upgrade(ListenerPid, Handler, Opts, Req) of
		{UpgradeRes, Req2} -> next_request(Req2, State, UpgradeRes);
		_Any -> terminate(State)
	end.

-spec handler_handle(any(), cowboy_req:req(), #state{}) -> ok.
handler_handle(HandlerState, Req, State=#state{handler={Handler, Opts}}) ->
	try Handler:handle(Req, HandlerState) of
		{ok, Req2, HandlerState2} ->
			terminate_request(HandlerState2, Req2, State)
	catch Class:Reason ->
		PLReq = cowboy_req:to_list(Req),
		error_logger:error_msg(
			"** Handler ~p terminating in handle/2~n"
			"   for the reason ~p:~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts,
			 HandlerState, PLReq, erlang:get_stacktrace()]),
		handler_terminate(HandlerState, Req, State),
		error_terminate(500, State)
	end.

%% We don't listen for Transport closes because that would force us
%% to receive data and buffer it indefinitely.
-spec handler_before_loop(any(), cowboy_req:req(), #state{}) -> ok.
handler_before_loop(HandlerState, Req, State=#state{hibernate=true}) ->
	State2 = handler_loop_timeout(State),
	catch erlang:hibernate(?MODULE, handler_loop,
		[HandlerState, Req, State2#state{hibernate=false}]),
	ok;
handler_before_loop(HandlerState, Req, State) ->
	State2 = handler_loop_timeout(State),
	handler_loop(HandlerState, Req, State2).

%% Almost the same code can be found in cowboy_websocket.
-spec handler_loop_timeout(#state{}) -> #state{}.
handler_loop_timeout(State=#state{loop_timeout=infinity}) ->
	State#state{loop_timeout_ref=undefined};
handler_loop_timeout(State=#state{loop_timeout=Timeout,
		loop_timeout_ref=PrevRef}) ->
	_ = case PrevRef of undefined -> ignore; PrevRef ->
		erlang:cancel_timer(PrevRef) end,
	TRef = erlang:start_timer(Timeout, self(), ?MODULE),
	State#state{loop_timeout_ref=TRef}.

-spec handler_loop(any(), cowboy_req:req(), #state{}) -> ok.
handler_loop(HandlerState, Req, State=#state{loop_timeout_ref=TRef}) ->
	receive
		{timeout, TRef, ?MODULE} ->
			terminate_request(HandlerState, Req, State);
		{timeout, OlderTRef, ?MODULE} when is_reference(OlderTRef) ->
			handler_loop(HandlerState, Req, State);
		Message ->
			handler_call(HandlerState, Req, State, Message)
	end.

-spec handler_call(any(), cowboy_req:req(), #state{}, any()) -> ok.
handler_call(HandlerState, Req, State=#state{handler={Handler, Opts}},
		Message) ->
	try Handler:info(Message, Req, HandlerState) of
		{ok, Req2, HandlerState2} ->
			terminate_request(HandlerState2, Req2, State);
		{loop, Req2, HandlerState2} ->
			handler_before_loop(HandlerState2, Req2, State);
		{loop, Req2, HandlerState2, hibernate} ->
			handler_before_loop(HandlerState2, Req2,
				State#state{hibernate=true})
	catch Class:Reason ->
		PLReq = cowboy_req:to_list(Req),
		error_logger:error_msg(
			"** Handler ~p terminating in info/3~n"
			"   for the reason ~p:~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts,
			 HandlerState, PLReq, erlang:get_stacktrace()]),
		handler_terminate(HandlerState, Req, State),
		error_terminate(500, State)
	end.

-spec handler_terminate(any(), cowboy_req:req(), #state{}) -> ok.
handler_terminate(HandlerState, Req, #state{handler={Handler, Opts}}) ->
	try
		Handler:terminate(cowboy_req:lock(Req), HandlerState)
	catch Class:Reason ->
		PLReq = cowboy_req:to_list(Req),
		error_logger:error_msg(
			"** Handler ~p terminating in terminate/2~n"
			"   for the reason ~p:~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Class, Reason, Opts,
			 HandlerState, PLReq, erlang:get_stacktrace()])
	end.

-spec terminate_request(any(), cowboy_req:req(), #state{}) -> ok.
terminate_request(HandlerState, Req, State) ->
	HandlerRes = handler_terminate(HandlerState, Req, State),
	next_request(Req, State, HandlerRes).

-spec next_request(cowboy_req:req(), #state{}, any()) -> ok.
next_request(Req, State=#state{
		req_keepalive=Keepalive}, HandlerRes) ->
	cowboy_req:ensure_response(Req, 204),
	{BodyRes, Buffer} = case cowboy_req:skip_body(Req) of
		{ok, Req2} -> {ok, cowboy_req:get_buffer(Req2)};
		{error, _} -> {close, <<>>}
	end,
	%% Flush the resp_sent message before moving on.
	receive {cowboy_req, resp_sent} -> ok after 0 -> ok end,
	case {HandlerRes, BodyRes, cowboy_req:get_connection(Req)} of
		{ok, ok, keepalive} ->
			?MODULE:parse_request(State#state{
				buffer=Buffer, host_tokens=undefined, path_tokens=undefined,
				req_empty_lines=0, req_keepalive=Keepalive + 1});
		_Closed ->
			terminate(State)
	end.

%% Only send an error reply if there is no resp_sent message.
-spec error_terminate(cowboy_http:status(), #state{}) -> ok.
error_terminate(Code, State=#state{socket=Socket, transport=Transport,
		onresponse=OnResponse}) ->
	receive
		{cowboy_req, resp_sent} -> ok
	after 0 ->
		_ = cowboy_req:reply(Code, cowboy_req:new(Socket, Transport,
			close, <<"GET">>, {1, 1}, <<>>, <<>>, OnResponse, undefined)),
		ok
	end,
	terminate(State).

-spec terminate(#state{}) -> ok.
terminate(#state{socket=Socket, transport=Transport}) ->
	Transport:close(Socket),
	ok.

%% Internal.

-spec version_to_connection(#state{}, cowboy_http:version())
	-> keepalive | close.
version_to_connection(#state{req_keepalive=Keepalive,
		max_keepalive=MaxKeepalive}, _) when Keepalive >= MaxKeepalive ->
	close;
version_to_connection(_, {1, 1}) ->
	keepalive;
version_to_connection(_, _) ->
	close.

-spec default_port(atom()) -> 80 | 443.
default_port(ssl) -> 443;
default_port(_) -> 80.
