-module(router).

-author("z5219960 Heng-Chuan Lin").

-export([start/1]).

start(RouterName) ->
    % initialise the Routing Table
    Table = ets:new(routing_table, [public]),
    % spawn new node to perform the processs().
    SpawnPid = spawn(fun () ->
                             process(not_yet, RouterName, Table, 0, false, [], {})
                     end),
    % return Spawned Pid
    % io:format("~w : ~w~n", [RouterName, SpawnPid]),
    SpawnPid.

% node process
process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult) ->
    if IsIn2PC =/= true andalso length(MsgQueue) =/= 0 ->
           % re-send myself the messages
           lists:foreach(fun (Msg) ->
                                 self() ! Msg
                         end,
                         MsgQueue),
           % clear the MsgQueue
           process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, [], TentativeResult);
       true ->
           ok
    end,
    receive
        {message, Dest, From, Pid, Trace} when Dest == RouterName ->
            % io:format("~w recv msg ~n",[RouterName]),
            if IsIn2PC == true -> % if I am in 2PC, queue this msg
                   Message = {message, Dest, From, Pid, Trace},
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
            process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, New_MsgQueue, TentativeResult);
        {message, Dest, From, Pid, Trace} ->
            Message = {message, Dest, From, Pid, Trace},
            if IsIn2PC == true -> % in2PC
                   % Queue this msg
                   New_MsgQueue = MsgQueue ++ [Message];
               true ->     % not in 2PC
                   % update trace
                   New_Trace = [RouterName] ++ Trace,
                   % find which node should I forward to
                   [{_DestNodeName, RouterPid}] = ets:lookup(Table, Dest),
                   % send it via routerPID with updated Trace
                   RouterPid ! {message, Dest, self(), Pid, New_Trace},
                   % same Queue
                   New_MsgQueue = MsgQueue
            end,
            % keep the previous status
            process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, New_MsgQueue, TentativeResult);
      {doAbort, SeqNum, FromPid, RootNodePid} ->
        %   io:format("~w recev doAbort~n",[RouterName]),
          % receive doAbort on the right SeqNum in 2PC
          if Cur_SeqNum == SeqNum andalso IsIn2PC == true ->
                 ListofEntries = ets:match_object(Table, {'$0', '$1'}),
                 % propage this doAbort msg through outgoing edge
                 propagate_control_message(ListofEntries,
                                           [],
                                           {doAbort, SeqNum, self(), RootNodePid},
                                           FromPid,
                                           RootNodePid),
                 {Children, TempTable, PreviousSeqNum} = TentativeResult,
                 if is_list(Children) == true ->
                        % terminate spawned node if this node has it
                        lists:foreach(fun (NodePid) ->
                                              exit(NodePid, abort)
                                            %   io:format("NewSpawnedNode ~w alive? ~w~n",
                                                        % [NodePid, is_process_alive(NodePid)])
                                      end,
                                      Children);
                    true -> % this is == abort
                        ok
                 end,
                 % deallocate the temp routing table
                 ets:delete(TempTable),
                 % restore to the previous status, close the 2PC,
                %  io:format("~w do Abort~n", [RouterName]),
                 process(RootNode, RouterName, Table, PreviousSeqNum, false, MsgQueue, {});
             true ->
                 process(RootNode,
                         RouterName,
                         Table,
                         Cur_SeqNum,
                         IsIn2PC,
                         MsgQueue,
                         TentativeResult)
          end;
      {doCommit, SeqNum, From, RootNodePid} ->
          % receive doCommit on the right SeqNum in 2PC
          if Cur_SeqNum == SeqNum andalso IsIn2PC == true ->
                 ListofEntries = ets:match_object(Table, {'$0', '$1'}),
                 %propagate the doCommit along the outgoing edge
                 propagate_control_message(ListofEntries,
                                           [],
                                           {doCommit, SeqNum, self(), RootNodePid},
                                           From,
                                           RootNodePid),
                 {_Children, TempTable, _PreviousSeqNum} = TentativeResult,
                 AllObj_from_tempTable = ets:match_object(TempTable, {'$0', '$1'}),
                 % replace the current routing table with temp one
                 ets:insert(Table, AllObj_from_tempTable),
                 % deallocate the temp table
                 ets:delete(TempTable),
                 % update the latest SeqNum, make TempTable permanent and close the 2PC
                 
                 process(RootNode, RouterName, Table, SeqNum, false, MsgQueue, {});
             true ->
                 
                 process(RootNode,
                         RouterName,
                         Table,
                         Cur_SeqNum,
                         IsIn2PC,
                         MsgQueue,
                         TentativeResult)
          end;

      {can_you_commit, DestNodeName, _DeliverPid, RootNodeName, Trace}
          when DestNodeName == RouterName ->

            if IsIn2PC == true ->
                % io:format("~w recv can you commit?~n", [RouterName]),
                % I am the DestNode
                % check the tentative result
                {Children, _TempTable, _PreviousSeqNum} = TentativeResult,
                % record the trace from root to me
                [LastPid | Rest] = Trace,
                if Children == abort ->
                        % send abort msg
                        LastPid ! {i_cannot_commit, RootNodeName, self(), RouterName, Rest};
                    true ->
                        % send can commit msg backward
                        LastPid ! {i_can_commit, RootNodeName, self(), RouterName, Rest}
                end;
                
            true -> ok
            end,
          % clean the propagate control msg
            % flush(),
          % keep the status ( now should be in 2PC)
          process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {can_you_commit, DestNodeName, _DeliverPid, RootNodeName, Trace} ->
          % this is not for me -> find which node should take care of it
          [{_DestNodeName, RouterPid}] = ets:lookup(Table, DestNodeName),
          % forward and add the trace for backward sending
          New_Trace = [self()] ++ Trace,
          RouterPid ! {can_you_commit, DestNodeName, self(), RootNodeName, New_Trace},
          process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {i_can_commit, RootNodeName, _DeliverPid, FromNodeName, Trace}
          when RootNodeName =/= RouterName ->
          % forward canCommit to rootnode
          % send to root in opposite direction
          [NextPid | Rest] = Trace,
          NextPid ! {i_can_commit, RootNodeName, self(), FromNodeName, Rest},
          process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {i_cannot_commit, RootNodeName, _DeliverPid, FromNodeName, Trace} ->
          % send to root in opposite direction
          [NextPid | Rest] = Trace,
          NextPid ! {i_cannot_commit, RootNodeName, self(), FromNodeName, Rest},
          process(RootNode, RouterName, Table, Cur_SeqNum, IsIn2PC, MsgQueue, TentativeResult);
      {control, _From, _Pid, SeqNum, ControlFun} when SeqNum == 0 ->
          % this is for the initial control message
          ControlFun(RouterName, Table),
          % children will be [] ,nothing spawned
          % not in 2PC !!
          process(RootNode, RouterName, Table, SeqNum, false, MsgQueue, TentativeResult);
      {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
          % I am a root router
          % hanlding simultaneously control request if root router is in 2PC already
          if IsIn2PC == true ->
                %  io:format(" INx2PC root ~w  detect control msg conflict ~n", [RouterName]),
                 Pid ! {abort, self(), SeqNum},
                %  io:format(" root ~w  send control msg conflict to control~n", [RouterName]),
                 process(RootNode,
                         RouterName,
                         Table,
                         Cur_SeqNum,
                         IsIn2PC,
                         MsgQueue,
                         TentativeResult);
             true ->
                 ok
          end,
          % hanlding simultaneously control request if current Seq is equal to or larger than this Control Seq
          if Cur_SeqNum > SeqNum orelse Cur_SeqNum == SeqNum ->
                %  io:format(" SQ root ~w  detect control msg conflict ~n", [RouterName]),
                 Pid ! {abort, self(), SeqNum},
                 process(RootNode, RouterName, Table, Cur_SeqNum, false, MsgQueue, TentativeResult);
             true ->
                 ok
          end,
          % 2PC phase 1
          % ask all nodes can commit or not
          ListofEntries = ets:match_object(Table, {'$0', '$1'}),
          ControlMessage = {control, self(), Pid, SeqNum, ControlFun},
          % Create a Temp Routing Table
          TempTable = ets:new(temp_routing_table, [public]),
          % Copy all Objs from Routing Table
          AllObj = ets:match_object(Table, {'$0', '$1'}),
          % insert these obj to Temp Table
          ets:insert(TempTable, AllObj),
          % perform the control funciton with TempTable
          Children = ControlFun(RouterName, TempTable),
          % propagate this control request to all nodes
          propagate_control_message(ListofEntries, [], ControlMessage, From, self()),
          % ask all node to prepare for commit
          Result = ask_nodes_for_commit(ListofEntries, RouterName),
          % clean propagated control msg
          flush(),
          % check the result from first phase
          if Result == timeout orelse Result == abort orelse Children == abort ->
                %  io:format("result is ~w~n", [Result]),
                 % if abort or timeout -> send do Abort
                 % propagate doAbort msg through outgoing edge
                 propagate_control_message(ListofEntries,
                                           [],
                                           {doAbort, SeqNum, self(), self()},
                                           From,
                                           self()),
                 % clean the tentative result of root node
                 if is_list(Children) == true ->
                        % terminate the spawned node
                        lists:foreach(fun (NodePid) ->
                                              exit(NodePid, abort)
                                      end,
                                      Children);
                    true -> % this is typically abort
                        ok
                 end,
                 % de-allocate the Temp Routing Table
                 ets:delete(TempTable),
                 % send abort to controller
                 Pid ! {abort, self(), SeqNum},
                 % complete the 2PC
                 % clean the mail box
                 flush(),
                 process(not_yet_set, RouterName, Table, Cur_SeqNum, false, MsgQueue, {});
             true ->
                 % propagate doCommit msg through outgoing edge
                 propagate_control_message(ListofEntries,
                                           [],
                                           {doCommit, SeqNum, self(), self()},
                                           From,
                                           self()),
                 % get all Obj from Temp Routing table
                 AllObj_from_tempTable = ets:match_object(TempTable, {'$0', '$1'}),
                 % replace the Routing Table
                 ets:insert(Table, AllObj_from_tempTable),
                 % de-allocate the Temp Table
                 ets:delete(TempTable),
                 % eventually send to controller
                 Pid ! {committed, self(), SeqNum},
                 % clean the mail box
                 flush(),
                 % finished 2PC
                 process(not_yet_set, RouterName, Table, SeqNum, false, MsgQueue, {})
          end;
      {control, From, Pid, SeqNum, ControlFun} ->
        %   io:format("~w ~w recv control cur seq ~w, seq ~w in 2pc(~w)~n",[RouterName,self(),Cur_SeqNum,SeqNum,IsIn2PC]),
          % case 1: receive a new control msg with Seq > current one (normal case)
          if Cur_SeqNum < SeqNum andalso IsIn2PC == false ->
                 ControlMessage = {control, From, Pid, SeqNum, ControlFun},
                 ListofEntries = ets:match_object(Table, {'$0', '$1'}),
                 % propagate this control msg through outgoing edges
                 propagate_control_message(ListofEntries, [], ControlMessage, From, From),
                 % create temp routing table
                 TempTable = ets:new(temp_routing_table, [public]),
                 AllObj = ets:match_object(Table, {'$0', '$1'}),
                 % copy all objs to temp routing table from current routing table
                 ets:insert(TempTable, AllObj),
                 % perform the control msg
                 Children = ControlFun(RouterName, TempTable),
                 % store the result, Temp routing and cur_seqNum
                 Updated_TentativeResult = {Children, TempTable, Cur_SeqNum},
                 % set current SeqNum to this SeqNum indicating I'm performing SeqNum : X 2PC
                %  io:format("~w into 2PC~n", [RouterName]),
                 process(RootNode,
                         RouterName,
                         Table,
                         SeqNum,
                         true,
                         MsgQueue,
                         Updated_TentativeResult);
             % case 2: conflicting with two conrtol msg conflict -> rollback the (larger) current one then do the smaller one
             Cur_SeqNum > SeqNum andalso IsIn2PC == true ->
                 % this is the result of current control msg one
                 {_PreChildren, Pre_TempTable, _Previous_SeqNum} = TentativeResult,
                 % deallocate this temptable
                 ets:delete(Pre_TempTable),
                 ControlMessage = {control, From, Pid, SeqNum, ControlFun},
                 ListofEntries = ets:match_object(Table, {'$0', '$1'}),
                 % propage the contol msg with smaller SeqNum one
                 propagate_control_message(ListofEntries, [], ControlMessage, From, From),
                 % create temp routing table
                 TempTable = ets:new(temp_routing_table, [public]),
                 AllObj = ets:match_object(Table, {'$0', '$1'}),
                 % copy all objs to temp routing table from current routing table
                 ets:insert(TempTable, AllObj),
                 % perform the control msg
                 Children = ControlFun(RouterName, TempTable),
                 % store the result, Temp routing and cur_seqNum
                 Updated_TentativeResult = {Children, TempTable, Cur_SeqNum},
                 % set current SeqNum to this SeqNum indicating I'm performing SeqNum : X 2PC
                 process(RootNode,
                         RouterName,
                         Table,
                         SeqNum,
                         true,
                         MsgQueue,
                         Updated_TentativeResult);
             % other old control message
             true ->
                 process(RootNode,
                         RouterName,
                         Table,
                         Cur_SeqNum,
                         IsIn2PC,
                         MsgQueue,
                         TentativeResult)
          end;
      {dump, From} ->
          Dump = ets:match(Table, '$1'),
          From ! {table, self(), Dump},
          process(RootNode, RouterName, Table, Cur_SeqNum, false, MsgQueue, TentativeResult);
      stop ->
          Message = stop,
          if IsIn2PC == true -> % if I am in 2PC, queue this msg
                 New_MsgQueue = MsgQueue ++ [Message],
                 process(RootNode,
                         RouterName,
                         Table,
                         Cur_SeqNum,
                         IsIn2PC,
                         New_MsgQueue,
                         TentativeResult);
             true -> % if I am not in 2PC , operate this stop command
                 % de-allocate the table
                %  io:format("~w exit~n", [RouterName]),
                 ets:delete(Table),
                 exit(stop)
          end
    end.

ask_nodes_for_commit([], _RouterName) ->
    true;
ask_nodes_for_commit([FirstEntry | RestEntries], RouterName) ->
    {DestNodeName, RouteViaPid} = FirstEntry,
    % skip NoInEdge key
    if DestNodeName =/= '$NoInEdges' ->
           % ask node can you commit
        %    io:format("ask ~w to commit ~n", [DestNodeName]),
           RouteViaPid ! {can_you_commit, DestNodeName, self(), RouterName, [self()]},
           receive
             % node reply can Commit will attach their Path for further usage
             {i_can_commit, _Me, _RouteFromPid, FromNodeName, _Deliver_List}
                 when FromNodeName == DestNodeName ->
                 [NextEntry | OtherEntries] = RestEntries,
                 {NextDestNodeName, _NextRouteViaPid} = NextEntry,
                 if NextDestNodeName == '$NoInEdges' ->
                        ask_nodes_for_commit(OtherEntries, RouterName);
                    true ->
                        ask_nodes_for_commit(RestEntries, RouterName)
                 end;
             % if root recv this -> abort
             {i_cannot_commit, _Me, _FromPid, _FromNodeName, _Trace} ->
                 abort
             after 5000 ->
                        % io:format("timeout from ~w~n",[DestNodeName]),
                       timeout
           end;
       true ->
           ask_nodes_for_commit(RestEntries, RouterName)
    end.

propagate_control_message([], Final_List, ForwardMessage, _FromPid, _RootNodePid) ->
    % sending control msg
    lists:foreach(fun (RoutePid) ->
                          RoutePid ! ForwardMessage
                        %   io:format("propage msg from ~w to ~w ~n", [self(), RoutePid])
                  end,
                  Final_List);
propagate_control_message([FirstEntry | RestEntries],
                          List,
                          ForwardMessage,
                          FromPid,
                          RootNodePid) ->
    {DestNodeName, RouteViaPid} = FirstEntry,
    if DestNodeName =/= '$NoInEdges' ->
           % see this pid is in the outgoing list
           Result = lists:member(RouteViaPid, List),
           % prevent the msg flow backward to node who send it and rootnode
           if Result == false andalso FromPid =/= RouteViaPid andalso RootNodePid =/= RouteViaPid ->
                  New_List = [RouteViaPid] ++ List;
              true ->
                  New_List = List
           end;
       true ->
           New_List = List
    end,
    propagate_control_message(RestEntries, New_List, ForwardMessage, FromPid, RootNodePid).

flush() ->
    receive
      _ ->
          flush()
      after 0 ->
                ok
    end.

