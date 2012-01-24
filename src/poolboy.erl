%% Poolboy - A hunky Erlang worker pool factory

-module(poolboy).
-behaviour(gen_fsm).

-export([start_link/1, checkout/1, checkout/2, checkout/3, checkin/2]).
-export([init/1, ready/2, ready/3, overflow/2, overflow/3, full/2, full/3,
         handle_event/3, handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).

-define(TIMEOUT, 5000).

-record(state, {workers, worker_sup, waiting=queue:new(), monitors=[],
                size=5, overflow=0, max_overflow=10}).

checkout(Pool) ->
    checkout(Pool, true, ?TIMEOUT).

checkout(Pool, Block) ->
    checkout(Pool, Block, ?TIMEOUT).

checkout(Pool, Block, Timeout) ->
    gen_fsm:sync_send_event(Pool, {checkout, Block}, Timeout).

checkin(Pool, Worker) ->
    gen_fsm:send_event(Pool, {checkin, Worker}).

start_link(Args) ->
    case proplists:get_value(name, Args) of
        undefined ->
            gen_fsm:start_link(?MODULE, Args, []);
        Name ->
            gen_fsm:start_link(Name, ?MODULE, Args, [])
    end.

init(Args) ->
    process_flag(trap_exit, true),
    init(Args, #state{}).

init([{worker_module, Mod} | Rest], State) ->
    {ok, Sup} = poolboy_sup:start_link(Mod, Rest),
    init(Rest, State#state{worker_sup=Sup});
init([{size, PoolSize} | Rest], State) ->
    init(Rest, State#state{size=PoolSize});
init([{max_overflow, MaxOverflow} | Rest], State) ->
    init(Rest, State#state{max_overflow=MaxOverflow});
init([_ | Rest], State) ->
    init(Rest, State);
init([], #state{size=Size, worker_sup=Sup}=State) ->
    Workers = prepopulate(Size, Sup),
    {ok, ready, State#state{workers=Workers}}.

ready({checkin, Pid}, State) ->
    Workers = queue:in(Pid, State#state.workers),
    Monitors = case lists:keytake(Pid, 1, State#state.monitors) of
        {value, {_, Ref}, Left} -> erlang:demonitor(Ref), Left;
        false -> State#state.monitors
    end,
    NewState = State#state{workers=Workers, monitors=Monitors},
    send_metrics(NewState),
    {next_state, ready, NewState};
ready(_Event, State) ->
    {next_state, ready, State}.

ready({checkout, Block}, {FromPid, _}=From, #state{workers=Workers,
                                                   worker_sup=Sup,
                                                   max_overflow=MaxOverflow
                                                   }=State) ->
    case queue:out(Workers) of
        {{value, Pid}, Left} ->
            Ref = erlang:monitor(process, FromPid),
            Monitors = [{Pid, Ref} | State#state.monitors],
            {reply, Pid, ready, State#state{workers=Left,
                                            monitors=Monitors}};
        {empty, Empty} when MaxOverflow > 0 ->
            {Pid, Ref} = new_worker(Sup, FromPid),
            Monitors = [{Pid, Ref} | State#state.monitors],
            {reply, Pid, overflow, State#state{workers=Empty,
                                               monitors=Monitors,
                                               overflow=1}};
        {empty, Empty} when Block =:= false ->
            {reply, full, full, State#state{workers=Empty}};
        {empty, Empty} ->
            Waiting = State#state.waiting,
            {next_state, full, State#state{workers=Empty,
                                           waiting=queue:in(From, Waiting)}}
    end;
ready(_Event, _From, State) ->
    {reply, ok, ready, State}.

overflow({checkin, Pid}, #state{overflow=1}=State) ->
    dismiss_worker(Pid),
    Monitors = case lists:keytake(Pid, 1, State#state.monitors) of
        {value, {_, Ref}, Left} -> erlang:demonitor(Ref), Left;
        false -> []
    end,
    NewState = State#state{overflow=0, monitors=Monitors},
    send_metrics(NewState),
    {next_state, ready, NewState};
overflow({checkin, Pid}, #state{overflow=Overflow}=State) ->
    dismiss_worker(Pid),
    Monitors = case lists:keytake(Pid, 1, State#state.monitors) of
        {value, {_, Ref}, Left} -> erlang:demonitor(Ref), Left;
        false -> State#state.monitors
    end,
    NewState = State#state{overflow=Overflow-1, monitors=Monitors},
    send_metrics(NewState),
    {next_state, overflow, NewState};
overflow(_Event, State) ->
    {next_state, overflow, State}.

overflow({checkout, Block}, From, #state{overflow=Overflow,
                                         max_overflow=MaxOverflow
                                         }=State) when Overflow >= MaxOverflow ->
    case Block of
        false ->
            {reply, full, full, State};
        Block ->
            Waiting = State#state.waiting,
            {next_state, full, State#state{waiting=queue:in(From, Waiting)}}
    end;
overflow({checkout, _Block}, {From, _},
         #state{worker_sup=Sup, overflow=Overflow}=State) ->
    {Pid, Ref} = new_worker(Sup, From),
    Monitors = [{Pid, Ref} | State#state.monitors],
    {reply, Pid, overflow, State#state{monitors=Monitors,
                                       overflow=Overflow+1}};
overflow(_Event, _From, State) ->
    {reply, ok, overflow, State}.

full({checkin, Pid}, #state{waiting=Waiting, max_overflow=MaxOverflow,
                            overflow=Overflow}=State) ->
    Monitors = case lists:keytake(Pid, 1, State#state.monitors) of
        {value, {_, Ref0}, Left0} -> erlang:demonitor(Ref0), Left0;
        false -> State#state.monitors
    end,
    {next_state, StateName, NewState} =
        case queue:out(Waiting) of
            {{value, {FromPid, _}=From}, Left} ->
                Ref = erlang:monitor(process, FromPid),
                Monitors1 = [{Pid, Ref} | Monitors],
                gen_fsm:reply(From, Pid),
                {next_state, full, State#state{waiting=Left,
                                               monitors=Monitors1}};
            {empty, Empty} when MaxOverflow < 1 ->
                Workers = queue:in(Pid, State#state.workers),
                {next_state, ready, State#state{workers=Workers, waiting=Empty,
                                                monitors=Monitors}};
            {empty, Empty} ->
                dismiss_worker(Pid),
                {next_state, overflow, State#state{waiting=Empty,
                                                   monitors=Monitors,
                                                   overflow=Overflow-1}}
        end,
    send_metrics(NewState),
    {next_state, StateName, NewState};
full(_Event, State) ->
    {next_state, full, State}.

full({checkout, false}, _From, State) ->
    {reply, full, full, State};
full({checkout, _Block}, From, #state{waiting=Waiting}=State) ->
    {next_state, full, State#state{waiting=queue:in(From, Waiting)}};
full(_Event, _From, State) ->
    {reply, ok, full, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(get_avail_workers, _From, StateName,
                  #state{workers=Workers}=State) ->
    WorkerList = queue:to_list(Workers),
    {reply, WorkerList, StateName, State};
handle_sync_event(get_all_workers, _From, StateName,
                  #state{worker_sup=Sup}=State) ->
    WorkerList = supervisor:which_children(Sup),
    {reply, WorkerList, StateName, State};
handle_sync_event(get_all_monitors, _From, StateName,
                  #state{monitors=Monitors}=State) ->
    {reply, Monitors, StateName, State};
handle_sync_event(stop, _From, _StateName, #state{worker_sup=Sup}=State) ->
    exit(Sup, shutdown),
    {stop, normal, ok, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = {error, invalid_message},
    {reply, Reply, StateName, State}.
handle_info({'DOWN', Ref, _, _, _}, StateName, State) ->
    send_metric(<<"poolboy.DOWN_rate">>, 1, meter),
    %% why isn't this lists:keytake? We're going to kill the Pid, but
    %% leave garbage in State#state.monitors?  Also, we link *and*
    %% monitor the Pids, why? When we clean dismiss a Pid, we unlink
    %% and then stop it, but shouldn't we also demonitor as part of
    %% the dismissal so that we don't have to process an extra DOWN
    %% message?
    case lists:keyfind(Ref, 2, State#state.monitors) of
        {Pid, Ref} ->
            exit(Pid, kill),
            {next_state, StateName, State};
        false ->
            {next_state, StateName, State}
    end;
handle_info({'EXIT', Pid, _}, StateName, #state{worker_sup=Sup,
                                                overflow=Overflow,
                                                waiting=Waiting,
                                                max_overflow=MaxOverflow
                                                }=State) ->
    send_metric(<<"poolboy.EXIT_rate">>, 1, meter),
    Monitors = case lists:keytake(Pid, 1, State#state.monitors) of
        {value, {_, Ref}, Left} -> erlang:demonitor(Ref), Left;
        false -> []
    end,
    {next_state, NewName, NewState} =
        case StateName of
            ready ->
                W = queue:filter(fun (P) -> P =/= Pid end, State#state.workers),
                {next_state, ready, State#state{workers=queue:in(new_worker(Sup), W),
                                                monitors=Monitors}};
            overflow when Overflow =< 1 ->
                {next_state, ready, State#state{monitors=Monitors, overflow=0}};
            overflow ->
                {next_state, overflow, State#state{monitors=Monitors,
                                                   overflow=Overflow-1}};
            full when MaxOverflow < 1 ->
                case queue:out(Waiting) of
                    {{value, {FromPid, _}=From}, LeftWaiting} ->
                        MonitorRef = erlang:monitor(process, FromPid),
                        Monitors2 = [{FromPid, MonitorRef} | Monitors],
                        gen_fsm:reply(From, new_worker(Sup)),
                        {next_state, full, State#state{waiting=LeftWaiting,
                                                       monitors=Monitors2}};
                    {empty, Empty} ->
                        Workers2 = queue:in(new_worker(Sup), State#state.workers),
                        {next_state, ready, State#state{monitors=Monitors,
                                                        waiting=Empty,
                                                        workers=Workers2}}
                end;
            full when Overflow =< MaxOverflow ->
                case queue:out(Waiting) of
                    {{value, {FromPid, _}=From}, LeftWaiting} ->
                        MonitorRef = erlang:monitor(process, FromPid),
                        Monitors2 = [{FromPid, MonitorRef} | Monitors],
                        NewWorker = new_worker(Sup),
                        gen_fsm:reply(From, NewWorker),
                        {next_state, full, State#state{waiting=LeftWaiting,
                                                       monitors=Monitors2}};
                    {empty, Empty} ->
                        {next_state, overflow, State#state{monitors=Monitors,
                                                           overflow=Overflow-1,
                                                           waiting=Empty}}
                end;
            full ->
                {next_state, full, State#state{monitors=Monitors,
                                               overflow=Overflow-1}}
        end,
    send_metrics(NewState),
    {next_state, NewName, NewState};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) -> ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

new_worker(Sup) ->
    {ok, Pid} = supervisor:start_child(Sup, []),
    link(Pid),
    Pid.

new_worker(Sup, FromPid) ->
    Pid = new_worker(Sup),
    Ref = erlang:monitor(process, FromPid),
    {Pid, Ref}.

dismiss_worker(Pid) ->
    unlink(Pid),
    Pid ! stop.

prepopulate(0, _Sup) ->
    queue:new();
prepopulate(N, Sup) ->
    prepopulate(N, Sup, queue:new()).

prepopulate(0, _Sup, Workers) ->
    Workers;
prepopulate(N, Sup, Workers) ->
    prepopulate(N-1, Sup, queue:in(new_worker(Sup), Workers)).

-spec send_metrics(#state{}) -> ok.
%% Send metrics, if configured in app config, based on data in state
%% record.  Currently, the available worker count, queued (waiting)
%% clients count, and number of monitors are recorded as histograms.
send_metrics(#state{workers = Workers, monitors = Monitors, waiting = Waiters}) ->
    send_metric(<<"poolboy.avail_workers">>, queue:len(Workers), histogram),
    send_metric(<<"poolboy.waiting_clients">>, queue:len(Waiters), histogram),
    send_metric(<<"poolboy.monitors">>, length(Monitors), histogram),
    ok.

-spec send_metric(binary(), term(), atom()) -> ok.
%% Send a metric using the metrics module from application config or
%% do nothing.
send_metric(Name, Value, Type) ->
    case application:get_env(poolboy, metrics_module) of
        undefined -> ok;
        {ok, Mod} -> Mod:notify(Name, Value, Type)
    end,
    ok.
