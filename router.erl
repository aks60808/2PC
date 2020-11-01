-module(router).

-export([start/1]).

start(RouterName) ->
    % initialise the Routing Table
    Table = ets:new(routing_table, [public]),
    % make new node perform the processs().
    SpawnPid = spawn(fun () ->
                             process(not_yet,RouterName, Table, 0, false, [], {})
                     end),
    io:format("~w : ~w ~n", [RouterName, SpawnPid]),
    SpawnPid.

% node process
process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult) ->
    % io:format("~w ~w In2PC: ~w~n",[RouterName,self(),IsIn2PC]),
    % if it's not in 2PC, proceess the queued msgs
    if IsIn2PC =/= true andalso length(MsgQueue) =/= 0 ->
           % send myself the messages
           lists:foreach(fun (Msg) ->
                                 self() ! Msg
                         end,
                         MsgQueue),
           process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, [], TentativeResult);
       true ->
           ok
    end,
    % listening
    receive
      {message, Dest, From, Pid, Trace} when Dest == RouterName ->
        % io:format("Dest ~w ~w recv message from ~w~n",[RouterName,self(),From]),
          % I am the Dest node , cache the message
          Message = {message, Dest, From, Pid, Trace},
          if IsIn2PC == true -> % if I am in 2PC, queue this msg
                 New_MsgQueue = MsgQueue ++ [Message];
             true -> % if I am not in 2PC , process this message
                 New_Trace = [RouterName] ++ Trace,
                 % in reverse order
                 Reversed_Full_Trace = lists:reverse(New_Trace),
                 % send to the controller
                 Pid ! {trace, self(), Reversed_Full_Trace},
                 % MsgQueue stays the same
                 New_MsgQueue = MsgQueue
          end,
          % keep the previous status of IsIn2PC
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, New_MsgQueue, TentativeResult);
      {message, Dest, From, Pid, Trace} ->
        %   io:format("~w ~w recv message to dest ~w from ~w~n",[RouterName,self(),Dest,From]),
          % I am doing the forwarding job
          Message = {message, Dest, From, Pid, Trace},
          if IsIn2PC == true -> % in2PC
                 % Queue this msg
                %  io:format("~w ~w is in 2PC~n",[RouterName,self()]),
                 New_MsgQueue = MsgQueue ++ [Message];
             true ->     % not in 2PC
                 % update trace
                 New_Trace = [RouterName] ++ Trace,
                 % find which node should I forward to
                 [{_DestNodeName, RouterPid}] = ets:lookup(Table, Dest),
                 % send it via routerPID with updated Trace
                 RouterPid ! {message, Dest, self(), Pid, New_Trace},
                %  io:format("~w ~w forward message to dest ~w via ~w~n",[RouterName,self(),Dest,RouterPid]),
                 % same Queue
                 New_MsgQueue = MsgQueue
          end,
          % keep the previous status of IsIn2PC
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, New_MsgQueue, TentativeResult);
      {can_you_commit, DestNodeName, FromPid, RootNodeName, Trace}
          when DestNodeName == RouterName ->
          io:format("~w got canyoucommit from ~w~n", [RouterName, FromPid]),
        %   io:format("Trace is ~p ~n", [Trace]),
          % I am the DestNode
          {Children, _TempTable} = TentativeResult,
          [LastPid | Rest] = Trace,
          RoutingPath = [self()] ++ Trace ,
          if Children == abort ->
                 LastPid ! {i_cannot_commit, RootNodeName, self(), RouterName, Rest};
             true ->
                 LastPid ! {i_can_commit, RootNodeName, self(), RouterName, Rest,RoutingPath}
          end,
          
          % keep the status ( now should be in 2PC)
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue,TentativeResult);
      {can_you_commit, DestNodeName, _FromPid, RootNodeName, Trace} ->
          % this is not for me -> find which node should take care of it
          [{_DestNodeName, RouterPid}] = ets:lookup(Table, DestNodeName),
          % forward
          New_Trace = [self()] ++ Trace,
          RouterPid ! {can_you_commit, DestNodeName, self(), RootNodeName, New_Trace},
          io:format("~w ~w foward can you commit to ~w via ~w~n",
                    [RouterName, self(), DestNodeName, RouterPid]),
          % only forward this cancommit request so Im not in 2PC
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {i_can_commit, RootNodeName, _FromPid, FromNodeName, Trace,RoutingPath} ->
          io:format("~w got i can commit of ~w ~n", [RouterName, FromNodeName]),
          % forward canCommit to rootnode
          [NextPid | Rest] = Trace,
          NextPid ! {i_can_commit, RootNodeName, self(), FromNodeName, Rest,RoutingPath},
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {i_cannot_commit, RootNodeName, _FromPid, FromNodeName, Trace} ->
          [NextPid | Rest] = Trace,
          NextPid ! {i_cannot_commit, RootNodeName, self(), FromNodeName, Rest},
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      % DestNode receive the message
      {control, _From, _Pid, SeqNum, ControlFun} when SeqNum == 0 ->
          % this is for the initial control message
          ControlFun(RouterName, Table),
          % children will be [] ,nothing spawned
          % not in 2PC !!
          Obj = ets:match_object(Table, {'$0', '$1'}),
        %   io:format("routing table of ~w ~w : ~p~n", [RouterName, self(), Obj]),
          process(RootNode,RouterName, Table, SeqNum, false, MsgQueue, TentativeResult);
      {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
          if 
            Cur_SeqNum > SeqNum orelse Cur_SeqNum == SeqNum->
                Pid ! {abort, self(), SeqNum},
                process(RootNode,RouterName, Table, SeqNum, false, MsgQueue, TentativeResult);
            true-> ok
          end,
          % I am a root router
          % ask all nodes can commit or not
          ListofEntries = ets:match_object(Table, {'$0', '$1'}),
          ControlMessage = {control, self(), Pid, SeqNum, ControlFun},
          TempTable = ets:new(temp_routing_table, [public]),
          AllObj = ets:match_object(Table, {'$0', '$1'}),
          ets:insert(TempTable, AllObj),
          Children = ControlFun(RouterName, TempTable),
          propagate_control_message(ListofEntries, [], ControlMessage),
          RoutingPath_Table = ets:new(routing_path_table,[]),
          Result = ask_nodes_for_commit(ListofEntries, RouterName,RoutingPath_Table),
        %   io:format("result is ~w~n", [Result]),
          if Result == timeout orelse Result == abort orelse Children == abort ->
                 send_2nd_phase_msg(ListofEntries, SeqNum, RouterName, doAbort,RoutingPath_Table),
                 if is_list(Children) == true ->
                        lists:foreach(fun (NodePid) ->
                                              exit(NodePid, abort)
                                      end,
                                      Children);
                    true -> % this is typically abort
                        ok
                 end,
                 ets:delete(TempTable),
                 Pid ! {abort, self(), SeqNum},
                 Obj_after_abort = ets:match_object(Table, {'$0', '$1'}),
                %  io:format("~w after abort is ~p~n", [RouterName,Obj_after_abort]),
                 % terminate the 2PC
                 process(RouterName,RouterName, Table, Cur_SeqNum, false, MsgQueue, {});
             true ->
                 send_2nd_phase_msg(ListofEntries, SeqNum, RouterName, doCommit,RoutingPath_Table),
                 AllObj_from_tempTable = ets:match_object(TempTable, {'$0', '$1'}),
                 ets:insert(Table, AllObj_from_tempTable),
                 ets:delete(TempTable),
                 % eventually send to controller
                 Pid ! {committed, self(), SeqNum},
                 % finished 2PC
                 AllObj_from_table_now = ets:match_object(Table, {'$0', '$1'}),
                %  io:format("~p~n", [AllObj_from_table_now]),
                 process(RouterName,RouterName, Table, SeqNum, false, MsgQueue, {})
          end;
      {control, From, Pid, SeqNum, ControlFun} ->
          io:format("~w got propagate cntrl msg~n",[RouterName]),
          if Cur_SeqNum < SeqNum andalso RootNode=/=RouterName->
                 ControlMessage = {control, From, Pid, SeqNum, ControlFun},
                 ListofEntries = ets:match_object(Table, {'$0', '$1'}),
                 propagate_control_message(ListofEntries, [], ControlMessage),
                 TempTable = ets:new(temp_routing_table, [public]),
                 AllObj = ets:match_object(Table, {'$0', '$1'}),
                 ets:insert(TempTable, AllObj),
                 Children = ControlFun(RouterName, TempTable),
                 Updated_TentativeResult = {Children, TempTable},
                 process(RootNode,RouterName, Table, SeqNum, true, MsgQueue, Updated_TentativeResult);
             % old control message
             true ->
                 process(RootNode,RouterName, Table, Cur_SeqNum, false, MsgQueue, TentativeResult)
          end;
      {doAbort, _SeqNum, DestNodeName, _FromPid, RootNodeName, Trace}
          when DestNodeName == RouterName ->
          {Children, TempTable} = TentativeResult,
          if is_list(Children) == true ->
                 lists:foreach(fun (NodePid) ->
                                       exit(NodePid, abort),
                                       io:format("NewSpawnedNode ~w alive? ~w~n",[NodePid,is_process_alive(NodePid)])
                               end,
                               Children);
             true -> % this is typically abort
                 ok
          end,
          ets:delete(TempTable),
          [LastPid | Rest] = Trace,
          LastPid ! {doAbort, ack, RootNodeName, Rest},
          Obj_after_abort = ets:match_object(Table, {'$0', '$1'}),
        %   io:format("~w after abort is ~p~n", [RouterName,Obj_after_abort]),
          % revert to the previous status, close the 2PC
          process(RootNode,RouterName, Table, Cur_SeqNum, false, MsgQueue, {});
      {doAbort, SeqNum, DestNodeName, _FromPid, RootNodeName, Trace} ->
          % forwarding
          New_Trace = [self()] ++ Trace,
          [{_DestNodeName, RouterPid}] = ets:lookup(Table, DestNodeName),
          RouterPid ! {doAbort, SeqNum, DestNodeName, self(), RootNodeName, New_Trace},
          io:format("~w ~w foward doAbort to ~w via ~w~n",
                    [RouterName, self(), DestNodeName, RouterPid]),
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {doCommit, SeqNum, DestNodeName, FromPid, RootNodeName,_Deliver_List,Path_from_Root_to_Node}
          when DestNodeName == RouterName ->
          io:format("~w ~w recv DoCommit from ~w~n", [RouterName, self(), FromPid]),
          {_Children, TempTable} = TentativeResult,
          Path_from_Node_to_Root = lists:reverse(Path_from_Root_to_Node),
          [_MyPid | Rest] = Path_from_Node_to_Root,
          [NextPid|OtherPids] = Rest,
          NextPid ! {doCommit, ack, RootNodeName, OtherPids},
          AllObj_from_tempTable = ets:match_object(TempTable, {'$0', '$1'}),
          ets:insert(Table, AllObj_from_tempTable),
          ets:delete(TempTable),
          % update the latest SeqNum, make TempTable permanent and close the 2PC
          process(RootNode,RouterName, Table, SeqNum, false, MsgQueue, {});
      {doCommit, SeqNum, DestNodeName, _FromPid, RootNodeName, Deliver_List,RoutingPath} ->
          % forwarding
          [NextPid|RestPids] = Deliver_List,
          NextPid ! {doCommit, SeqNum, DestNodeName, self(), RootNodeName, RestPids,RoutingPath},
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {doCommit, ack, RootNodeName, Deliver_List} ->
          [LastPid | Rest] = Deliver_List,
          LastPid ! {doCommit, ack, RootNodeName, Rest},
          io:format("~w ~w recv the doCommit ACK to ~w via ~w~n",
                    [RouterName, self(), RootNodeName, LastPid]),
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {doAbort, ack, RootNodeName, Trace} ->
          [LastPid | Rest] = Trace,
          LastPid ! {doAbort, ack, RootNodeName, Rest},
          process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {dump, From} ->
          Dump = ets:match(Table, '$1'),
          From ! {table, self(), Dump},
          process(RootNode,RouterName, Table, Cur_SeqNum, false, MsgQueue, TentativeResult);
      stop ->
        io:format("~w ~w recv stop!~n",[RouterName,self()]),
        Message = stop,
        if IsIn2PC == true -> % if I am in 2PC, queue this msg
               New_MsgQueue = MsgQueue ++ [Message],
               process(RootNode,RouterName, Table, Cur_SeqNum, IsIn2PC, New_MsgQueue, TentativeResult);
           true -> % if I am not in 2PC , operate this stop command
            % de-allocate the table    
            ets:delete(Table),
            io:format("~w ~w leave ~n",[RouterName,self()]),
            exit(stop)
        end
    end.

send_2nd_phase_msg([], _SeqNum, _RouterName, _Command,_RoutingPath_Table) ->
    ok;
send_2nd_phase_msg([FirstEntry | RestEntries], SeqNum, RouterName, Command,RoutingPath_Table) ->
    {DestNodeName, RouteViaPid} = FirstEntry,
    if DestNodeName =/= '$NoInEdges' ->
           io:format("send 2nd phase to ~w~n", [DestNodeName]),
           if Command == doCommit->
            [{_DestNodeName,Path_from_Root_to_Node}] = ets:lookup(RoutingPath_Table,DestNodeName),
            [_RootNodePid|Rest] = Path_from_Root_to_Node,
            [NextPid|OtherPids] = Rest,
            NextPid ! {Command, SeqNum, DestNodeName, self(), RouterName, OtherPids,Path_from_Root_to_Node};
           true ->
            RouteViaPid ! {Command, SeqNum, DestNodeName, self(), RouterName, [self()]}
           end,
           receive
             {Command, ack, _Me, _Trace} ->
                 io:format("Root recv ack from ~n"),
                ok
           end,
           [NextEntry | OtherEntries] = RestEntries,
           {NextDestNodeName, _NextRouteViaPid} = NextEntry,
           if NextDestNodeName == '$NoInEdges' ->
                  send_2nd_phase_msg(OtherEntries, SeqNum, RouterName, Command,RoutingPath_Table);
              true ->
                  send_2nd_phase_msg(RestEntries, SeqNum, RouterName, Command,RoutingPath_Table)
           end;
       true ->
           send_2nd_phase_msg(RestEntries, SeqNum, RouterName, Command,RoutingPath_Table)
    end.

ask_nodes_for_commit([], _RouterName,_RoutePATH_TABLE) ->
    true;
ask_nodes_for_commit([FirstEntry | RestEntries], RouterName,RoutePATH_TABLE) ->
    {DestNodeName, RouteViaPid} = FirstEntry,
    if DestNodeName =/= '$NoInEdges' ->
        %    io:format("send cancommit to ~w~n", [DestNodeName]),
           RouteViaPid ! {can_you_commit, DestNodeName, self(), RouterName, [self()]},
           receive
             {i_can_commit, _Me, _RouteFromPid, FromNodeName, _Deliver_List,Path_from_Node_to_Root}
                 when FromNodeName == DestNodeName ->
                 %  io:format("~w recv the canCommit from ~w~n", [RouterName, FromNodeName]),
                 Path_from_Root_to_Node = lists:reverse(Path_from_Node_to_Root),
                 ets:insert(RoutePATH_TABLE,{FromNodeName,Path_from_Root_to_Node}),
                 [NextEntry | OtherEntries] = RestEntries,
                 {NextDestNodeName, _NextRouteViaPid} = NextEntry,
                 if NextDestNodeName == '$NoInEdges' ->
                        ask_nodes_for_commit(OtherEntries, RouterName,RoutePATH_TABLE);
                    true ->
                        ask_nodes_for_commit(RestEntries, RouterName,RoutePATH_TABLE)
                 end;
             {i_cannot_commit, _Me, _FromPid, _FromNodeName, _Trace} ->
                 abort
             after 5000 ->
                       timeout
           end;
       true ->
           ask_nodes_for_commit(RestEntries, RouterName,RoutePATH_TABLE)
    end.

propagate_control_message([], Final_List, ForwardMessage) ->
    % io:format("forward node have ~p~n",[Final_List]),
    lists:foreach(fun (RoutePid) ->
                          RoutePid ! ForwardMessage
                  end,
                  Final_List);
propagate_control_message([FirstEntry | RestEntries], List, ForwardMessage) ->
    {DestNodeName, RouteViaPid} = FirstEntry,
    if DestNodeName =/= '$NoInEdges' ->
           Result = lists:member(RouteViaPid, List),
           if Result == false ->
                  New_List = [RouteViaPid] ++ List;
              true ->
                  New_List = List
           end;
       true ->
           New_List = List
    end,
    propagate_control_message(RestEntries, New_List, ForwardMessage).

