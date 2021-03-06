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
-module(dnsxd_op_ctx).
-include("dnsxd_internal.hrl").

%% API
-export([new_udp/5, new_tcp/3]).
-export([protocol/1,
	 src/1, dst/1,
	 src_ip/1, src_port/1,
	 dst_ip/1, dst_port/1,
	 send/2,
	 tsig/1, tsig/2, tsig_mac/1, tsig_mac/2,
	 max_size/1, max_size/2,
	 tc_mode/1, tc_mode/2,
	 to_wire/2, reply/3]).

-record(dnsxd_op_ctx, {protocol,
		       socket,
		       src_ip,
		       src_port,
		       dst_ip,
		       dst_port,
		       tsig,
		       max_size = 512,
		       tc_mode = default
		      }).

%%%===================================================================
%%% API
%%%===================================================================

new_udp(Socket, SrcIP, SrcPort, DstIP, DstPort) ->
    Ctx = #dnsxd_op_ctx{protocol = udp, src_ip = SrcIP, src_port = SrcPort},
    new(Ctx, Socket, DstIP, DstPort).

new_tcp(Socket, DstIP, DstPort) ->
    Ctx = #dnsxd_op_ctx{protocol = tcp, socket = Socket},
    new(Ctx, Socket, DstIP, DstPort).

new(#dnsxd_op_ctx{} = Ctx, Socket, DstIP, DstPort) ->
    Ctx#dnsxd_op_ctx{socket = Socket, dst_ip = DstIP, dst_port = DstPort}.

protocol(#dnsxd_op_ctx{protocol = Protocol}) -> Protocol.

src(#dnsxd_op_ctx{protocol = udp, src_port = SrcPort, src_ip = SrcIP}) ->
    {SrcIP, SrcPort};
src(#dnsxd_op_ctx{protocol = tcp, socket = Socket}) ->
    {ok, {_SrcIP, _SrcPort} = Src} = inet:peername(Socket),
    Src.

src_ip(#dnsxd_op_ctx{} = Ctx) -> {SrcIP, _SrcPort} = src(Ctx), SrcIP.

src_port(#dnsxd_op_ctx{} = Ctx) -> {_SrcIP, SrcPort} = src(Ctx), SrcPort.

dst(#dnsxd_op_ctx{dst_ip = DstIP, dst_port = DstPort}) -> {DstIP, DstPort}.

dst_ip(#dnsxd_op_ctx{dst_ip = DstIP}) -> DstIP.

dst_port(#dnsxd_op_ctx{dst_port = DstPort}) -> DstPort.

send(#dnsxd_op_ctx{protocol = udp,
		   socket = Socket,
		   src_ip = SrcIP,
		   src_port = SrcPort}, Message) ->
    gen_udp:send(Socket, SrcIP, SrcPort, Message);
send(#dnsxd_op_ctx{protocol = tcp, socket = Socket}, Message) ->
    gen_tcp:send(Socket, Message).

tsig(#dnsxd_op_ctx{tsig = TSIG}) -> TSIG.

tsig(#dnsxd_op_ctx{} = Ctx, NewTSIG) -> Ctx#dnsxd_op_ctx{tsig = NewTSIG}.

tsig_mac(#dnsxd_op_ctx{tsig = #dnsxd_tsig_ctx{mac =  MAC}}) -> MAC;
tsig_mac(#dnsxd_op_ctx{}) -> undefined.

tsig_mac(#dnsxd_op_ctx{tsig = #dnsxd_tsig_ctx{} = TSIG} = MsgCtx, NewMAC)
  when is_binary(NewMAC) ->
    MsgCtx#dnsxd_op_ctx{tsig = TSIG#dnsxd_tsig_ctx{mac = NewMAC}};
tsig_mac(_, _) -> erlang:error(badarg).

max_size(#dnsxd_op_ctx{max_size = MaxSize}) -> MaxSize.

max_size(#dnsxd_op_ctx{} = Ctx, NewMaxSize) ->
    Ctx#dnsxd_op_ctx{max_size = NewMaxSize}.

tc_mode(#dnsxd_op_ctx{tc_mode = TCMode}) -> TCMode.

tc_mode(#dnsxd_op_ctx{} = Ctx, NewTCMode) ->
    Ctx#dnsxd_op_ctx{tc_mode = NewTCMode}.

to_wire(MsgCtx, #dns_message{additional = Ad} = RespMsg0) ->
    UPS = dnsxd_op_ctx:max_size(MsgCtx),
    RespMsg1 = case Ad of
		   [#dns_optrr{} = OptRR|AddRest] ->
		       NewOptRR = OptRR#dns_optrr{udp_payload_size = UPS},
		       NewAdd = [NewOptRR|AddRest],
		       RespMsg0#dns_message{additional = NewAdd};
		   _ ->
		       RespMsg0
	       end,
    MaxSize = case protocol(MsgCtx) of
		  tcp -> 65535;
		  udp -> UPS
	      end,
    TCMode = tc_mode(MsgCtx),
    Opts = [{tc_mode, TCMode}, {max_size, MaxSize}],
    to_wire_internal(MsgCtx, RespMsg1, Opts, false).

reply(MsgCtx,
      #dns_message{additional = [#dns_optrr{} = OptRR|_]} = Msg, Props) ->
    NewOptRR = build_optrr(MsgCtx, OptRR, Props),
    NewProps = case lists:keytake(ad, 1, Props) of
		   {value, {ad, Additional}, Props0}
		     when is_list(Additional) ->
		       NewAdditional = [NewOptRR|Additional],
		       [{ad, NewAdditional}|Props0];
		   false ->
		       [{ad, [NewOptRR]}|Props]
	       end,
    reply_body(MsgCtx, Msg, NewProps);
reply(MsgCtx, #dns_message{} = Msg, Props) ->
    reply_body(MsgCtx, Msg, Props).

%%%===================================================================
%%% Internal functions
%%%===================================================================

reply_body(MsgCtx, Msg, Props) ->
    Now = dns:unix_time(),
    RC = proplists:get_value(rc, Props, ?DNS_RCODE_NOERROR),
    AA = proplists:get_bool(aa, Props),
    DNSSEC = proplists:get_bool(dnssec, Props),
    An = to_rr(Now, DNSSEC, proplists:get_value(an, Props, [])),
    AnLen = length(An),
    Au = to_rr(Now, DNSSEC, proplists:get_value(au, Props, [])),
    AuLen = length(Au),
    Ad = to_rr(Now, DNSSEC, proplists:get_value(ad, Props, [])),
    AdLen = length(Ad),
    RespMsg = Msg#dns_message{qr = true, rc = RC, aa = AA,
			      anc = AnLen, answers = An,
			      auc = AuLen, authority = Au,
			      adc = AdLen, additional = Ad},
    to_wire(MsgCtx, RespMsg).

to_rr(Now, DNSSEC, RRs) when is_list(RRs) ->
    lists:foldr(fun(#dns_rr{} = RR, Acc) -> [RR|Acc];
		   (#dnsxd_rr{name = Name,
			      class = Class,
			      type = Type,
			      data = Data} = RR, Acc) ->
			[#dns_rr{name = Name,
				 class = Class,
				 type = Type,
				 ttl = ttl(Now, RR),
				 data = Data}|Acc];
		   (#rrset{} = Set, Acc) -> to_rr(Now, DNSSEC, Set, Acc);
		   (Other, Acc) -> [Other|Acc]
		end, [], RRs).

to_rr(Now, false, #rrset{name = Name, class = Class, type = Type,
			 data = Datas} = Set, Acc) ->
    TTL = ttl(Now, Set),
    lists:foldl(fun(Data, Acc0) ->
			[#dns_rr{name = Name,
				 class = Class,
				 type = Type,
				 ttl = TTL,
				 data = Data}|Acc0]
		end, Acc, Datas);
to_rr(Now, true, #rrset{name = Name, class = Class, sig = Sigs} = Set, Acc) ->
    TTL = ttl(Now, Set),
    Acc1 = lists:foldl(fun(Sig, Acc0) ->
			       [#dns_rr{name = Name,
					class = Class,
					type = ?DNS_TYPE_RRSIG,
					ttl = TTL,
					data = Sig}|Acc0]
		       end, Acc, Sigs),
    to_rr(Now, false, Set, Acc1).

ttl(Now, #dnsxd_rr{incept = Incept,
		   expire = Expire,
		   ttl = TTL}) -> ttl(Now, Incept, Expire, TTL);
ttl(Now, #rrset{incept = Incept, expire = Expire, ttl = TTL}) ->
    ttl(Now, Incept, Expire, TTL).

ttl(Now, Incept, Expire, NaturalTTL) ->
    case is_integer(Expire) of
	true ->
	    MinTTL = 0,
	    MaxTTL = 24 * 60 * 60, % config opts... or another way?
	    TTL = lists:min([Expire - Incept, Expire - Now, NaturalTTL]),
	    case TTL of
		TTL when TTL < MinTTL -> MinTTL;
		TTL when TTL > MaxTTL -> MaxTTL;
		TTL -> TTL
	    end;
	false -> NaturalTTL
    end.

build_optrr(MsgCtx, #dns_optrr{data = ReqDatas}, Props) ->
    PayloadSize = dnsxd_op_ctx:max_size(MsgCtx),
    DNSSEC = proplists:get_bool(dnssec, Props),
    Props0 = case lists:keymember(dns_opt_nsid, 1, ReqDatas) of
		 true ->
		     {ok, Host} = inet:gethostname(),
		     [#dns_opt_nsid{data = list_to_binary(Host)}|Props];
		 false -> Props
	     end,
    Datas = [ EOpt || EOpt <- Props0, is_eopt(EOpt) ],
    #dns_optrr{udp_payload_size = PayloadSize, dnssec = DNSSEC, data = Datas}.

is_eopt(#dns_opt_llq{}) -> true;
is_eopt(#dns_opt_ul{}) -> true;
is_eopt(#dns_opt_nsid{}) -> true;
is_eopt(_) -> false.

to_wire_internal(MsgCtx, Msg, Opts, Tail) ->
    Opts0 = add_tsig_opts(MsgCtx, Opts, Tail),
    case dns:encode_message(Msg, Opts0) of
	{false, Bin} -> dnsxd_op_ctx:send(MsgCtx, Bin);
	{false, Bin, _NewMAC} ->
	    ok = dnsxd_op_ctx:send(MsgCtx, Bin);
	{true, Bin, Msg0} ->
	    ok = dnsxd_op_ctx:send(MsgCtx, Bin),
	    to_wire_internal(MsgCtx, Msg0, Opts, true);
	{true, Bin, NewMAC, Msg0} ->
	    MsgCtx0 = tsig_mac(MsgCtx, NewMAC),
	    ok = dnsxd_op_ctx:send(MsgCtx0, Bin),
	    to_wire_internal(MsgCtx0, Msg0, Opts, true)
    end.

add_tsig_opts(MsgCtx, Opts, Tail) ->
    case dnsxd_op_ctx:tsig(MsgCtx) of
	#dnsxd_tsig_ctx{keyname = KeyName,
			alg = Alg,
			secret = Secret,
			mac = MAC,
			msgid = OrigMsgId} ->
	    TSIGOpts = [{name, KeyName}, {alg, Alg}, {secret, Secret},
			{mac, MAC}, {msgid, OrigMsgId}, {tail, Tail}],
	    [{tsig, TSIGOpts}|Opts];
	undefined -> Opts
    end.
