#!/usr/bin/env escript
%%! -hidden -noinput -dist_listen false
%% Copyright (c) Bankole Ogundero and the Vigil contributors
%% SPDX-License-Identifier: Apache-2.0
%%
%% Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
%% implied. Run it at your own risk: review it first, and test it before you
%% rely on it. In no event shall the authors or copyright holders be liable
%% for any claim, damages or other liability arising from its use. See the
%% LICENSE file for the full terms.
%%
%% _beam.escript - the beam pack's cookie tier: what each node says about
%% itself, read over Erlang distribution with the node's cookie.
%%
%%   escript _beam.escript vm|processes|tables|dist|apps
%%
%% The nodes come from BEAM_DIST, "<name>=<node>" separated by ;, and the
%% cookie from BEAM_COOKIE: the environment, never a command line.
%%
%% WARNING: a node's cookie lets whoever holds it run anything on that node.
%% This script never does: it only READS. It joins as a hidden node that
%% never listens (-dist_listen false), so the nodes never list it, nothing
%% can connect to it and it needs no epmd here. Every call it makes on a
%% node is one of these, and nothing else:
%%   erlang:memory/0, erlang:system_info/1, erlang:statistics/1,
%%   erlang:processes/0, erlang:process_info/2, erlang:port_info/2,
%%   erlang:nodes/1, ets:all/0, ets:info/1, proc_lib:translate_initial_call/1,
%%   application:which_applications/0
%% It never calls erlang:system_flag/2, so the figures that need a switch
%% turned on first (scheduler utilisation, for one) are not read.
%%
%% Exit code: 0 on success, nodes up or down; 1 if a node that epmd lists
%% refused the cookie, or a setting is wrong.

-define(TIMEOUT, 15000).
-define(MAX_PROCESSES, 20000).
-define(TOP, 10).

main([Job]) when Job =:= "vm"; Job =:= "processes"; Job =:= "tables"; Job =:= "dist"; Job =:= "apps" ->
    Nodes = targets(os:getenv("BEAM_DIST", "")),
    Cookie = os:getenv("BEAM_COOKIE", ""),
    Nodes =:= [] andalso halt(0),
    Cookie =:= "" andalso fail("no cookie: BEAM_COOKIE is empty. Add to the job: "
                               "secret = BEAM_COOKIE=secret:BEAM_COOKIE, then: vigil secret set BEAM_COOKIE"),
    start(Nodes),
    Bad = lists:foldl(fun({Name, Node}, Acc) -> Acc + one(list_to_atom(Job), Name, Node, Cookie) end, 0, Nodes),
    halt(case Bad of 0 -> 0; _ -> 1 end);
main(_) ->
    io:format(standard_error, "usage: escript _beam.escript vm|processes|tables|dist|apps~n", []),
    halt(64).

%% "<name>=<node>;..." as [{Name, Node}].
targets(S) ->
    [case string:split(string:trim(P), "=") of
         [N, Node] -> {string:trim(N), list_to_atom(string:trim(Node))};
         _ -> fail(io_lib:format("BEAM_DIST: ~ts is not <name>=<node>, as in rabbit=rabbit@db1", [P]))
     end || P <- string:split(S, ";", all), string:trim(P) =/= ""].

%% This run's own node: long names if any node's host has a dot, as those
%% nodes must; a name of this process's id.
start(Nodes) ->
    Long = lists:any(fun({_, N}) -> lists:member($., host(N)) end, Nodes),
    Me = list_to_atom("vigil_" ++ os:getpid() ++ case Long of true -> "@127.0.0.1"; false -> "" end),
    Domain = case Long of true -> longnames; false -> shortnames end,
    case net_kernel:start(Me, #{name_domain => Domain}) of
        {ok, _} -> ok;
        {error, Why} -> fail(io_lib:format("cannot start this run's own node: ~p", [Why]))
    end.

host(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_, H] -> H;
        _ -> ""
    end.

%% One node: up 1 and what it says, or up 0. 1 when it refused the cookie.
one(Job, Name, Node, Cookie) ->
    erlang:set_cookie(Node, list_to_atom(Cookie)),
    T = [{"node", Name}, {"source", "dist"}],
    case net_kernel:connect_node(Node) of
        true ->
            metric("up", 1, T),
            try read(Job, Node, T)
            catch _:E -> say(io_lib:format("~ts: ~p answered, but reading it failed: ~p", [Name, Node, E]))
            end,
            0;
        _ ->
            metric("up", 0, T),
            case string:split(atom_to_list(Node), "@") of
                [NodeName, Host] ->
                    case erl_epmd:port_please(NodeName, Host, 5000) of
                        {port, _, _} ->
                            say(io_lib:format("~ts: epmd on ~ts lists ~ts, but ~p refused this run: BEAM_COOKIE "
                                              "is not its cookie, or ~p is not exactly its name (names are "
                                              "case-sensitive: beam.process shows each VM's)",
                                              [Name, Host, NodeName, Node, Node])),
                            1;
                        _ -> 0
                    end;
                _ -> 0
            end
    end.

call(Node, M, F, A) ->
    case rpc:call(Node, M, F, A, ?TIMEOUT) of
        {badrpc, Why} -> throw({M, F, length(A), Why});
        V -> V
    end.

%% A call that may fail on an older or smaller node: its value, or undefined.
try_call(Node, M, F, A) ->
    try call(Node, M, F, A) catch _:_ -> undefined end.

read(vm, Node, T) ->
    Mem = call(Node, erlang, memory, []),
    [metric("memory_bytes", V, T ++ [{"kind", atom_to_list(K)}])
     || {K, V} <- Mem, lists:member(K, [total, processes, system, atom, binary, code, ets])],
    metric("version", 1, T ++ [{"otp", call(Node, erlang, system_info, [otp_release])},
                               {"erts", call(Node, erlang, system_info, [version])}]),
    Info = fun(Key) -> case try_call(Node, erlang, system_info, [Key]) of V when is_integer(V) -> V; _ -> undefined end end,
    limit(T, "processes", Info(process_count), "process_limit", Info(process_limit), "process_pct"),
    limit(T, "ports", Info(port_count), "port_limit", Info(port_limit), "port_pct"),
    limit(T, "atoms", Info(atom_count), "atom_limit", Info(atom_limit), "atom_pct"),
    limit(T, "ets_tables", Info(ets_count), "ets_limit", Info(ets_limit), "ets_pct"),
    opt("schedulers_online", Info(schedulers_online), T),
    metric("run_queue", call(Node, erlang, statistics, [total_run_queue_lengths]), T),
    case try_call(Node, erlang, statistics, [run_queue_lengths_all]) of
        L when is_list(L), length(L) >= 3 ->
            [Cpu, Io] = lists:nthtail(length(L) - 2, L),
            metric("dirty_cpu_run_queue", Cpu, T),
            metric("dirty_io_run_queue", Io, T);
        _ -> ok
    end,
    {Reds, _} = call(Node, erlang, statistics, [reductions]),
    metric("reductions_count", Reds, T),
    {Gcs, Words, _} = call(Node, erlang, statistics, [garbage_collection]),
    metric("gcs_count", Gcs, T),
    metric("gc_reclaimed_bytes", Words * call(Node, erlang, system_info, [wordsize]), T),
    {Switches, _} = call(Node, erlang, statistics, [context_switches]),
    metric("context_switches_count", Switches, T),
    {{input, In}, {output, Out}} = call(Node, erlang, statistics, [io]),
    metric("received_bytes", In, T),
    metric("sent_bytes", Out, T),
    {Wall, _} = call(Node, erlang, statistics, [wall_clock]),
    metric("uptime_seconds", Wall div 1000, T);

read(processes, Node, T) ->
    %% Each process's mailbox, memory and reductions. Past MAX_PROCESSES,
    %% the first of them, which keeps a run in time on a node of millions.
    All = call(Node, erlang, processes, []),
    Pids = lists:sublist(All, ?MAX_PROCESSES),
    Keys = [registered_name, initial_call, current_function, message_queue_len, memory, reductions],
    Infos = [{P, I} || P <- Pids, I <- [rpc:call(Node, erlang, process_info, [P, Keys], ?TIMEOUT)], is_list(I)],
    metric("processes_read", length(Infos), T),
    metric("processes_not_read", length(All) - length(Pids), T),
    metric("mailbox_messages", lists:sum([v(message_queue_len, I) || {_, I} <- Infos]), T),
    metric("mailboxes_over_1000", length([x || {_, I} <- Infos, v(message_queue_len, I) > 1000]), T),
    Top = fun(Key, Metric, Floor) ->
                  Sorted = lists:sublist(lists:reverse(lists:keysort(3, [{P, I, v(Key, I)} || {P, I} <- Infos])), ?TOP),
                  [metric(Metric, N, T ++ [{"process", who(Node, P, I)}]) || {P, I, N} <- Sorted, N > Floor]
          end,
    Top(message_queue_len, "mailbox", 0),
    Top(memory, "process_memory_bytes", -1),
    Top(reductions, "process_reductions_count", -1),
    ok;

read(tables, Node, T) ->
    Word = call(Node, erlang, system_info, [wordsize]),
    Infos = [I || Tab <- call(Node, ets, all, []), I <- [try_call(Node, ets, info, [Tab])], is_list(I)],
    metric("tables", length(Infos), T),
    metric("objects", lists:sum([v(size, I) || I <- Infos]), T),
    metric("memory_bytes", lists:sum([v(memory, I) || I <- Infos]) * Word, T),
    Tag = fun(I) -> T ++ [{"table", table(I)}, {"owner", owner(Node, I)}] end,
    Big = lists:sublist(lists:reverse(lists:keysort(2, [{I, v(memory, I)} || I <- Infos])), ?TOP),
    [metric("table_memory_bytes", N * Word, Tag(I)) || {I, N} <- Big],
    Many = lists:sublist(lists:reverse(lists:keysort(2, [{I, v(size, I)} || I <- Infos])), ?TOP),
    [metric("table_objects", N, Tag(I)) || {I, N} <- Many],
    ok;

read(dist, Node, T) ->
    Visible = call(Node, erlang, nodes, [visible]),
    Hidden = [N || N <- call(Node, erlang, nodes, [hidden]), not lists:prefix("vigil_", atom_to_list(N))],
    metric("peers", length(Visible), T),
    metric("hidden_peers", length(Hidden), T),
    Ctrl = case try_call(Node, erlang, system_info, [dist_ctrl]) of L when is_list(L) -> L; _ -> [] end,
    Queue = fun(Peer) ->
                    case lists:keyfind(Peer, 1, Ctrl) of
                        {_, Port} when is_port(Port) ->
                            case try_call(Node, erlang, port_info, [Port, queue_size]) of {queue_size, Q} -> Q; _ -> undefined end;
                        _ -> undefined
                    end
            end,
    Shown = lists:sublist(Visible ++ Hidden, 100),
    [begin
         Tp = T ++ [{"peer", atom_to_list(P)}, {"hidden", atom_to_list(lists:member(P, Hidden))}],
         metric("peer", 1, Tp),
         opt("peer_queue_bytes", Queue(P), Tp)
     end || P <- Shown],
    metric("peers_not_shown", length(Visible) + length(Hidden) - length(Shown), T),
    opt("busy_limit_bytes", try_call(Node, erlang, system_info, [dist_buf_busy_limit]), T),
    ok;

read(apps, Node, T) ->
    Apps = call(Node, application, which_applications, []),
    metric("apps", length(Apps), T),
    [metric("app", 1, T ++ [{"app", atom_to_list(A)}, {"version", V}]) || {A, _, V} <- lists:sublist(Apps, 100)],
    metric("apps_not_shown", max(0, length(Apps) - 100), T),
    ok.

%% A count, its limit and how much of it is used.
limit(T, Name, N, LimitName, Limit, Pct) ->
    opt(Name, N, T),
    opt(LimitName, Limit, T),
    case is_integer(N) andalso is_integer(Limit) andalso Limit > 0 of
        true -> metric(Pct, list_to_float(float_to_list(100 * N / Limit, [{decimals, 2}])), T);
        false -> ok
    end.

opt(_, undefined, _) -> ok;
opt(Name, V, T) when is_integer(V) -> metric(Name, V, T);
opt(_, _, _) -> ok.

v(K, I) -> case lists:keyfind(K, 1, I) of {K, V} when is_integer(V) -> V; _ -> 0 end.

%% A process by its registered name, else what it was started as (a
%% gen_server's module, not proc_lib's), else, for a fun (erlang:apply/2),
%% the function it is in now.
who(Node, Pid, I) ->
    case lists:keyfind(registered_name, 1, I) of
        {_, N} when is_atom(N), N =/= [] -> atom_to_list(N);
        _ ->
            Get = fun(K) -> case lists:keyfind(K, 1, I) of {_, V} -> V; _ -> undefined end end,
            Initial = Get(initial_call),
            Translated = case Initial of
                             {proc_lib, init_p, 5} -> try_call(Node, proc_lib, translate_initial_call, [Pid]);
                             _ -> Initial
                         end,
            MFA = case Translated of
                      {proc_lib, init_p, 5} -> own_frame(Node, Pid, Get(current_function));
                      {erlang, apply, 2} -> own_frame(Node, Pid, Get(current_function));
                      {_, _, _} -> Translated;
                      _ -> own_frame(Node, Pid, Get(current_function))
                  end,
            case MFA of
                {M, F, A} -> lists:flatten(io_lib:format("~s:~s/~b", [M, F, A]));
                _ -> "unknown"
            end
    end.

%% The first frame of a process's stack in its own code, not in a library
%% it waits in (timer:sleep/1, gen_server:loop/7...).
own_frame(Node, Pid, Default) ->
    Library = [timer, erlang, gen, gen_server, gen_statem, gen_event, proc_lib, lists, io, io_lib,
               prim_inet, inet, gen_tcp, gen_udp, rpc, erpc, supervisor, application_master, sys],
    case try_call(Node, erlang, process_info, [Pid, current_stacktrace]) of
        {current_stacktrace, Stack} ->
            case [{M, F, A} || {M, F, A, _} <- Stack, is_integer(A), not lists:member(M, Library)] of
                [First | _] -> First;
                [] -> Default
            end;
        _ -> Default
    end.

table(I) ->
    case lists:keyfind(name, 1, I) of
        {_, N} ->
            case lists:keyfind(named_table, 1, I) of
                {_, true} -> atom_to_list(N);
                _ -> atom_to_list(N) ++ "(unnamed)"
            end;
        _ -> "unknown"
    end.

owner(Node, I) ->
    case lists:keyfind(owner, 1, I) of
        {_, P} when is_pid(P) ->
            case try_call(Node, erlang, process_info, [P, [registered_name, initial_call, current_function]]) of
                L when is_list(L) -> who(Node, P, L);
                _ -> "unknown"
            end;
        _ -> "unknown"
    end.

metric(Name, Value, Tags) ->
    io:format("metric ~s ~p~ts~n", [Name, Value, [[" ", K, "=", tag(V)] || {K, V} <- Tags]]).

%% A tag's value: no spaces, quotes or control characters, never empty.
tag(V) ->
    S = [case C of $\s -> $_; _ when C < 32 -> $_; _ -> C end
         || C <- lists:flatten(io_lib:format("~ts", [V])), C =/= $", C =/= $', C =/= $`],
    case S of "" -> "none"; _ -> lists:sublist(S, 120) end.

say(Msg) -> io:format(standard_error, "~ts~n", [Msg]).

fail(Msg) -> say(Msg), halt(1).
