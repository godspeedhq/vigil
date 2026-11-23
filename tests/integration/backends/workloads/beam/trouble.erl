%% Copyright (c) Bankole Ogundero and the Vigil contributors
%% SPDX-License-Identifier: Apache-2.0
%%
%% Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
%% implied. Run it at your own risk: review it first, and test it before you
%% rely on it. In no event shall the authors or copyright holders be liable
%% for any claim, damages or other liability arising from its use. See the
%% LICENSE file for the full terms.
%%
%% trouble.erl - an Erlang node in trouble on purpose, for the beam pack's
%% tests (scripts/run-beam.sh): every problem the pack is meant to see,
%% growing slowly. -s trouble start starts them all.
-module(trouble).
-export([start/0, crash/1]).

start() ->
    %% A mailbox nobody reads: 50 messages a second.
    Slow = spawn(fun() -> receive never -> ok end end),
    register(slow_consumer, Slow),
    spawn(fun() -> feed(Slow) end),
    %% A cache that never evicts: 100 rows a second.
    spawn(fun() -> ets:new(leaky_cache, [named_table, public, set]), cache(0) end),
    %% Atoms made from input: 20 a second.
    spawn(fun() -> atoms(0) end),
    %% A process holding binaries.
    register(hoarder, spawn(fun() -> hoard([]) end)),
    %% A busy loop.
    register(spinner, spawn(fun spin/0)),
    %% Processes started and never stopped: 5 a second.
    spawn(fun leak/0),
    ok.

feed(P) -> P ! {work, os:timestamp()}, timer:sleep(20), feed(P).
cache(N) -> ets:insert(leaky_cache, {N, lists:duplicate(10, N)}), timer:sleep(10), cache(N + 1).
atoms(N) -> _ = list_to_atom("vigil_leak_" ++ integer_to_list(N)), timer:sleep(50), atoms(N + 1).
hoard(L) when length(L) < 200 -> timer:sleep(500), hoard([binary:copy(<<1>>, 65536) | L]);
hoard(L) -> timer:sleep(1000), hoard(L).
spin() -> spin(0).
spin(N) when N > 100000000 -> spin(0);
spin(N) -> spin(N + 1).
leak() -> spawn(fun() -> receive never -> ok end end), timer:sleep(200), leak().

%% Dies, as a VM does: of atoms (run with +t 20000), or of memory (run
%% under ulimit -v).
crash(atoms) -> [list_to_atom("boom_" ++ integer_to_list(I)) || I <- lists:seq(1, 10000000)];
crash(memory) -> grow([]).
grow(L) -> grow([lists:seq(1, 100000) | L]).
