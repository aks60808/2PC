-module(control).
-import(router,[start/1]).
-import(lists,[append/2,last/1]).
-import(ets,[new/2,delete/1,insert/2]).
-author("tommy").

%% API
-export([extendNetwork/4,graphToNetwork/1]).



% function graphToNetwork(Graph) start
graphToNetwork(Graph) ->
  % io:format("graph is ~w~n",[Graph]),
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
  lists:foreach( fun (Edge) ->
    {EdgeToNodeName,_Names} = Edge,
    Result = ets:lookup(IncomingEdges_Count_Table,EdgeToNodeName),
    if
      Result ==[]->
        ets:insert(IncomingEdges_Count_Table,{EdgeToNodeName,1});
      true ->
        ets:update_counter(IncomingEdges_Count_Table, EdgeToNodeName, 1)
    end
    % Obj = ets:match_object(IncomingEdges_Count_Table,{'$0','$1'}),
    % io:format("edges table: ~p~n",[Obj]) 
    end,Edges),
  % count_edges(Edges,IncomingEdges_Count_Table),
  % continue with Rest iteration
  nodeSpawn(Rest,Node_Table,IncomingEdges_Count_Table,New_Node_List).

initial_network_config([],_Node_Table,_IncomingEdges_Count_Table) -> true;
initial_network_config([First|Rest],Node_Table,IncomingEdges_Count_Table)->
  {RouterNodeName,Edges} = First, 
  [{_RouterNodeName,RouterNodePid}] = ets:lookup(Node_Table,RouterNodeName),
  [{_RouterNodeName,NoInEdge}] = ets:lookup(IncomingEdges_Count_Table,RouterNodeName),
  send_initial_control_message(Edges,RouterNodePid,Node_Table,[],NoInEdge),
  initial_network_config(Rest,Node_Table,IncomingEdges_Count_Table).

send_initial_control_message([],RouterNodePid,_Node_Table,ListOfNames,NoInEdge) -> 
  % send controll message to node
  RouterNodePid ! {control,self(),self(),0,fun (_Name,Table) ->
    ets:insert(Table,{'$NoInEdges',NoInEdge}),
    ets:insert(Table,ListOfNames),  
  []
  end  
  }; 
send_initial_control_message([FirstEdge|RestEdges],RouterNodePid,Node_Table,ListOfNames,NoInEdge) -> 
  {DestName,Names} = FirstEdge,
  [{_NodeName,DestPid}] = ets:lookup(Node_Table,DestName),
  Names_with_Pid = get_list_of_names(Names,DestPid,[]),
  New_ListOfNames = lists:append(Names_with_Pid,ListOfNames),
  send_initial_control_message(RestEdges,RouterNodePid,Node_Table,New_ListOfNames,NoInEdge).
  

get_list_of_names([],_DestPid,ListOfNames) -> ListOfNames;  
get_list_of_names([FirstName|RestNames],DestPid,ListOfNames) ->
  New_ListOfNames = lists:append([{FirstName,DestPid}],ListOfNames),  
  get_list_of_names(RestNames,DestPid,New_ListOfNames).

% function graphToNetwork(Graph) end

% function extendNetwork (RootPid, SeqNum, From, {NodeName, Edges}) start
extendNetwork (RootPid, SeqNum, From, {NodeName, Edges}) -> 
  ControlPid = self(),
  % get the list of routing entries and list of nodes who need to update its NoInEdge
  {Routing_List,IncomingEdgeNode_List} = get_routing_entries_and_edges_list(Edges,[],[]),
  % send control message to the root router node
  RootPid ! {control, self(), ControlPid, SeqNum, fun (Name,Table) ->
    % if the receipient is the node who matched From
    if 
      From == Name -> 
        
        % Spawn the new node 
        NewSpawnPid = router:start(NodeName),
        % % Send to new node for configuring its routing table
        NewSpawnPid ! {control,self(),ControlPid,0, fun (_SpawnedNodeName,SpawnedNodeTable) ->
          ets:insert(SpawnedNodeTable,{'$NoInEdges',1}),
          ets:insert(SpawnedNodeTable,Routing_List),
          []
          end},
        ReturnValue = [NewSpawnPid],
        % update the From's routing table for this new entry
        ets:insert(Table, {NodeName,NewSpawnPid});
      % other node
      true -> 
        ReturnValue = [],
        % update the other's routing table for this new entry
        % find which pid forward to the From Node
        [{_FromNodeName,RouterPid}] = ets:lookup(Table,From),
        % copy RouterPid and update the new entry with that Pid
        ets:insert(Table,{NodeName,RouterPid})
    end,
    % check if receipient has the incoming edge from the new node
    NeedUpdateNoInEdge = lists:member(self(), IncomingEdgeNode_List),
    if
      NeedUpdateNoInEdge == true ->  
        ets:update_counter(Table,'$NoInEdges' , 1);
      true -> ok
    end,
    ReturnValue end},
  receive
      {committed, RootPid, SeqNum} -> true;
      {abort    , RootPid, SeqNum} -> false
   end.
 

get_routing_entries_and_edges_list([],ListOfNames,IncomingEdgeNode_List)-> {ListOfNames,IncomingEdgeNode_List};
get_routing_entries_and_edges_list([FirstEdge|RestEdges],ListOfNames,IncomingEdgeNode_List)-> 
  {EdgeToNodePid,Names} = FirstEdge,
  Names_with_Pid = get_list_of_names(Names,EdgeToNodePid,[]),
  New_ListOfNames = lists:append(Names_with_Pid,ListOfNames),
  New_IncomingEdgeNode_List = lists:append(IncomingEdgeNode_List,[EdgeToNodePid]),
  get_routing_entries_and_edges_list(RestEdges,New_ListOfNames,New_IncomingEdgeNode_List).
