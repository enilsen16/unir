%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Christopher S. Meiklejohn.  All Rights Reserved.
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
%%

-module(unir_SUITE).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

%% common_test callbacks
-export([suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0,
         groups/0,
         init_per_group/2]).

%% tests
-compile([export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-define(APP, unir).
-define(CLIENT_NUMBER, 3).
-define(PEER_PORT, 9000).
-define(SLEEP, 30000).
-define(PARALLELISM, 1).

-define(PREFIX, {unir, test}).
-define(KEY, key).
-define(VALUE, value).

-define(CHANNELS, [broadcast, vnode, {monotonic, gossip}]).

%% ===================================================================
%% common_test callbacks
%% ===================================================================

suite() ->
    [{timetrap, {hours, 10}}].

init_per_suite(_Config) ->
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(Case, Config) ->
    ct:pal("Beginning test case ~p", [Case]),
    [{hash, erlang:phash2({Case, Config})}|Config].

end_per_testcase(Case, Config) ->
    ct:pal("Ending test case ~p", [Case]),
    Config.

init_per_group(partisan, Config) ->
    [{partisan_dispatch, true}] ++ Config;
init_per_group(partisan_races, Config) ->
    [{partisan_dispatch, true}] ++ Config;
init_per_group(partisan_scale, Config) ->
    [{partisan_dispatch, true}] ++ Config;
init_per_group(partisan_large_scale, Config) ->
    [{partisan_dispatch, true}] ++ Config;
init_per_group(partisan_with_binary_padding, Config) ->
    [{partisan_dispatch, true}, {binary_padding, true}] ++ Config;
init_per_group(_, Config) ->
    Config.

end_per_group(_, _Config) ->
    ok.

all() ->
    [
     {group, default, []}
    ].

groups() ->
    [
     {basic, [],
      [membership_test, 
       metadata_test, 
       large_gossip_test,
       timing_test,
       transition_test, 
       vnode_test]},

     {default, [],
      [membership_test]
     },

     {disterl, [],
      [{group, basic}]
     },
     
     {partisan, [],
      [{group, basic}]
     },

     {races, [],
      [four_node_membership_test]},

     {partisan_races, [],
      [four_node_membership_test]},

     {scale, [],
      [scale_test]},

     {partisan_scale, [],
      [scale_test]},
     
     {large_scale, [],
      [large_scale_test]},

     {partisan_large_scale, [],
      [large_scale_test]},

     {partisan_with_binary_padding, [],
      [timing_test]}
    ].

%% ===================================================================
%% Tests.
%% ===================================================================

timing_test(Config) ->
    Nodes = start(timing_test,
                  Config,
                  [{num_nodes, 3},
                   {partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Verify partisan connection is configured with the correct
    %% membership information.
    ct:pal("Waiting for partisan membership..."),
    ?assertEqual(ok, wait_until_partisan_membership(SortedNodes)),

    %% Ensure we have the right number of connections.
    %% Verify appropriate number of connections.
    ct:pal("Waiting for partisan connections..."),
    ?assertEqual(ok, wait_until_all_connections(SortedNodes)),

    %% Send a bunch of messages.
    Self = self(),
    NumMessages = 10000,
    [Node1, Node2, _Node3] = SortedNodes,

    %% Register a local name for forwarding.
    Self = self(),
    LocalName = test,

    %% Use 64-byte binary to force shared heap usage.
    Padding = rand_bits(512),

    {Time, _} = timer:tc(fun() ->

            %% Spawn receiver process on Node2.
            ReceiverFun = fun() ->
                receive
                    {message, Padding, NumMessages} ->
                        Self ! done
                end
            end,
            ReceiverPid = rpc:call(Node2, erlang, spawn, [ReceiverFun]),

            %% Register name on Node2.
            true = rpc:call(Node2, erlang, register, [LocalName, ReceiverPid]),

            %% Spawn senders on Node1.
            ct:pal("Performing message dispatch."),
            lists:foreach(fun(X) ->
                spawn(fun() ->
                    ok = rpc:call(Node1, 
                                  riak_core_partisan_utils, 
                                  forward, 
                                  [vnode, Node2, LocalName, {message, Padding, X}])
                    end)
                end, lists:seq(1, NumMessages)),

            %% Wait for receipt acknowledgement.
            ct:pal("Waiting for receipt acknowledgement."),
            receive
                done ->
                    ok
            end

        end),

    ct:pal("Time for ~p messages: ~p", [NumMessages, Time]),

    stop(Nodes),

    ok.

large_scale_test(Config) ->
    case os:getenv("TRAVIS") of
        "true" ->
            Nodes = start(large_scale_test,
                          Config,
                          [{partisan_peer_service_manager,
                              partisan_default_peer_service_manager},
                          {num_nodes, 20},
                          {cluster_nodes, false}]),

            scale(Nodes);
        _ ->
            ct:pal("Skipping test; outside of the travis environment.")
    end,

    ok.

scale_test(Config) ->
    Nodes = start(scale_test,
                  Config,
                  [{partisan_peer_service_manager,
                    partisan_default_peer_service_manager},
                   {num_nodes, 10},
                   {cluster_nodes, false}]),

    scale(Nodes),

    ok.

transition_test(Config) ->
    Nodes = start(transition_test,
                  Config,
                  [{partisan_peer_service_manager,
                    partisan_default_peer_service_manager},
                   {num_nodes, 4},
                   {cluster_nodes, false}]),

    %% Get the list of nodes.
    [{_, Node1}, {_, Node2}, {_, Node3}, {_, Node4}] = Nodes,

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Cluster the first two ndoes.
    ?assertEqual(ok, join_cluster([Node1, Node2])),

    %% Verify appropriate number of connections.
    ?assertEqual(ok, wait_until_all_connections([Node1, Node2])),

    %% Perform metadata storage write.
    ?assertEqual(ok, metadata_write(Node1)),

    %% Join the third node.
    ?assertEqual(ok, staged_join(Node3, Node1)),

    %% Plan will only succeed once the ring has been gossiped.
    ?assertEqual(ok, plan_and_commit(Node1)),

    %% Verify appropriate number of connections.
    ?assertEqual(ok, wait_until_all_connections([Node1, Node2, Node3])),

    %% Join the fourth node.
    ?assertEqual(ok, staged_join(Node4, Node1)),

    %% Plan will only succeed once the ring has been gossiped.
    ?assertEqual(ok, plan_and_commit(Node1)),

    %% Verify appropriate number of connections.
    ?assertEqual(ok, wait_until_all_connections([Node1, Node2, Node3, Node4])),

    %% Verify that we can read that value at all nodes.
    ?assertEqual(ok, wait_until_metadata_read(SortedNodes)),

    %% Leave a node.
    ?assertEqual(ok, leave(Node3)),

    %% Verify appropriate number of connections.
    ?assertEqual(ok, wait_until_all_connections([Node1, Node2, Node4])),

    stop(Nodes),

    ok.

metadata_test(Config) ->
    Nodes = start(metadata_test,
                  Config,
                  [{partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Get the first node.
    [{_Name, Node}|_] = Nodes,

    %% Put a value into the metadata system.
    ?assertEqual(ok, metadata_write(Node)),

    %% Verify that we can read that value at all nodes.
    ?assertEqual(ok, wait_until_metadata_read(SortedNodes)),

    stop(Nodes),

    ok.

four_node_membership_test(Config) ->
    Nodes = start(four_node_membership_test,
                  Config,
                  [{num_nodes, 4},
                   {partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Verify partisan connection is configured with the correct
    %% membership information.
    ct:pal("Waiting for partisan membership..."),
    ?assertEqual(ok, wait_until_partisan_membership(SortedNodes)),

    %% Ensure we have the right number of connections.
    %% Verify appropriate number of connections.
    ct:pal("Waiting for partisan connections..."),
    ?assertEqual(ok, wait_until_all_connections(SortedNodes)),

    stop(Nodes),

    ok.

large_gossip_test(Config) ->
    Nodes = start(large_gossip_test,
                  Config,
                  [{num_nodes, 5},
                   {partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Verify partisan connection is configured with the correct
    %% membership information.
    ct:pal("Waiting for partisan membership..."),
    ?assertEqual(ok, wait_until_partisan_membership(SortedNodes)),

    %% Ensure we have the right number of connections.
    %% Verify appropriate number of connections.
    ct:pal("Waiting for partisan connections..."),
    ?assertEqual(ok, wait_until_all_connections(SortedNodes)),

    %% Bloat ring.
    ct:pal("Attempting to bloat the ring to see performance effect..."),
    Node1 = hd(SortedNodes),
    ok = rpc:call(Node1, riak_core_ring_manager, bloat_ring, []),

    %% Sleep for gossip rounds.
    ct:pal("Sleeping for 50 seconds..."),
    timer:sleep(50000),

    stop(Nodes),

    ok.

membership_test(Config) ->
    Nodes = start(membership_test,
                  Config,
                  [{num_nodes, 3},
                   {partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Verify partisan connection is configured with the correct
    %% membership information.
    ct:pal("Waiting for partisan membership..."),
    ?assertEqual(ok, wait_until_partisan_membership(SortedNodes)),

    %% Ensure we have the right number of connections.
    %% Verify appropriate number of connections.
    ct:pal("Waiting for partisan connections..."),
    ?assertEqual(ok, wait_until_all_connections(SortedNodes)),

    stop(Nodes),

    ok.

join_test(Config) ->
    Nodes = start(join_test,
                  Config,
                  [{num_nodes, 3},
                   {partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    stop(Nodes),

    ok.

vnode_test(Config) ->
    Nodes = start(vnode_test,
                  Config,
                  [{partisan_peer_service_manager,
                    partisan_default_peer_service_manager}]),

    SortedNodes = lists:usort([Node || {_Name, Node} <- Nodes]),

    %% Verify partisan connection is configured with the correct
    %% membership information.
    ct:pal("Waiting for partisan membership..."),
    ?assertEqual(ok, wait_until_partisan_membership(SortedNodes)),

    %% Ensure we have the right number of connections.
    %% Verify appropriate number of connections.
    ct:pal("Waiting for partisan connections..."),
    ?assertEqual(ok, wait_until_all_connections(SortedNodes)),

    %% Get the list of nodes.
    ct:pal("Nodes is: ~p", [Nodes]),
    [{_, Node1}, {_, _Node2}, {_, _Node3}] = Nodes,

    %% Attempt to access the vnode request API.
    %% This will test command/3 and command/4 behavior.
    ct:pal("Waiting for response from ping command..."),
    CommandResult = rpc:call(Node1, unir, ping, []),
    ?assertEqual(ok, CommandResult),

    %% Attempt to access the vnode request API.
    %% This will test sync_command/3 and sync_command/4 behavior.
    ct:pal("Waiting for response from sync_ping command..."),
    SyncCommandResult = rpc:call(Node1, unir, sync_ping, []),
    ?assertMatch({pong, _}, SyncCommandResult),

    %% Attempt to access the vnode request API.
    %% This will test sync_spawn_command/3 and sync_spawn_command/4 behavior.
    ct:pal("Waiting for response from sync_spawn_ping command..."),
    SyncSpawnCommandResult = rpc:call(Node1, unir, sync_spawn_ping, []),
    ?assertMatch({pong, _}, SyncSpawnCommandResult),

    stop(Nodes),

    ok.

%% ===================================================================
%% Internal functions.
%% ===================================================================

%% @private
stop(Nodes) ->
    StopFun = fun({Name, _Node}) ->
        ct:pal("Stopping node: ~p", [Name]),

        case ct_slave:stop(Name) of
            {ok, _} ->
                ok;
            {error, stop_timeout, _} ->
                ok;
            Error ->
                ct:fail(Error)
        end
    end,
    lists:map(StopFun, Nodes),
    ok.

%% @private
codepath() ->
    lists:filter(fun filelib:is_dir/1, code:get_path()).

%% @private
start(_Case, Config, Options) ->
    %% Launch distribution for the test runner.
    ct:pal("Launching Erlang distribution..."),

    os:cmd(os:find_executable("epmd") ++ " -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@" ++ Hostname), shortnames]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end,

    %% Load sasl.
    application:load(sasl),
    ok = application:set_env(sasl, sasl_error_logger, false),
    application:start(sasl),

    %% Load lager.
    {ok, _} = application:ensure_all_started(lager),

    %% Generate node names.
    NumNodes = proplists:get_value(num_nodes, Options, 3),
    NodeNames = node_list(NumNodes, "node", Config),

    %% Start all nodes.
    InitializerFun = fun(Name) ->
                            ct:pal("Starting node: ~p", [Name]),

                            NodeConfig = [{monitor_master, true},
                                          {erl_flags, "-smp"}, %% smp for the eleveldb god

                                          {startup_functions,
                                           [{code, set_path, [codepath()]}]}],

                            case ct_slave:start(Name, NodeConfig) of
                                {ok, Node} ->
                                    {Name, Node};
                                Error ->
                                    ct:fail(Error)
                            end
                     end,
    Nodes = lists:map(InitializerFun, NodeNames),

    %% Load applications on all of the nodes.
    LoaderFun = fun({Name, Node}) ->
                            % ct:pal("Loading applications on node: ~p", [Node]),

                            PrivDir = proplists:get_value(priv_dir, Config),
                            NodeDir = filename:join([PrivDir, Node]),

                            %% Manually force sasl loading, and disable the logger.
                            ok = rpc:call(Node, application, load, [sasl]),
                            ok = rpc:call(Node, application, set_env, [sasl, sasl_error_logger, false]),
                            ok = rpc:call(Node, application, start, [sasl]),

                            ok = rpc:call(Node, application, load, [partisan]),
                            ok = rpc:call(Node, application, load, [lager]),
                            ok = rpc:call(Node, application, load, [riak_core]),
                            ok = rpc:call(Node, application, set_env, [lager, log_root, NodeDir]),

                            % ct:print("Node dir: ~p", [NodeDir]),

                            PlatformDir = NodeDir ++ "/data/",
                            RingDir = PlatformDir ++ "/ring/",
                            NumberOfVNodes = 1024,

                            %% Eagerly create incase it doesn't exist
                            %% and delete to remove any state that
                            %% remains between test executions.
                            filelib:ensure_dir(PlatformDir),
                            del_dir(PlatformDir),

                            %% Recreate directories before starting
                            %% Riak Core.
                            filelib:ensure_dir(PlatformDir),
                            filelib:ensure_dir(RingDir),

                            ok = rpc:call(Node, application, set_env, [riak_core, cluster_name, "unir"]),
                            ok = rpc:call(Node, application, set_env, [riak_core, riak_state_dir, RingDir]),
                            ok = rpc:call(Node, application, set_env, [riak_core, ring_creation_size, NumberOfVNodes]),

                            ok = rpc:call(Node, application, set_env, [riak_core, platform_data_dir, PlatformDir]),
                            ok = rpc:call(Node, application, set_env, [riak_core, handoff_ip, "127.0.0.1"]),
                            ok = rpc:call(Node, application, set_env, [riak_core, handoff_port, web_ports(Name) + 3]),

                            ok = rpc:call(Node, application, set_env, [riak_core, schema_dirs, ["../../../../_build/default/rel/unir/share/schema/"]]),

                            ok = rpc:call(Node, application, set_env, [riak_api, pb_port, web_ports(Name) + 2]),
                            ok = rpc:call(Node, application, set_env, [riak_api, pb_ip, "127.0.0.1"])
                     end,
    lists:map(LoaderFun, Nodes),

    %% Configure settings.
    ConfigureFun = fun({_Name, Node}) ->
            %% Configure the peer service.
            PeerService = proplists:get_value(partisan_peer_service_manager, Options),
            ok = rpc:call(Node, partisan_config, set, [partisan_peer_service_manager, PeerService]),

            %% Configure binary padding in Riak Core.
            BinaryPadding = ?config(binary_padding, Config),
            case BinaryPadding of
                true ->
                    ok = rpc:call(Node, partisan_config, set, [binary_padding, BinaryPadding]),
                    ct:pal("Enabling binary padding.");
                _ ->
                    ok
            end,

            %% Configure partisan dispatch in Riak Core.
            PartisanDispatch = ?config(partisan_dispatch, Config),
            case PartisanDispatch of
                true ->
                    ct:pal("Enabling partisan dispatch on node ~p!", [Node]);
                _ ->
                    ok
            end,
            ok = rpc:call(Node, application, set_env, [riak_core, partisan_dispatch, PartisanDispatch]),

            MaxActiveSize = proplists:get_value(max_active_size, Options, 5),
            ok = rpc:call(Node, partisan_config, set, [persist_state, false]),
            ok = rpc:call(Node, partisan_config, set, [max_active_size, MaxActiveSize]),
            ok = rpc:call(Node, partisan_config, set, [tls, ?config(tls, Config)]),
            ok = rpc:call(Node, partisan_config, set, [parallelism, ?PARALLELISM]),
            ok = rpc:call(Node, partisan_config, set, [channels, ?CHANNELS]),
            ok = rpc:call(Node, partisan_config, set, [gossip, false])
    end,
    lists:foreach(ConfigureFun, Nodes),

    ct:pal("Starting nodes."),

    StartFun = fun({_Name, Node}) ->
                        %% Start partisan.
                        {ok, _} = rpc:call(Node,
                                           application, ensure_all_started,
                                           [partisan]),

                        %% Start riak_core.
                        CoreResult = rpc:call(Node,
                                              application, ensure_all_started,
                                              [riak_core]),
                        case CoreResult of
                            {ok, _} ->
                                ok;
                            Error ->
                                ct:pal("Riak Core failed to start: ~p",
                                       [Error]),
                                ct:fail(riak_core_failure)
                        end,

                        %% Start unir.
                        {ok, _}  = rpc:call(Node,
                                            application, ensure_all_started,
                                            [?APP]),
                        ct:pal("Started node ~p", [Node])
               end,
    lists:foreach(StartFun, Nodes),

    %% Determine if we should cluster the nodes or not.
    ClusterNodes = proplists:get_value(cluster_nodes, Options, true),
    case ClusterNodes of
        true ->
            ct:pal("Clustering nodes."),
            ok = join_cluster([Node || {_Name, Node} <- Nodes]);
        false ->
            ct:pal("Skipping cluster formation.")
    end,

    ct:pal("Nodes fully initialized: ~p", [Nodes]),

    Nodes.

%% @private
node_list(0, _Name, _Config) -> [];
node_list(N, Name, _Config) ->
    [ list_to_atom(string:join([Name,
                                integer_to_list(X)],
                               "_")) ||
        X <- lists:seq(1, N) ].

%% @private
web_ports(Name) ->
    NameList = atom_to_list(Name),
    [_|[Number]] = string:tokens(NameList, "_"),
    10005 + (list_to_integer(Number) * 10).

%% @private
join_cluster(Nodes) ->
    %% Ensure each node owns 100% of it's own ring
    [?assertEqual([Node], owners_according_to(Node)) || Node <- Nodes],

    %% Join nodes
    [Node1|OtherNodes] = Nodes,
    case OtherNodes of
        [] ->
            %% no other nodes, nothing to join/plan/commit
            ok;
        _ ->
            case length(Nodes) > 2 of
                true ->
                    %% ok do a staged join and then commit it, this eliminates the
                    %% large amount of redundant handoff done in a sequential join
                    [staged_join(Node, Node1) || Node <- OtherNodes],

                    %% Sleep for partisan connections to be setup.
                    timer:sleep(?SLEEP),

                    plan_and_commit(Node1),

                    try_nodes_ready(Nodes, 3, 500);
                false ->
                    %% do the standard join.
                    [join(Node, Node1) || Node <- OtherNodes]
            end
    end,

    ?assertEqual(ok, wait_until_nodes_ready(Nodes)),

    %% Ensure each node owns a portion of the ring
    ?assertEqual(ok, wait_until_nodes_agree_about_ownership(Nodes)),
    ?assertEqual(ok, wait_until_no_pending_changes(Nodes)),
    ?assertEqual(ok, wait_until_ring_converged(Nodes)),

    ok.

%% @private
owners_according_to(Node) ->
    case rpc:call(Node, riak_core_ring_manager, get_raw_ring, []) of
        {ok, Ring} ->
            % lager:info("Ring ~p", [Ring]),
            Owners = [Owner || {_Idx, Owner} <- riak_core_ring:all_owners(Ring)],
            % lager:info("Owners according to ~p: ~p", [Node, lists:usort(Owners)]),
            lists:usort(Owners);
        {badrpc, _}=BadRpc ->
            lager:info("Badrpc"),
            BadRpc
    end.

%% @private
join(Node, PNode) ->
    timer:sleep(5000),
    R = rpc:call(Node, riak_core, join, [PNode]),
    lager:info("[join] ~p to (~p): ~p", [Node, PNode, R]),
    ?assertEqual(ok, R),
    ok.

%% @private
staged_join(Node, PNode) ->
    timer:sleep(5000),
    R = rpc:call(Node, riak_core, staged_join, [PNode]),
    lager:info("[join] ~p to (~p): ~p", [Node, PNode, R]),
    ?assertEqual(ok, R),
    ok.

%% @private
plan_and_commit(Node) ->
    timer:sleep(5000),
    % lager:info("planning and committing cluster join"),
    case rpc:call(Node, riak_core_claimant, plan, []) of
        {error, ring_not_ready} ->
            ct:pal("plan: ring not ready"),
            timer:sleep(5000),
            maybe_wait_for_changes(Node),
            plan_and_commit(Node);
        {ok, _Actions, _RingTransitions} ->
            % ct:pal("Actions for ring transition: ~p", [Actions]),
            do_commit(Node);
        Other ->
            ct:fail("Claimant returned: ~p", [Other])
    end.

%% @private
do_commit(Node) ->
    % lager:info("Committing"),
    case rpc:call(Node, riak_core_claimant, commit, []) of
        {error, plan_changed} ->
            lager:info("commit: plan changed"),
            timer:sleep(100),
            maybe_wait_for_changes(Node),
            plan_and_commit(Node);
        {error, ring_not_ready} ->
            lager:info("commit: ring not ready"),
            timer:sleep(100),
            maybe_wait_for_changes(Node),
            do_commit(Node);
        {error, nothing_planned} ->
            %% Keep waiting...
            % ct:pal("Nothing planned!"),
            plan_and_commit(Node);
        ok ->
            ok
    end.

%% @private
try_nodes_ready([Node1 | _Nodes], 0, _SleepMs) ->
      lager:info("Nodes not ready after initial plan/commit, retrying"),
      plan_and_commit(Node1);
try_nodes_ready(Nodes, N, SleepMs) ->
      ReadyNodes = [Node || Node <- Nodes, is_ready(Node) =:= true],

      case ReadyNodes of
          Nodes ->
              ok;
          _ ->
              timer:sleep(SleepMs),
              try_nodes_ready(Nodes, N-1, SleepMs)
      end.

%% @private
maybe_wait_for_changes(Node) ->
    wait_until_no_pending_changes([Node]).

%% @private
wait_until_no_pending_changes(Nodes) ->
    % lager:info("Wait until no pending changes on ~p", [Nodes]),
    F = fun() ->
                rpc:multicall(Nodes, riak_core_vnode_manager, force_handoffs, []),
                {Rings, BadNodes} = rpc:multicall(Nodes, riak_core_ring_manager, get_raw_ring, []),
                Changes = [ riak_core_ring:pending_changes(Ring) =:= [] || {ok, Ring} <- Rings ],
                BadNodes =:= [] andalso length(Changes) =:= length(Nodes) andalso lists:all(fun(T) -> T end, Changes)
        end,
    ?assertEqual(ok, wait_until(F)),
    ok.

%% @private
wait_until(Fun) when is_function(Fun) ->
    MaxTime = 600000, %% @TODO use config,
        Delay = 1000, %% @TODO use config,
        Retry = MaxTime div Delay,
    wait_until(Fun, Retry, Delay).

%% @private
wait_until_nodes_ready(Nodes) ->
    % lager:info("Wait until nodes are ready : ~p", [Nodes]),
    [?assertEqual(ok, wait_until(Node, fun is_ready/1)) || Node <- Nodes],
    ok.

%% @private
is_ready(Node) ->
    case rpc:call(Node, riak_core_ring_manager, get_raw_ring, []) of
        {ok, Ring} ->
            case lists:member(Node, riak_core_ring:ready_members(Ring)) of
                true ->
                    true;
                false ->
                    {not_ready, Node}
            end;
        Other ->
            Other
    end.

%% @private
wait_until_nodes_agree_about_ownership(Nodes) ->
    ct:pal("Wait until nodes agree about ownership ~p", [Nodes]),
    Results = [ wait_until_owners_according_to(Node, Nodes) || Node <- Nodes ],
    ?assert(lists:all(fun(X) -> ok =:= X end, Results)).

%% @private
wait_until(Node, Fun) when is_atom(Node), is_function(Fun) ->
    wait_until(fun() -> Fun(Node) end).

%% @private
wait_until_owners_according_to(Node, Nodes) ->
    ct:pal("Waiting until node ~p agrees ownership on ~p", [Node, Nodes]),
  SortedNodes = lists:usort(Nodes),
  F = fun(N) ->
      owners_according_to(N) =:= SortedNodes
  end,
  ?assertEqual(ok, wait_until(Node, F)),
  ok.

%% @private
is_ring_ready(Node) ->
    case rpc:call(Node, riak_core_ring_manager, get_raw_ring, []) of
        {ok, Ring} ->
            riak_core_ring:ring_ready(Ring);
        _ ->
            false
    end.

%% @private
wait_until_ring_converged(Nodes) ->
    % lager:info("Wait until ring converged on ~p", [Nodes]),
    [?assertEqual(ok, wait_until(Node, fun is_ring_ready/1)) || Node <- Nodes],
    ok.

%% @private
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    wait_until_result(Fun, true, Retry, Delay).

%% @private
wait_until_result(Fun, Result, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        Result ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until_result(Fun, Result, Retry-1, Delay)
    end.

%% @private
del_dir(Dir) ->
   lists:foreach(fun(D) ->
                    ok = file:del_dir(D)
                 end, del_all_files([Dir], [])).

%% @private
del_all_files([], EmptyDirs) ->
   EmptyDirs;
del_all_files([Dir | T], EmptyDirs) ->
   {ok, FilesInDir} = file:list_dir(Dir),
   {Files, Dirs} = lists:foldl(fun(F, {Fs, Ds}) ->
                                  Path = Dir ++ "/" ++ F,
                                  case filelib:is_dir(Path) of
                                     true ->
                                          {Fs, [Path | Ds]};
                                     false ->
                                          {[Path | Fs], Ds}
                                  end
                               end, {[],[]}, FilesInDir),
   lists:foreach(fun(F) ->
                         ok = file:delete(F)
                 end, Files),
   del_all_files(T ++ Dirs, [Dir | EmptyDirs]).

%% @private
verify_open_connections(Me, Others, Connections) ->
    %% Verify we have connections to the peers we should have.
    R = lists:map(fun(Other) ->
                        OtherName = rpc:call(Other, partisan_peer_service_manager, myself, []),
                        DesiredConnections = ?PARALLELISM * (length(?CHANNELS) + 1),
                        case dict:find(OtherName, Connections) of
                            {ok, Active} ->
                                case length(Active) of
                                    DesiredConnections ->
                                        true;
                                    _ ->
                                        false
                                end;
                            error ->
                                false
                        end
                  end, Others -- [Me]),

    OthersOpen = lists:all(fun(X) -> X =:= true end, R),

    %% Verify we don't have connetions to ourself.
    SelfOpen = case dict:find(Me, Connections) of
        {ok, _} ->
            false;
        error ->
            true
    end,

    SelfOpen andalso OthersOpen.

%% @private
verify_all_connections(Nodes) ->
    R = lists:map(fun(Node) ->
                        case rpc:call(Node, partisan_peer_service, connections, []) of
                            {ok, Connections} ->
                                verify_open_connections(Node, Nodes, Connections);
                            _ ->
                                false

                          end
                  end, Nodes),

    lists:all(fun(X) -> X =:= true end, R).

%% @private
wait_until_all_connections(Nodes) ->
    F = fun() ->
                verify_all_connections(Nodes)
        end,
    wait_until(F).

%% @private
verify_partisan_membership(Nodes) ->
    R = lists:map(fun(Node) ->
                          case rpc:call(Node, partisan_peer_service, members, []) of
                            {ok, JoinedNodes} ->
                                  case lists:usort(JoinedNodes) =:= Nodes of
                                      true ->
                                          true;
                                      false -> 
                                          ct:pal("Membership on node ~p is not right: ~p but should be ~p", [Node, JoinedNodes, Nodes]),
                                          false
                                  end;
                            Error ->
                                  ct:fail("Cannot retrieve membership: ~p", [Error])
                          end
                  end, Nodes),

    lists:all(fun(X) -> X =:= true end, R).

%% @private
wait_until_partisan_membership(Nodes) ->
    F = fun() ->
                verify_partisan_membership(Nodes)
        end,
    wait_until(F).

%% @private
wait_until_metadata_read(Nodes) ->
    F = fun() ->
                verify_metadata_read(Nodes)
        end,
    wait_until(F).

%% @private
verify_metadata_read(Nodes) ->
    %% Verify that we can read that value at all nodes.
    R = lists:map(fun(Node) ->
                          case rpc:call(Node, riak_core_metadata, get, [?PREFIX, ?KEY]) of
                              ?VALUE ->
                                  true;
                              _ ->
                                  false
                          end
                  end,  Nodes),

    lists:all(fun(X) -> X =:= true end, R).

%% @private
metadata_write(Node) ->
    case rpc:call(Node, riak_core_metadata, put, [?PREFIX, ?KEY, ?VALUE]) of
        ok ->
            ok;
        _ ->
            error
    end.

%% @private
leave(Node) ->
    case rpc:call(Node, riak_core, leave, []) of
        ok ->
            ok;
        _ ->
            error
    end.

%% @private
scale(Nodes) ->
    [{_, Node1}, {_, Node2}|ToBeJoined] = Nodes,
    InitialCluster = [Node1, Node2],

    %% Cluster the first two ndoes.
    ct:pal("Building initial cluster: ~p", [InitialCluster]),
    ?assertEqual(ok, join_cluster(InitialCluster)),

    %% Verify appropriate number of connections.
    ct:pal("Verifying connections for initial cluster: ~p", [InitialCluster]),
    ?assertEqual(ok, wait_until_all_connections(InitialCluster)),

    lists:foldl(fun({_, Node}, CurrentCluster) ->
        %% Join another node.
        ct:pal("Joining ~p to ~p", [Node, Node1]),
        ?assertEqual(ok, staged_join(Node, Node1)),

        %% Plan will only succeed once the ring has been gossiped.
        ct:pal("Committing plan."),
        ?assertEqual(ok, plan_and_commit(Node1)),

        %% Verify appropriate number of connections.
        NewCluster = CurrentCluster ++ [Node],
        ct:pal("Verifying connections for expanded cluster: ~p", [NewCluster]),
        ?assertEqual(ok, wait_until_all_connections(NewCluster)),

        %% Ensure each node owns a portion of the ring
        ?assertEqual(ok, wait_until_nodes_agree_about_ownership(NewCluster)),
        ?assertEqual(ok, wait_until_no_pending_changes(NewCluster)),
        ?assertEqual(ok, wait_until_ring_converged(NewCluster)),

        NewCluster
    end, InitialCluster, ToBeJoined),

    %% Print final member status to the log.
    rpc:call(Node1, riak_core_console, member_status, [[]]),
    
    stop(Nodes),

    ok.

%% @private
rand_bits(Bits) ->
        Bytes = (Bits + 7) div 8,
        <<Result:Bits/bits, _/bits>> = crypto:rand_bytes(Bytes),
        Result.