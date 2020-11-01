-module(abortTest).
-export([runTest/0]).

%% modify from controlTest
%% Test abort operation without spawning any new_node
%% Circular network consisting of three nodes.
%%
circularNetwork3 () ->
  [{red  , [{white, [white, blue]}]},
   {white, [{blue , [red, blue]}]},
   {blue , [{red  , [red, white]}]}
  ].


%% Build a circular network and then use a control request to change the 
%% direction of all edges; verify the original 
%%
runTest () ->
  io:format ("*** Starting router network...~n"),
  CGraph = circularNetwork3 (),
  RedPid = control:graphToNetwork (CGraph),
  networkTest:verifyNetwork (RedPid, CGraph),

  {WhitePid, _} = networkTest:probeNetwork (RedPid, white),
  {BluePid , _} = networkTest:probeNetwork (RedPid, blue ),
  if (WhitePid == undef) or (BluePid == undef) -> 
      io:format ("*** ERROR: Corrupt network!~n");
     true -> true
  end,

  io:format ("*** Reversing routing cycle...~n"),
  RedPid ! {control, self (), self (), 1, 
	    fun (Name, Table) -> 
		case Name of
		  red   -> ets:insert (Table, [{white, BluePid }, 
                           {blue , BluePid }]),
                    Rtn = [];
		  white -> ets:insert (Table, [{red  , RedPid  }, 
                           {blue , RedPid  }]),
                           Rtn = []       ;
		  blue  -> ets:insert (Table, [{red  , WhitePid}, 
                           {white, WhitePid}]),
                           Rtn = abort   % make it return abort
		end,
		Rtn
	    end},
  receive
    {committed, RedPid, 1} -> io:format ("*** ERROR: Re-configuration committed (should be abort)!!!~n");
    {abort    , RedPid, 1} -> 
      io:format ("*** Re-configuration failed as expected!~n")
  after 10000              ->
      io:format ("*** ERROR: Re-configuration timed out!~n")
  end,
  %% check the network is still the same
  networkTest:verifyNetwork (RedPid, circularNetwork3 ()).