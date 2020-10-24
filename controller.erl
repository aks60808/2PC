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
  nodeSpawn(Graph,Node_Table,Graph).


% Spawn all node processes
nodeSpawn([],Node_Table,Graph) ->
  Obj = ets:match_object(Node_Table,{'$0','$1'}),
  io:format("~p~n",[Obj]),
% in the end of the function, do the network config after spawning all node processes
  initial_network_config(Graph,Node_Table);  
nodeSpawn([First|Rest],Node_Table,Graph) ->
  % get node name and its edges
  {NodeName,_Edges} = First,
  io:format("Node is ~w~n",[NodeName]),
  % spawn the node by its name
  NodePid = router:start(NodeName),
  % insert the Node name and its corresponding Pid to Node_Table
  ets:insert(Node_Table,{NodeName,NodePid}),
  nodeSpawn(Rest,Node_Table,Graph).

  
  
initial_network_config([],_Node_Table) -> ok;
initial_network_config([First|Rest],Node_Table)->
  io:format("~p~n",[First]),
  {RouterNodeName,Edges} = First, 
  io:format("edges is ~p~n",[Edges]),
  [{_RouterNodeName,RouterNodePid}] = ets:lookup(Node_Table,RouterNodeName),
  send_initial_control_message(RouterNodePid,Edges,Node_Table,[]),
  io:format("go to another node~n"),
  initial_network_config(Rest,Node_Table).

send_initial_control_message(RouterNodePid,[],_Node_Table,ListOfNames) -> 
  io:format("List of Names is ~p~n",[ListOfNames]),
  io:format("end of foo~n"),
  RouterNodePid ! {hello,self(),ListOfNames},
  ok; % next node
send_initial_control_message(RouterNodePid,[FirstEdge|RestEdges],Node_Table,ListOfNames) -> 
  {DestName,Names} = FirstEdge,
  [{_NodeName,DestPid}] = ets:lookup(Node_Table,DestName),
  io:format("~w~n",[DestPid]),
  Names_with_Pid = get_list_of_names(Names,DestPid,[]),
  New_ListOfNames = lists:append(Names_with_Pid,ListOfNames),
  send_initial_control_message(RouterNodePid,RestEdges,Node_Table,New_ListOfNames).
  

get_list_of_names([],_DestPid,ListOfNames) -> ListOfNames;  
get_list_of_names([FirstName|RestNames],DestPid,ListOfNames) ->
  New_ListOfNames = lists:append([{FirstName,DestPid}],ListOfNames),  
  get_list_of_names(RestNames,DestPid,New_ListOfNames).
