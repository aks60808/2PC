-module(controller).
-import(router,[start/1]).
-author("tommy").

%% API
-export([test/0,genGraph/0,graphToNetwork/1]).
test()->
  G = genGraph(),
  graphToNetwork(G).
genGraph() ->
  [{red  , [{white, [white, green]},
    {blue , [blue]}]},
    {white, [{red, [blue]},
      {blue, [green, red]}]},
    {blue , [{green, [white, green, red]}]},
    {green, [{red, [red, blue, white]}]}
  ].
graphToNetwork(Graph) ->
  io:format("graph is ~w~n",[Graph]),
  nodeSpawn(Graph).

edgeIterate([])->ok;
edgeIterate([First|Rest])->
  {Edge,Names} = First,
  io:format("Edge is ~w~n",[Edge]).

nodeSpawn([]) -> ok;
nodeSpawn([First|Rest]) ->
  {NodeName,Edges} = First,
  io:format("Node is ~w~n",[NodeName]),
  NodePid = router:start(NodeName),
  edgeIterate(Edges),
  ControlFun = hello_world,
  NodePid ! {control, self(), self(), 0,ControlFun},
  nodeSpawn(Rest).
listener() ->
  %% receive the trace receipt from DestNode
    receive
      {trace, Dest, Tracelist} -> ok
    end.