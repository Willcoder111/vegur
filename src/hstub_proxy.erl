-module(hstub_proxy).

-define(BUFFER_LIMIT, 1024). % in bytes

-export([backend_connection/1
         ,send_request/7
         ,send_headers/7
         ,send_body/7
         ,read_backend_response/2
         ,upgrade/3
         ,relay/4]).

-spec backend_connection(ServiceBackend) ->
                                {connected, Client} |
                                {error, any()} when
      ServiceBackend :: hstub_interface:service_backend(),
      Client :: hstub_client:client().
backend_connection({IpAddress, Port}) ->
    {ok, Client} = hstub_client:init([]),
    case hstub_client:connect(ranch_tcp, IpAddress, Port,
                              100, Client) of
        {ok, Client1} ->
            {connected, Client1};
        {error, Reason} ->
            {error, Reason}
    end.

-spec send_request(Method, Headers, Body, Path, Url, Req, Client) ->
                            {done, Req, Client} |
                            {error, any()} when
      Body ::{stream, chunked|non_neg_integer()}|binary(),
      Method :: binary(),
      Headers :: [{binary(), binary()}]|[],
      Path :: binary(),
      Url :: binary(),
      Req :: cowboy_req:req(),
      Client :: hstub_client:client().
send_headers(Method, Headers, Body, Path, Url, Req, Client) ->
    %% Sends a request with a body yet to come through streaming. The BodyLen
    %% value can be either 'chunked' or an actual length.
    %% hstub_client:request_to_iolist will return a partial request with the
    %% correct headers in place, and the body can be sent later with sequential
    %% raw_request calls.
    IoHeaders = hstub_client:request_to_headers_iolist(Method,
                                                       request_headers(Headers),
                                                       Body,
                                                       'HTTP/1.1',
                                                       Url,
                                                       Path),
    {ok, _} = hstub_client:raw_request(IoHeaders, Client),
    {Cont, Req1} = cowboy_req:meta(continue, Req, []),
    case Cont of
        continue ->
            negotiate_continue(Body, Req1, Client);
        _ ->
            {done, Req1, Client}
    end.

send_body(_Method, _Header, Body, _Path, _Url, Req, BackendClient) ->
    case Body of
        {stream, BodyLen} ->
            {Fun, FunState} = case BodyLen of
                chunked -> {fun decode_chunked/2, {undefined, 0}};
                BodyLen -> {fun decode_raw/2, {0, BodyLen}}
            end,
            {ok, Req2} = cowboy_req:init_stream(Fun, FunState, fun decode_identity/1, Req),
            %% use headers & body to stream correctly
            stream_request(Req2, BackendClient);
        Body ->
            {ok, _} = hstub_client:raw_request(Body, BackendClient),
            {done, Req, BackendClient}
    end.

send_request(Method, Headers, Body, Path, Url, Req, Client) ->
    %% We have a static, already known body, and can send it at once.
    Request = hstub_client:request_to_iolist(Method,
                                             request_headers(Headers),
                                             Body,
                                             'HTTP/1.1',
                                             Url,
                                             Path),
    case hstub_client:raw_request(Request, Client) of
        {ok, Client2} -> {done, Req, Client2};
        {error, _Err} = Err -> Err
    end.

negotiate_continue(Body, Req, BackendClient) ->
    negotiate_continue(Body, Req, BackendClient, timer:seconds(55)).

negotiate_continue(_, _, _, Timeout) when Timeout =< 0 ->
    {error, Timeout};
negotiate_continue(Body, Req, BackendClient, Timeout) ->
    %% In here, we must await the 100 continue from the BackendClient
    %% *OR* wait until cowboy (front-end) starts sending data.
    %% Because there is a timeout before which a client may send data,
    %% and that we may have looked for a suitable backend for a considerable
    %% amount of time, always start by looking over the client connection.
    %% If the client sends first, we then *may* have to intercept the first
    %% 100 continue and not pass it on.
    %% Strip the 'continue' request type from meta!
    Wait = timer:seconds(1),
    case cowboy_req:buffer_data(0, 0, Req) of
        {ok, Req1} ->
            {done, Req1, BackendClient};
        {error, timeout} ->
            case hstub_client:buffer_data(0, Wait, BackendClient) of
                {ok, BackendClient1} ->
                    case read_response(BackendClient1) of
                        {ok, 100, _RespHeaders, _BackendClient2} ->
                            %% We don't carry the headers on a 100 Continue
                            %% for a simpler implementation -- there is no
                            %% header prescribed for it in the spec anyway.
                            Req1 = send_continue(Req, BackendClient),
                            %% We use the original client so that no state
                            %% change due to 100 Continue is observable.
                            {done, Req1, BackendClient};
                        {ok, Code, RespHeaders, BackendClient2} ->
                            {ok, Code, RespHeaders, BackendClient2};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, timeout} ->
                    negotiate_continue(Body, Req, BackendClient, Timeout-Wait);
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

-spec read_response(Client) ->
                           {ok, Code, Headers, Client} |
                           {error, Error} when
      Client :: hstub_client:client(),
      Code :: pos_integer(),
      Headers :: [{binary(), binary()}]|[],
      Error :: any().
read_response(Client) ->
    case hstub_client:response(Client) of
        {error, _} = Err -> Err;
        {ok, Code, RespHeaders, Client2} ->
            {ok, Code, RespHeaders, Client2}
    end.

%% This function works like read_response, but actually handles
%% the 100-Continue business to keep it out of the regular request flow
%% for the middleware.
-spec read_backend_response(Req, Client) ->
                           {ok, Code, Headers, Req, Client} |
                           {error, Error} when
      Req :: cowboy_req:req(),
      Client :: hstub_client:client(),
      Code :: pos_integer(),
      Headers :: [{binary(), binary()}]|[],
      Error :: any().
read_backend_response(Req, Client) ->
    case read_response(Client) of
        {error, _} = Err -> Err;
        {ok, Code, RespHeaders, Client1} ->
            {Cont, Req1} = cowboy_req:meta(continue, Req, []),
            case {Code, Cont} of
                {100, continue} ->
                    %% Leftover from Continue due to race condition between
                    %% client and server. Forward to client, which should
                    %% deal with it.
                    Req2 = send_continue(Req1, Client),
                    read_backend_response(Req2, Client1);
                {100, continued} ->
                    {error, non_terminal_status_after_continue};
                {100, _} ->
                    case cowboy_req:version(Req1) of
                        {'HTTP/1.0', Req2} ->
                            %% Http1.0 client without expect: 100-continue
                            %% Strip as per RFC.
                            read_backend_response(Req2, Client1);
                        {_, Req2} ->
                            %% Forward it. Older HTTP 1.1 servers may send
                            %% these or no reason, and clients should handle
                            %% them.
                            Req3 = send_continue(Req2, Client),
                            read_backend_response(Req3, Client1)
                    end;
                _ ->
                    {ok, Code, RespHeaders, Req1, Client1}
            end
    end.

send_continue(Req, BackendClient) ->
    HTTPVer = atom_to_binary(hstub_client:version(BackendClient), latin1),
    {{Transport,Socket}, _} = cowboy_req:raw_socket(Req, [no_buffer]),
    Transport:send(Socket,
        [HTTPVer, <<" 100 Continue\r\n\r\n">>]),
    %% Got it. Now clean up the '100 Continue' state from
    %% the request, and mark it as handled
    cowboy_req:set_meta(continue, continued, Req).

-spec upgrade(Headers, Req, Client) ->
                     {done, Req} when
      Req :: cowboy_req:req(),
      Headers :: [{binary(), binary()}]|[],
      Client :: hstub_client:client().
upgrade(Headers, Req, BackendClient) ->
    %% fetch raw sockets and buffers
    {Server={TransStub,SockStub}, BufStub, _NewClient} = hstub_client:raw_socket(BackendClient),
    {Client={TransCow,SockCow}, BufCow, Req3} = cowboy_req:raw_socket(Req),
    %% Send the response to the caller
    Headers1 = hstub_client:headers_to_iolist(request_headers(Headers)),
    TransCow:send(SockCow,
                  [<<"HTTP/1.1 101 Switching Protocols\r\n">>,
                   Headers1, <<"\r\n">>,
                   BufStub]),
    %% Flush leftover buffer data from the client, if any
    TransStub:send(SockStub, BufCow),
    ok = hstub_bytepipe:become(Client, Server, [{timeout, timer:seconds(55)}]),
    backend_close(BackendClient),
    {done, Req3}.

-spec relay(Status, Headers, Req, Client) ->
                   {ok, Req, Client} |
                   {error, Error, Req} when
      Status :: pos_integer(),
      Headers :: [{binary(), binary()}]|[],
      Req :: cowboy_req:req(),
      Client :: hstub_client:client(),
      Error :: any().
relay(Status, HeadersRaw, Req, Client) ->
    %% Dispatch data from hstub_client down into the cowboy connection, either
    %% in batch or directly.
    Headers = case should_close(Status, Req, Client) of
        false -> response_headers(HeadersRaw);
        true  -> add_connection_close_header(response_headers(HeadersRaw))
    end,
    case hstub_client:body_type(Client) of
        {content_size, N} when N =< ?BUFFER_LIMIT ->
            relay_full_body(Status, Headers, Req, Client);
        {content_size, N} ->
            relay_stream_body(Status, Headers, N, fun stream_body/2, Req, Client);
        stream_close -> % unknown content-lenght, stream until connection close
            relay_stream_body(Status, Headers, undefined, fun stream_close/2, Req, Client);
        chunked ->
            relay_chunked(Status, Headers, Req, Client);
        no_body ->
            relay_no_body(Status, Headers, Req, Client)
    end.

%% There is no body to relay
relay_no_body(Status, Headers, Req, Client) ->
    Req1 = respond(Status, Headers, <<>>, Req),
    {ok, Req1, backend_close(Client)}.

%% The entire body is known and we can pipe it through as is.
relay_full_body(Status, Headers, Req, Client) ->
    case hstub_client:response_body(Client) of
        {ok, Body, Client2} ->
            Req1 = respond(Status, Headers, Body, Req),
            {ok, Req1, backend_close(Client2)};
        {error, Error} ->
            backend_close(Client),
            {error, Error, Req}
    end.

%% The body is large and may need to be broken in multiple parts. Send them as
%% they come.
relay_stream_body(Status, Headers, Size, StreamFun, Req, Client) ->
    %% Use cowboy's partial response delivery to stream contents.
    %% We use exceptions (throws) to detect bad transfers and close
    %% both connections when this happens.
    Fun = fun(Socket, Transport) ->
        case StreamFun({Transport,Socket}, Client) of
            {ok, _Client2} -> ok;
            {error, Reason} -> throw({stream_error, Reason})
        end
    end,
    Req2 = case Size of
        undefined -> cowboy_req:set_resp_body_fun(Fun, Req); % end on close
        _ -> cowboy_req:set_resp_body_fun(Size, Fun, Req)    % end on size
    end,
    try cowboy_req:reply(Status, Headers, Req2) of
        {ok, Req3} ->
            {ok, Req3, backend_close(Client)}
    catch
        {stream_error, Error} ->
            backend_close(Client),
            {error, Error, Req2}
    end.

relay_chunked(Status, Headers, Req, Client) ->
    %% This is a special case. We stream pre-delimited chunks raw instead
    %% of using cowboy, which would have to recalculate and re-delimitate
    %% sizes all over after we parsed them first. We save time by just using
    %% raw chunks.
    {ok, Req2} = cowboy_req:chunked_reply(Status, Headers, Req),
    {RawSocket, Req3} = cowboy_req:raw_socket(Req2, [no_buffer]),
    case stream_chunked(RawSocket, Client) of
        {ok, Client2} ->
            {ok, Req3, backend_close(Client2)};
        {error, Error} -> % uh-oh, we died during the transfer
            backend_close(Client),
            {error, Error, Req3}
    end.

stream_chunked({Transport,Sock}=Raw, Client) ->
    %% Fetch chunks one by one (including length and line-delimitation)
    %% and forward them over the raw socket.
    case hstub_client:stream_chunk(Client) of
        {ok, Data, Client2} ->
            Transport:send(Sock, Data),
            stream_chunked(Raw, Client2);
        {more, _Len, Data, Client2} ->
            Transport:send(Sock, Data),
            stream_chunked(Raw, Client2);
        {done, Data, Client2} ->
            Transport:send(Sock, Data),
            {ok, backend_close(Client2)};
        {error, Reason} ->
            backend_close(Client),
            {error, Reason}
    end.

%% Deal with the transfer of a large or chunked request body by
%% going from a cowboy stream to raw htsub_client requests
stream_request(Req, Client) ->
    case cowboy_req:stream_body(Req) of
        {done, Req2} -> {done, Req2, Client};
        {ok, Data, Req2} -> stream_request(Data, Req2, Client);
        {error, Err} -> {error, Err}
    end.

stream_request(Buffer, Req, Client) ->
    {ok, _} = hstub_client:raw_request(Buffer, Client),
    case cowboy_req:stream_body(Req) of
        {done, Req2} -> {done, Req2, Client};
        {ok, Data, Req2} -> stream_request(Data, Req2, Client);
        {error, Err} -> {error, Err}
    end.

%% Cowboy also allows to decode data further after one pass, say if it
%% was gzipped or something. For our use cases, we do not care about this
%% as we relay the information as-is, so this function does nothing.
decode_identity(Data) ->
    {ok, Data}.

%% Custom decoder for Cowboy that will allow to stream data without modifying
%% it, in bursts, directly to the dyno without accumulating it in memory.
decode_raw(Data, {Streamed, Total}) when Streamed + byte_size(Data) < Total ->
    %% Still a lot to go, we return it all as a frame
    {ok, Data, <<>>, {Streamed+iolist_size(Data), Total}};
decode_raw(Data, {Streamed, Total}) ->
    %% Last batch, but we may have more than we asked for.
    Size = Total-Streamed,
    <<Data2:Size/binary, Rest/binary>> = Data,
    {done, Data2, Total, Rest}.

%% Custom decoder for Cowboy that will allow to return chunks in streams while
%% still giving us a general idea when a chunk begins and ends, and when the
%% entire request is cleared. Can deal with partial chunks for cases where
%% the user sends in multi-gigabyte chunks to mess with us.
decode_chunked(Data, {Cont, Total}) ->
    case hstub_chunked:stream_chunk(Data, Cont) of
        {done, Buf, Rest} ->
            %% Entire request is over
            {done, Buf, Total+iolist_size(Buf), Rest};
        {chunk, Buf, Rest} ->
            %% Chunk is done, but more to come
            {ok, Buf, Rest, {undefined, Total+iolist_size(Buf)}};
        {more, _Len, Buf, Cont2} ->
            %% Not yet done on the current chunk, but keep going.
            {ok, Buf, <<>>, {Cont2, Total}}
    end.

respond(Status, Headers, Body, Req) ->
    {ok, Req1} = cowboy_req:reply(Status, Headers, Body, Req),
    Req1.

stream_body({Transport,Sock}=Raw, Client) ->
    %% Stream the body until as much data is sent as there
    %% was in its content-length initially.
    case hstub_client:stream_body(Client) of
        {ok, Data, Client2} ->
            Transport:send(Sock, Data),
            stream_body(Raw, Client2);
        {done, Client2} ->
            {ok, Client2};
        {error, Reason} ->
            {error, Reason}
    end.

stream_close({Transport,Sock}=Raw, Client) ->
    %% Stream the body until the connection is closed.
    case hstub_client:stream_close(Client) of
        {ok, Data, Client2} ->
            Transport:send(Sock, Data),
            stream_close(Raw, Client2);
        {done, Client2} ->
            {ok, Client2};
        {error, Reason} ->
            {error, Reason}
    end.

%% We should close the connection whenever we get an Expect: 100-Continue
%% that got answered with a final status code.
should_close(Status, Req, _Client) ->
    {Cont, _} = cowboy_req:meta(continue, Req, []),
    %% If we haven't received a 100 continue to forward AND this is
    %% a final status, then we should close the connection
    Cont =:= continue andalso Status >= 200.

backend_close(undefined) -> undefined;
backend_close(Client) ->
    hstub_client:close(Client),
    undefined.

%% Strip Connection header on request.
request_headers(Headers0) ->
    lists:foldl(fun (F, H) ->
                        F(H)
                end,
                Headers0,
                [fun delete_connection_keepalive_header/1
                ,fun delete_host_header/1
                ,fun add_connection_close_header/1
                ,fun delete_content_length_header/1
                ]).

%% Strip Connection header on response.
response_headers(Headers) ->
    lists:foldl(fun (F, H) ->
                        F(H)
                end,
                Headers,
                [fun delete_connection_keepalive_header/1
                ]).

delete_connection_keepalive_header(Hdrs) ->
    lists:delete({<<"connection">>, <<"keepalive">>}, Hdrs).

delete_host_header(Hdrs) ->
    lists:keydelete(<<"host">>, 1, Hdrs).

delete_content_length_header(Hdrs) ->
    lists:keydelete(<<"content-length">>, 1, Hdrs).

add_connection_close_header(Hdrs) ->
    case lists:keymember(<<"connection">>, 1, Hdrs) of
        true -> Hdrs;
        false -> [{<<"connection">>, <<"close">>} | Hdrs]
    end.