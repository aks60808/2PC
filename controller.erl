-module(controller).
-import(router,[start/1]).
-import(lists,[append/2,last/1]).
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
  RootPid = graphToNetwork(G),
  io:format("root pid is ~w~n",[RootPid]).
% function graphToNetwork(Graph) start
graphToNetwork(Graph) ->
  io:format("graph is ~w~n",[Graph]),
  Node_Table = ets:new(node_table,[]),
  IncomingEdges_Count_Table = ets:new(edges_table,[]),
  RootPid = nodeSpawn(Graph,Node_Table,IncomingEdges_Count_Table,[]),
  initial_network_config(Graph,Node_Table,IncomingEdges_Count_Table),
  % Obj = ets:match_object(IncomingEdges_Count_Table,{'$0','$1'}),
  % io:format("edges table: ~p~n",[Obj]),
  RootPid.

% Spawn all node processes
nodeSpawn([],Node_Table,_IncomingEdges_Count_Table,Node_List) ->
  % get the first node in the Graph
  First_Node_Name = lists:last(Node_List),
  % get the RootPid
  [{_RootName,RootPid}] = ets:lookup(Node_Table,First_Node_Name),
  % return RootPid
  RootPid;  
nodeSpawn([First|Rest],Node_Table,IncomingEdges_Count_Table,Node_List) ->
  % get node name and its edges
  {NodeName,Edges} = First,
  % update the node list
  New_Node_List = lists:append([NodeName],Node_List),
  % spawn the node by its name
  NodePid = router:start(NodeName),
  % insert the Node name and its corresponding Pid to Node_Table
  ets:insert(Node_Table,{NodeName,NodePid}),
  count_edges(Edges,IncomingEdges_Count_Table),
  % continue with Rest iteration
  nodeSpawn(Rest,Node_Table,IncomingEdges_Count_Table,New_Node_List).

count_edges([],_IncomingEdges_Count_Table) -> ok;
count_edges([First|Rest],IncomingEdges_Count_Table)->
  {EdgeToNodeName,_Names} = First,
  Result = ets:lookup(IncomingEdges_Count_Table,EdgeToNodeName),
  io:format("Result is : ~p~n",[Result]),
 
  update_edge_table(Result,EdgeToNodeName,IncomingEdges_Count_Table),
  Obj = ets:match_object(IncomingEdges_Count_Table,{'$0','$1'}),
  io:format("edges table: ~p~n",[Obj]),
  count_edges(Rest,IncomingEdges_Count_Table).

update_edge_table(Result,EdgeToNodeName,IncomingEdges_Count_Table) when Result == [] ->
  ets:insert(IncomingEdges_Count_Table,{EdgeToNodeName,1});
update_edge_table(Result,EdgeToNodeName,IncomingEdges_Count_Table) ->
  ets:update_counter(IncomingEdges_Count_Table, EdgeToNodeName, 1).


initial_network_config([],_Node_Table,_IncomingEdges_Count_Table) -> ok;
initial_network_config([First|Rest],Node_Table,IncomingEdges_Count_Table)->
  {RouterNodeName,Edges} = First, 
  [{_RouterNodeName,RouterNodePid}] = ets:lookup(Node_Table,RouterNodeName),
  send_initial_control_message(Edges,RouterNodePid,Node_Table,[]),
  initial_network_config(Rest,Node_Table,IncomingEdges_Count_Table).

send_initial_control_message([],RouterNodePid,_Node_Table,ListOfNames) -> 
  % io:format("List of Names is ~p~n",[ListOfNames]),
  % io:format("end of foo~n"),
  RouterNodePid ! {control,self(),self(),0,fun (_Name,Table) ->
    ets:insert(Table,ListOfNames)  
  ,[]
  end  
  }; % next node
send_initial_control_message([FirstEdge|RestEdges],RouterNodePid,Node_Table,ListOfNames) -> 
  {DestName,Names} = FirstEdge,
  [{_NodeName,DestPid}] = ets:lookup(Node_Table,DestName),
  Names_with_Pid = get_list_of_names(Names,DestPid,[]),
  New_ListOfNames = lists:append(Names_with_Pid,ListOfNames),
  send_initial_control_message(RestEdges,RouterNodePid,Node_Table,New_ListOfNames).
  

get_list_of_names([],_DestPid,ListOfNames) -> ListOfNames;  
get_list_of_names([FirstName|RestNames],DestPid,ListOfNames) ->
  New_ListOfNames = lists:append([{FirstName,DestPid}],ListOfNames),  
  get_list_of_names(RestNames,DestPid,New_ListOfNames).

% function graphToNetwork(Graph) end

% function extendNetwork (RootPid, SeqNum, From, {NodeName, Edges}) start
% extendNetwork (RootPid, SeqNum, From, {NodeName, Edges}) -> 
%   RootPid ! {control, From, self(), SeqNum, _ControlFun},
%   ok.
