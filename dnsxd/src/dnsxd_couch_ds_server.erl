%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Andrew Tunnell-Jones. All Rights Reserved.
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
-module(dnsxd_couch_ds_server).
-include("dnsxd_couch.hrl").
-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([dnsxd_admin_zone_list/0, dnsxd_admin_get_zone/1,
	 dnsxd_admin_change_zone/2, dnsxd_dns_update/5,
	 dnsxd_reload_zones/1, dnsxd_allow_axfr/2, dnsxd_get_tsig_key/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(TAB_AXFR, dnsxd_couch_axfr).
-define(TAB_TSIG, dnsxd_couch_tsig).

-define(CHANGES_FILTER, <<?DNSXD_COUCH_DESIGNDOC "/dnsxd_couch_zone">>).

-record(state, {db_ref, db_seq, db_lost = false, reload = []}).
-record(tsig_entry, {zone :: binary(),
		     name :: binary(),
		     key}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    DsOpts = dnsxd:datastore_opts(),
    Timeout = proplists:get_value(init_timeout, DsOpts, 60000),
    Opts = [{timeout, Timeout}],
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], Opts).

dnsxd_dns_update(MsgCtx, ZoneName, Lease, PreReq, Changes) ->
    case dnsxd_op_ctx:tsig(MsgCtx) of
	#dnsxd_tsig_ctx{keyname = KeyName} ->
	    case get_tsig_key(ZoneName, KeyName) of
		undefined -> {error, ?DNS_RCODE_REFUSED};
		Key ->
		    update_zone(Key, ZoneName, Lease, PreReq, Changes)
	    end;
	_ -> {error, ?DNS_RCODE_NOTAUTH}
    end.

dnsxd_admin_zone_list() ->
    case dnsxd_couch_lib:get_db() of
	{ok, DbRef} ->
	    ViewName = {?DNSXD_COUCH_DESIGNDOC, "dnsxd_couch_zone"},
	    Fun = fun({Props}, Acc) ->
			  ZoneName = get_value(<<"id">>, Props),
			  Enabled = get_value(<<"key">>, Props),
			  [{ZoneName, Enabled}|Acc]
		  end,
	    case couchbeam_view:fold(Fun, [], DbRef, ViewName) of
		Zones when is_list(Zones) -> {ok, Zones};
		{error, _Reason} = Error -> Error
	    end;
	{error, _Reason} = Error -> Error
    end.

dnsxd_admin_get_zone(ZoneName) ->
    case dnsxd_couch_zone:get(ZoneName) of
	{ok, #dnsxd_couch_zone{} = CouchZone} ->
	    Zone = to_dnsxd_zone(CouchZone, true),
	    {ok, Zone};
	{error, _Reason} = Error -> Error
    end.

dnsxd_admin_change_zone(ZoneName, [_|_] = Changes) when is_binary(ZoneName) ->
    dnsxd_couch_zone:change(ZoneName, Changes).

dnsxd_reload_zones(ZoneNames) ->
    Fun = fun(ZoneName) ->
		  case load_zone(ZoneName) of
		      ok -> ok;
		      {error, Reason} ->
			  Fmt = "Failed to reload ~s - DB error:~n~p",
			  ?DNSXD_ERR(Fmt, [ZoneName, Reason]),
			  gen_server:cast(?SERVER, {reload, ZoneName})
		  end
	  end,
    lists:foreach(Fun, ZoneNames).

dnsxd_allow_axfr(Context, ZoneName) ->
    case ets:lookup_element(?TAB_AXFR, ZoneName, 2) of
	Bool when is_boolean(Bool) -> Bool;
	IPs when is_list(IPs) ->
	    SrcIP = dnsxd_lib:ip_to_txt(dnsxd_op_ctx:src_ip(Context)),
	    lists:member(SrcIP, IPs)
    end.

dnsxd_get_tsig_key(?DNS_OPCODE_UPDATE,
		   #dns_query{name = Zone, type = ?DNS_TYPE_SOA}, Name, _Alg) ->
    get_tsig_key(Zone, Name);
dnsxd_get_tsig_key(_OpCode, _Query, _Name, _Alg) -> undefined.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    ?TAB_AXFR = ets:new(?TAB_AXFR, [named_table, {keypos, 1}]),
    ?TAB_TSIG = ets:new(?TAB_TSIG, [named_table, {keypos, #tsig_entry.zone},
				    bag]),
    {ok, DbRef, DbSeq} = dnsxd_couch_lib:setup_monitor(?CHANGES_FILTER),
    State = #state{db_ref = DbRef, db_seq = DbSeq},
    ok = init_load_zones(),
    {ok, State}.

handle_call(Request, _From, State) ->
    ?DNSXD_ERR("Stray call:~n~p~nState:~n~p~n", [Request, State]),
    {noreply, State}.

handle_cast({reload, ZoneName}, #state{db_lost = false} = State) ->
    ok = spawn_zone_reloader(ZoneName),
    {noreply, State};
handle_cast({reload, ZoneName}, #state{reload = List} = State) ->
    List0 = case lists:member(ZoneName, List) of
		true -> List;
		false -> [ZoneName|List]
	    end,
    NewState = State#state{reload = List0},
    {noreply, NewState};
handle_cast(Msg, State) ->
    ?DNSXD_ERR("Stray cast:~n~p~nState:~n~p~n", [Msg, State]),
    {noreply, State}.

handle_info({Ref, done} = Message, #state{db_ref = Ref, db_seq = Seq,
					  db_lost = Lost, reload = ReloadList
					 } = State) ->
    case dnsxd_couch_lib:setup_monitor(?CHANGES_FILTER, Seq) of
	{ok, NewRef, Seq} ->
	    if Lost -> ?DNSXD_INFO("Reconnected db poll");
	       true -> ok end,
	    ok = spawn_zone_reloader(ReloadList),
	    State0 = State#state{db_ref = NewRef, db_lost = false, reload = []},
	    {noreply, State0};
	{error, Error} ->
	    ?DNSXD_ERR("Unable to reconnect db poll:~n"
		       "~p~n"
		       "Retrying in 30 seconds", [Error]),
	    {ok, _} = timer:send_after(30000, self(), Message),
	    {noreply, State}
    end;
handle_info({error, Ref, _Seq, Error},
	    #state{db_ref = Ref, db_lost = false} = State) ->
    ?DNSXD_ERR("Lost db connection:~n~p", [Error]),
    {ok, _} = timer:send_after(0, self(), {Ref, done}),
    NewState = State#state{db_lost = true},
    {noreply, NewState};
handle_info({error, _Ref, _Seq, Error}, #state{db_lost = true} = State) ->
    Fmt = "Got db connection error when db connection already lost:~n~p",
    ?DNSXD_ERR(Fmt, [Error]),
    {noreply, State};
handle_info({change, Ref, {Props}}, #state{db_ref = Ref} = State) ->
    Name = proplists:get_value(<<"id">>, Props),
    NewSeq = proplists:get_value(<<"seq">>, Props),
    NewState = State#state{db_seq = NewSeq},
    Exists = dnsxd:zone_loaded(Name),
    case load_zone(Name) of
	ok when Exists -> ?DNSXD_INFO("Zone ~s reloaded", [Name]);
	ok -> ?DNSXD_INFO("Zone loaded", [Name]);
	{error, Reason} ->
	    ?DNSXD_ERR("Failed to load zone ~s: ~p", [Name, Reason])
    end,
    {noreply, NewState};
handle_info(_Msg, State) -> {stop, stray_message, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

load_zone(ZoneName) ->
    case dnsxd_couch_zone:get(ZoneName) of
	{ok, #dnsxd_couch_zone{enabled = true} = CouchZone} ->
	    Zone = to_dnsxd_zone(CouchZone),
	    ok = dnsxd:reload_zone(Zone),
	    ok = cache_axfr(CouchZone),
	    ok = cache_tsig(CouchZone);
	{ok, #dnsxd_couch_zone{enabled = false}} ->
	    ok = unload_zone(ZoneName),
	    {error, disabled};
	{error, Reason} = Error ->
	    case lists:member(Reason, [deleted, not_found, not_zone]) of
		true -> ok = unload_zone(ZoneName);
		false -> ok
	    end,
	    Error
    end.

cache_axfr(#dnsxd_couch_zone{name = Zone, axfr_enabled = false}) ->
    ets:insert(?TAB_AXFR, {Zone, false}),
    ok;
cache_axfr(#dnsxd_couch_zone{name = Zone, axfr_hosts = []}) ->
    ets:insert(?TAB_AXFR, {Zone, true}),
    ok;
cache_axfr(#dnsxd_couch_zone{name = Zone, axfr_hosts = Hosts}) ->
    ets:insert(?TAB_AXFR, {Zone, Hosts}),
    ok.

cache_tsig(#dnsxd_couch_zone{name = Zone, tsig_keys = TSIGKeys}) ->
    New = [#tsig_entry{zone = Zone,
		       name = <<Name/binary, $., Zone/binary>>,
		       key = couch_tk_to_dnsxd_key(TK)}
	   || #dnsxd_couch_tk{name = Name} = TK <- TSIGKeys ],
    Old = ets:lookup(?TAB_TSIG, Zone),
    [ ets:delete_object(?TAB_TSIG, Key) || Key <- Old -- New],
    true = ets:insert(?TAB_TSIG, New),
    ok.

unload_zone(ZoneName) ->
    ok = dnsxd:delete_zone(ZoneName),
    true = ets:delete(?TAB_AXFR, ZoneName),
    true = ets:match_delete(?TAB_TSIG, #tsig_entry{zone = ZoneName, _ = '_'}),
    ok.

get_tsig_key(Zone, Name) ->
    Pattern = #tsig_entry{zone = Zone, name = Name, key = '$1'},
    case ets:match(?TAB_TSIG, Pattern) of
	[[#dnsxd_tsig_key{} = Key]] -> Key;
	_ -> undefined
    end.

update_zone(#dnsxd_tsig_key{dnssd_only = true, name = KeyName}, ZoneName, Lease,
	    PreReq, Changes) ->
    Fun = fun(Change) ->
		  dnsxd_lib:is_dnssd_change(ZoneName, KeyName, Change)
	  end,
    case lists:all(Fun, Changes) of
	true -> update_zone(KeyName, ZoneName, Lease, PreReq, Changes);
	false -> {error, ?DNS_RCODE_REFUSED}
    end;
update_zone(#dnsxd_tsig_key{name = KeyName}, ZoneName, Lease, PreReq,
	    Changes) ->
    update_zone(KeyName, ZoneName, Lease, PreReq, Changes);
update_zone(Key, Zone, Lease, PreReq, Changes) ->
    LockId = {{?MODULE, Zone}, self()},
    DsOpts = dnsxd:datastore_opts(),
    Attempts = proplists:get_value(update_attempts, DsOpts, 10),
    BeforeLock = now(),
    true = global:set_lock(LockId, [node()]),
    Result = case timer:now_diff(now(), BeforeLock) < 2000000 of
		 true ->
		     update_zone(Attempts, Key, Zone, Lease, PreReq, Changes);
		 false -> {error, timeout}
	     end,
    true = global:del_lock(LockId),
    Result.

update_zone(0, _Key, Zone, _Lease, _PreReq, _Changes) ->
    ?DNSXD_ERR("Exhausted update attempts updating ~s", [Zone]),
    {error, ?DNS_RCODE_SERVFAIL};
update_zone(Attempts, Key, Zone, Lease, PreReq, Changes) ->
    case dnsxd_couch_zone:update(Key, Zone, Lease, PreReq, Changes) of
	{error, conflict} ->
	    update_zone(Attempts - 1, Key, Zone, Lease, PreReq, Changes);
	{error, Reason} ->
	    ?DNSXD_ERR("Error updating ~s:~n~p", [Zone, Reason]),
	    {error, ?DNS_RCODE_SERVFAIL};
	Other -> Other
    end.

init_load_zones() ->
    {ok, DbRef} = dnsxd_couch_lib:get_db(),
    ViewName = {?DNSXD_COUCH_DESIGNDOC, "dnsxd_couch_zone"},
    Fun = fun({Props}) ->
		  ZoneName = get_value(<<"id">>, Props),
		  load_zone(ZoneName)
	  end,
    Opts = [{<<"key">>, <<"true">>}],
    ok = couchbeam_view:foreach(Fun, DbRef, ViewName, Opts).

couch_tk_to_dnsxd_key(#dnsxd_couch_tk{id = Id,
				      name = Name,
				      secret = Secret,
				      enabled = Enabled,
				      dnssd_only = DnssdOnly}) ->
    #dnsxd_tsig_key{id = Id,
		    name = Name,
		    secret = base64:decode(Secret),
		    enabled = Enabled,
		    dnssd_only = DnssdOnly}.

couch_dk_to_dnsxd_key(#dnsxd_couch_dk{id = Id, incept = Incept, expire = Expire,
				      alg = Alg, ksk = KSK,
				      data = #dnsxd_couch_dk_rsa{} = Data}) ->
    #dnsxd_couch_dk_rsa{e = E, n = N, d = D} = Data,
    Fun = fun(B64) ->
		  Bin = base64:decode(B64),
		  BinSize = byte_size(Bin),
		  <<BinSize:32, Bin/binary>>
	  end,
    Key = [ Fun(X) || X <- [E, N, D] ],
    #dnsxd_dnssec_key{id = Id, incept = Incept, expire = Expire, alg = Alg,
		      ksk = KSK, key = Key}.

to_dnsxd_zone(#dnsxd_couch_zone{} = Zone) -> to_dnsxd_zone(Zone, false).

to_dnsxd_zone(#dnsxd_couch_zone{name = Name,
				enabled = Enabled,
				rr = CouchRRs,
				tsig_keys = CouchTSIGKeys,
				soa_param = CouchSP,
				dnssec_enabled = DNSSEC,
				dnssec_keys = CouchDNSSECKeys,
				dnssec_nsec3_param = NSEC3Param,
				dnssec_siglife = SigLife}, KeepDisabled) ->
    RRs = [ to_dnsxd_rr(RR) || RR <- CouchRRs ],
    Serials = dnsxd_couch_lib:get_serials(CouchRRs),
    TSIGKeys = [ couch_tk_to_dnsxd_key(Key)
		 || Key <- CouchTSIGKeys,
		    Key#dnsxd_couch_tk.enabled orelse KeepDisabled,
		    not is_integer(Key#dnsxd_couch_tk.tombstone) ],
    DNSSECKeys = [ couch_dk_to_dnsxd_key(Key)
		   || Key <- CouchDNSSECKeys,
		      not is_integer(Key#dnsxd_couch_dk.tombstone) ],
    #dnsxd_couch_sp{mname = MName,
		    rname = RName,
		    refresh = Refresh,
		    retry = Retry,
		    expire = Expire,
		    minimum = Minimum} = CouchSP,
    SP = #dnsxd_soa_param{mname = MName,
			  rname = RName,
			  refresh = Refresh,
			  retry = Retry,
			  expire = Expire,
			  minimum = Minimum},
    NSEC3 = case NSEC3Param of
		#dnsxd_couch_nsec3param{salt = Salt, iter = Iter, alg = Alg} ->
		    #dnsxd_nsec3_param{hash = Alg, salt = Salt, iter = Iter};
		_ ->
		    undefined
	    end,
    #dnsxd_zone{name = Name,
		enabled = Enabled,
		rr = RRs,
		serials = Serials,
		tsig_keys = TSIGKeys,
		soa_param = SP,
		dnssec_enabled = DNSSEC,
		dnssec_keys = DNSSECKeys,
		dnssec_siglife = SigLife,
		nsec3 = NSEC3}.

to_dnsxd_rr(#dnsxd_couch_rr{incept = Incept,
			    expire = Expire,
			    name = Name,
			    class = Class,
			    type = Type,
			    ttl = TTL,
			    data = Data}) ->
    #dnsxd_rr{incept = Incept,
	      expire = Expire,
	      name = Name,
	      class = Class,
	      type = Type,
	      ttl = TTL,
	      data = Data}.

get_value(Key, List) -> {Key, Value} = lists:keyfind(Key, 1, List), Value.

spawn_zone_reloader(ZoneName) when is_binary(ZoneName) ->
    spawn_zone_reloader([ZoneName]);
spawn_zone_reloader([_|_] = ZoneNames) ->
    spawn_link(fun() -> ?MODULE:dnsxd_reload_zones(ZoneNames) end),
    ok;
spawn_zone_reloader([]) -> ok.
