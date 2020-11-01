-module(msgin2PC).

-export([runTest/0]).
%% I swith cGraph and rervese Graph for testing the ordering
reverseCircularNetwork3() ->
    [{red, [{white, [white, blue]}]},
     {white, [{blue, [red, blue]}]},
     {blue, [{red, [red, white]}]}].

circularNetwork3() ->
    [{red, [{blue, [white, blue]}]},
     {white, [{red, [red, blue]}]},
     {blue, [{white, [red, white]}]}].

%% Build a circular network and then use a control request to change the
%% direction of all edges; verify the original and reversed network
%%
runTest() ->
    io:format("*** Starting router network...~n"),
    CGraph = circularNetwork3(),
    RedPid = control:graphToNetwork(CGraph),
    networkTest:verifyNetwork(RedPid, CGraph),
    {WhitePid, _} = networkTest:probeNetwork(RedPid, white),
    {BluePid, _} = networkTest:probeNetwork(RedPid, blue),
    if (WhitePid == undef) or (BluePid == undef) ->
	   io:format("*** ERROR: Corrupt network!~n");
       true -> true
    end,
    RedPid ! {message, blue, self(), self(), []},
    receive
      {trace, _From, Trace_before_reconfig} ->
	  io:format("Received trace: ~w~n", [Trace_before_reconfig])
    end,
    io:format("*** Reversing routing cycle...~n"),
    RedPid !
      {control, self(), self(), 1,
       fun (Name, Table) ->
	       case Name of
		 red ->
		     ets:insert(Table, [{white, WhitePid}, {blue, WhitePid}]);
		 white ->
		     ets:insert(Table, [{red, BluePid}, {blue, BluePid}]);
		 blue ->
		     ets:insert(Table, [{red, RedPid}, {white, RedPid}])
	       end,
	       []
       end},
     RedPid ! {message, blue, self(), self(), []},
    receive
      {trace, _, _Trace} -> io:format ("*** ERROR: should not receive this during 2PC!!!~n");
      {committed, RedPid, 1} -> io:format("*** ...done.~n");
      {abort, RedPid, 1} ->
	  io:format("*** ERROR: Re-configuration failed!~n")
      after 10000 ->
		io:format("*** ERROR: Re-configuration timed out!~n")
    end,
    receive
      {trace, _, Trace_after_reconfig} ->
          if Trace_after_reconfig =/= [red,white,blue] ->
            io:format("*** ERROR: Trace differed!!~n");
          true->
            io:format("Received trace: ~w~n", [Trace_after_reconfig])
          end
    after 5000 -> timeout
    end,
    networkTest:verifyNetwork(RedPid, reverseCircularNetwork3()).

