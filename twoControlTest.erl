-module(twoControlTest).

-export([runTest/0]).

% based on controlTest
circularNetwork3() ->
    [{red, [{white, [white, blue]}]},
     {white, [{blue, [red, blue]}]},
     {blue, [{red, [red, white]}]}].

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
    io:format("*** Reversing routing cycle...~n"),
    % control msg 1
    RedPid !
      {control, self(), self(), 1,
       fun (Name, Table) ->
	       case Name of
		 red ->
		     ets:insert(Table, [{white, BluePid}, {blue, BluePid}]);
		 white ->
		     ets:insert(Table, [{red, RedPid}, {blue, RedPid}]);
		 blue ->
		     ets:insert(Table, [{red, WhitePid}, {white, WhitePid}])
	       end,
	       []
       end},
    % control msg 2
    RedPid !
      {control, self(), self(), 2,
       fun (Name, Table) ->
	       case Name of
		 red ->
		     ets:insert(Table,
				[{white, WhitePid}, {blue, WhitePid}]);
		 white ->
		     ets:insert(Table, [{red, BluePid}, {blue, BluePid}]);
		 blue ->
		     ets:insert(Table, [{red, RedPid}, {white, RedPid}])
	       end,
	       []
       end},
    % recv the first control outcome ( *** This down below depends on your implemetation)
    receive
      {committed, RedPid, SQ} -> io:format("*** First control sqnum ~w...done.~n",[SQ]);
      {abort, RedPid, SQ} ->
	  io:format("*** First control sqnum ~w abort !~n",[SQ])
      after 10000 ->
		io:format("*** ERROR: Re-configuration timed out!~n")
    end,
    % recv the second control outcome
    receive
      {committed, RedPid, SqNum} -> io:format("*** Second sqNum ~w committed ...done.~n",[SqNum]);
      {abort, RedPid, SqNum} ->
	  io:format("*** SqNum ~w abort !~n",[SqNum])
      after 10000 ->
		io:format("*** ERROR: Re-configuration timed out!~n")
    end,
ok.