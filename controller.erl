-module(controller).
-import(router,[start/1]).
-import(lists,[append/2]).
-import(ets,[new/2,delete/1,insert/2]).
-author("tommy").

%% API
-export([test/0,genGraph/0,graphToNetwork/1]).

genGraph() ->
  [{red  , [{white, [white, green]},
    {blue , [blue]}]},
    {white, [{red, [blue]},
      {blue, [green, red]}]},
    {blue , [{green, [white, green, red]}]},
    {green, [{red, [red, blue, white]}]}
  ].
  
  
test()->
  G = genGraph(),
  graphToNetwork(G).

graphToNetwork(Graph) ->
  io:format("graph is ~w~n",[Graph]),
  Node_Table = ets:new(node_table,[]),
  nodeSpawn(Graph,Node_Table).



nodeSpawn([],Node_Table) -> 
  % ets:i(Node_Table),
  % ets:delete(Node_Table),
  ok;
nodeSpawn([First|Rest],Node_Table) ->
  {NodeName,Edges} = First,
  io:format("Node is ~w~n",[NodeName]),
  NodePid = router:start(NodeName),
  ets:insert(Node_Table,{NodeName,NodePid}),
  edgeIterate(Edges).
  % NodePid ! {control, self(), self(), 0,ControlFun},
  % nodeSpawn(Rest,Node_Table).
  
edgeIterate([])->ok;
edgeIterate([First|Rest])->
  {Edge,Names} = First, 
  io:format("Edge is ~w~n",[First]),
  ListOfLables = register_label_list(Names,Edge,[]),
  io:format(ListOfLables).
  % edgeIterate(Rest).

register_label_list([],_,ListOfLabels) -> ListOfLabels;  
register_label_list([FirstLabel|RestLabels],Edge,ListOfLabels) ->
  io:format(FirstLabel),
  io:format("~w~n",[ListOfLabels]),
  New_ListOfLabels = lists:append([FirstLabel],ListOfLabels),
  io:format("~w~n",[New_ListOfLabels]).
  % register_label_list(RestLabels,Edge,New_ListOfLabels).