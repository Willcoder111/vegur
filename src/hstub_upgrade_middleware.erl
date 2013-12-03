-module(hstub_upgrade_middleware).

-behaviour(cowboy_middleware).
-export([execute/2]).

execute(Req, Env) ->
    {ConnectionTokens,Req1} = case cowboy_req:parse_header(<<"connection">>, Req) of
        {ok, L, Req0} when is_list(L) -> {L, Req0};
        {ok, Term, Req0} -> {[Term], Req0};
        {undefined, undefined, Req0} -> {[], Req0}
    end,
    case lists:member(<<"upgrade">>, ConnectionTokens) of
        false ->
            {ok, Req1, Env};
        true ->
            %% The connection should be upgraded
            case cowboy_req:parse_header(<<"upgrade">>, Req1) of
                {ok, undefined, Req2} ->
                    {error, 400, Req2};
                {ok, Upgrade, Req2} ->
                    handle_upgrade(Upgrade, Req2, Env);
                {undefined, _, Req2} ->
                    {error, 400, Req2}; % 426?
                _ ->
                    {error, 400, Req1}
            end
    end.

% http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.42
-spec handle_upgrade(undefined|[binary()] | {error, term()}, Req, Env) ->
                            {ok, Req, Env} |
                            {error, ErrorCode, Req} when
      Req :: cowboy_req:req(),
      Env :: cowboy_middleware:env(),
      ErrorCode :: 400.
handle_upgrade(undefined, Req, Env) ->
    % No Upgrade header
    {ok, Req, Env};
handle_upgrade(UpgradeTokens, Req, Env) when is_list(UpgradeTokens) ->
    Req2 = cowboy_req:set_meta(upgraded, true, Req),
    {ok, Req2, Env};
handle_upgrade({error, _}, Req, _Env) ->
    {error, 400, Req};
handle_upgrade(_, Req, _Env) ->
    % The upgrade header can contain other values, those will result in a client error
    {error, 400, Req}.
