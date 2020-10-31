-module(router).
-import(lists,[append/1]).
-import(ets,[new/2,insert/2]).
-export([start/1]).


start(RouterName) ->
  Table = ets:new(routing_table,[public]),
  
  SpawnPid = spawn(fun()-> process(RouterName,Table,0,false,[],{}) end),
  io:format("~w : ~w ~n",[RouterName,SpawnPid]),
  SpawnPid.
  


process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult)->
  % process the queued msgs
  if
    IsIn2PC =/= true andalso length(MsgQueue) =/= 0 ->
      lists:foreach(fun (Msg)->
        self()!Msg end,MsgQueue),
        process(RouterName,Table,Cur_SeqNum,IsIn2PC,[],TentativeResult);
    true -> ok
  end,
  % listening
  receive
    {message, Dest, From,Pid,Trace} when Dest == RouterName ->
      % I am the Dest node
      Message = {message, Dest, From,Pid,Trace},
      if 
        IsIn2PC == true -> % if I am in 2PC
          % queue this msg 
          New_MsgQueue = lists:append(MsgQueue,[Message]);
        true -> % if I am not in 2PC
          % process this message
          New_Trace = lists:append([RouterName],Trace),
          % in reverse order
          Reversed_Full_Trace = lists:reverse(New_Trace),
          % send to the controller
          Pid ! {trace,self(),Reversed_Full_Trace},
          % MsgQueue stays the same
          New_MsgQueue = MsgQueue
      end,
      % keep the previous status of IsIn2PC
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,New_MsgQueue,TentativeResult);
    {message, Dest, From,Pid,Trace} ->
      % I am doing the forwarding job
      Message = {message, Dest, From,Pid,Trace},
      if 
        IsIn2PC == true -> % in2PC
          % Queue this msg
          New_MsgQueue = lists:append(MsgQueue,[Message]);
        true ->     % not in 2PC
          % update trace
          New_Trace = lists:append([RouterName],Trace),
          % find which node should I forward to 
          [{_DestNodeName,RouterPid}] = ets:lookup(Table,Dest),
          % send it via routerPID with updated Trace
          RouterPid ! {message, Dest, self(),Pid,New_Trace},
          % same Queue
          New_MsgQueue = MsgQueue
      end,
      % keep the previous status of IsIn2PC
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,New_MsgQueue,TentativeResult);

    {can_you_commit,DestNodeName,FromPid,RootNodeName,Trace} when DestNodeName == RouterName->
      io:format("~w got canyoucommit from ~w~n",[RouterName,FromPid]),
      io:format("Trace is ~p ~n",[Trace]),
      % I am the DestNode 
      {Children,_TempTable} = TentativeResult,
      [LastPid|Rest] = Trace,
      if
        Children == abort ->
          LastPid ! {i_cannot_commit,RootNodeName,self(),RouterName,Rest};
        true ->
          LastPid ! {i_can_commit,RootNodeName,self(),RouterName,Rest}
      end,   
      % keep the status ( now should be in 2PC)
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {can_you_commit,DestNodeName,_FromPid,RootNodeName,Trace} ->
      % this is not for me -> find which node should take care of it 
      [{_DestNodeName,RouterPid}] = ets:lookup(Table,DestNodeName),
      % forward 
      New_Trace = lists:append([self()],Trace),
      RouterPid ! {can_you_commit,DestNodeName,self(),RootNodeName,New_Trace},
      io:format("~w ~w foward can you commit to ~w via ~w~n",[RouterName,self(),DestNodeName,RouterPid]),
      % only forward this cancommit request so Im not in 2PC
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {i_can_commit,RootNodeName,_FromPid,FromNodeName,Trace} ->
      io:format("~w got i can commit of ~w ~n",[RouterName,FromNodeName]),
      % forward canCommit to rootnode
      [LastPid|Rest] = Trace,
      LastPid !  {i_can_commit,RootNodeName,self(),FromNodeName,Rest},
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {i_cannot_commit,RootNodeName,_FromPid,FromNodeName,Trace} ->
      [LastPid|Rest] = Trace,
      LastPid !  {i_cannot_commit,RootNodeName,self(),FromNodeName,Rest},
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    % DestNode receive the message

    {control, _From, _Pid, SeqNum, ControlFun} when SeqNum == 0-> 
      % this is for the initial control message
      ControlFun(RouterName,Table),
      % children will be [] ,nothing spawned
      % not in 2PC !!
      Obj = ets:match_object(Table,{'$0','$1'}),
      io:format("routing table of ~w ~w : ~p~n",[RouterName,self(),Obj]),
      process(RouterName,Table,SeqNum,false,MsgQueue,TentativeResult);
    {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
      % I am a root router
      % ask all nodes can commit or not
      ListofEntries = ets:match_object(Table,{'$0','$1'}),
      ControlMessage = {control, self(), Pid, SeqNum, ControlFun},
      TempTable = ets:new(temp_routing_table,[public]),
      AllObj = ets:match_object(Table,{'$0','$1'}),
      ets:insert(TempTable,AllObj),
      Children = ControlFun(RouterName,TempTable),
      propagate_control_message(ListofEntries,[],ControlMessage),
      Result = ask_nodes_for_commit(ListofEntries,RouterName),
      io:format("result is ~w~n",[Result]),
      if
        Result == timeout orelse Result == abort orelse Children == abort ->
          send_2nd_phase_msg(ListofEntries,SeqNum,RouterName,doAbort),
          
          if
            is_list(Children) == true ->
              lists:foreach(fun(NodePid)->
                exit(NodePid,abort)end,Children);
            true-> % this is typically abort
              ok
          end,
          ets:delete(TempTable),
          Pid ! {abort,self(),SeqNum},
          % terminate the 2PC
          process(RouterName,Table,Cur_SeqNum,false,MsgQueue,{});
        true -> 
          send_2nd_phase_msg(ListofEntries,SeqNum,RouterName,doCommit),
          AllObj_from_tempTable = ets:match_object(TempTable,{'$0','$1'}),
          ets:insert(Table,AllObj_from_tempTable),
          ets:delete(TempTable),
          % eventually send to controller
          Pid ! {committed,self(),SeqNum},
          % finished 2PC
          process(RouterName,Table,SeqNum,false,MsgQueue,{})
      end;
      
    {control, From, Pid, SeqNum, ControlFun} -> 
      if
        Cur_SeqNum < SeqNum ->
          ControlMessage = {control, From, Pid, SeqNum, ControlFun},
          ListofEntries = ets:match_object(Table,{'$0','$1'}),
          propagate_control_message(ListofEntries,[],ControlMessage),
          TempTable = ets:new(temp_routing_table,[public]),
          AllObj = ets:match_object(Table,{'$0','$1'}),
          ets:insert(TempTable,AllObj),
          Children = ControlFun(RouterName,TempTable),
          Updated_TentativeResult = {Children,TempTable},
          process(RouterName,Table,SeqNum,true,MsgQueue,Updated_TentativeResult);
        % old control message
        true -> process(RouterName,Table,Cur_SeqNum,false,MsgQueue,TentativeResult)
      end;
    {doAbort,_SeqNum,DestNodeName,_FromPid,RootNodeName,Trace} when DestNodeName == RouterName -> 
      {Children,TempTable} = TentativeResult,
      if
        is_list(Children) == true ->
          lists:foreach(fun(NodePid)->
            exit(NodePid,abort)end,Children);
        true-> % this is typically abort
          ok
      end,
      ets:delete(TempTable),
      [LastPid|Rest] = Trace,
      LastPid ! {doAbort,ack,RootNodeName,Rest},
      % revert to the previous status, close the 2PC
      process(RouterName,Table,Cur_SeqNum,false,MsgQueue,{});
    {doAbort,SeqNum,DestNodeName,_FromPid,RootNodeName,Trace} -> 
      % forwarding
      New_Trace = lists:append([self()],Trace),
      [{_DestNodeName,RouterPid}] = ets:lookup(Table,DestNodeName),
      RouterPid ! {doAbort,SeqNum,DestNodeName,self(),RootNodeName,New_Trace},
      io:format("~w ~w foward doAbort to ~w via ~w~n",[RouterName,self(),DestNodeName,RouterPid]),
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {doCommit,SeqNum,DestNodeName,FromPid,RootNodeName,Trace} when DestNodeName == RouterName -> 
      io:format("~w ~w recv DoCommit from ~w~n",[RouterName,self(),FromPid]),
      {_Children,TempTable} = TentativeResult,
      [LastPid|Rest] = Trace,
      LastPid ! {doCommit,ack,RootNodeName,Rest},
      AllObj_from_tempTable = ets:match_object(TempTable,{'$0','$1'}),
      ets:insert(Table,AllObj_from_tempTable),
      ets:delete(TempTable),
      % update the latest SeqNum, make TempTable permanent and close the 2PC
      process(RouterName,Table,SeqNum,false,MsgQueue,{});
    {doCommit,SeqNum,DestNodeName,_FromPid,RootNodeName,Trace} -> 
      % forwarding
      New_Trace = lists:append([self()],Trace),
      [{_DestNodeName,RouterPid}] = ets:lookup(Table,DestNodeName),
      RouterPid ! {doCommit,SeqNum,DestNodeName,self(),RootNodeName,New_Trace},
      io:format("~w ~w foward DoCommit to ~w via ~w~n",[RouterName,self(),DestNodeName,RouterPid]),
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {doCommit,ack,RootNodeName,Trace} ->
      [LastPid|Rest] = Trace,
      LastPid ! {doCommit,ack,RootNodeName,Rest},
      io:format("~w ~w recv the doCommit ACK to ~w via ~w~n",[RouterName,self(),RootNodeName,LastPid]),

      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {doAbort,ack,RootNodeName,Trace} ->
      [LastPid|Rest] = Trace,
      LastPid ! {doAbort,ack,RootNodeName,Rest},
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue,TentativeResult);
    {dump,From} ->
      Dump = ets:match(Table,'$1'),
      From ! {table,self(),Dump},
      process(RouterName,Table,Cur_SeqNum,false,MsgQueue,TentativeResult);
    stop ->
      % de-allocate the table
      ets:delete(Table),
      ok
  end.

send_2nd_phase_msg([],_SeqNum,_RouterName,_Command)->ok;
send_2nd_phase_msg([FirstEntry|RestEntries],SeqNum,RouterName,Command)->
  {DestNodeName,RouteViaPid} = FirstEntry,
  if
    DestNodeName =/= '$NoInEdges' ->
      io:format("send 2nd phase to ~w~n",[DestNodeName]),
      RouteViaPid ! {Command,SeqNum,DestNodeName,self(),RouterName,[self()]},
      receive
        {Command,ack,_Me,_Trace} ->
          io:format("Root recv ack from ~n")
      end,
      [NextEntry|OtherEntries] = RestEntries,
      {NextDestNodeName,_NextRouteViaPid} = NextEntry,
      if
        NextDestNodeName == '$NoInEdges' ->
          send_2nd_phase_msg(OtherEntries,SeqNum,RouterName,Command);
        true -> 
          send_2nd_phase_msg(RestEntries,SeqNum,RouterName,Command)
      end;
    true -> send_2nd_phase_msg(RestEntries,SeqNum,RouterName,Command)
  end.

  
  


ask_nodes_for_commit([],_RouterName) -> 
  true;
ask_nodes_for_commit([FirstEntry|RestEntries],RouterName) ->
  {DestNodeName,RouteViaPid} = FirstEntry,
  if
    DestNodeName =/= '$NoInEdges' ->
      io:format("send cancommit to ~w~n",[DestNodeName]),
      RouteViaPid ! {can_you_commit,DestNodeName,self(),RouterName,[self()]},
      receive
        {i_can_commit,_Me,_FromPid,FromNodeName,_Trace} when FromNodeName == DestNodeName -> 
          io:format("~w recv the canCommit from ~w~n",[RouterName,FromNodeName]),
          [NextEntry|OtherEntries] = RestEntries,
        {NextDestNodeName,_NextRouteViaPid} = NextEntry,
          if
            NextDestNodeName == '$NoInEdges' ->
              ask_nodes_for_commit(OtherEntries,RouterName);
            true -> 
              ask_nodes_for_commit(RestEntries,RouterName)
          end;
        {i_cannot_commit,_Me,_FromPid,_FromNodeName,_Trace} -> abort
      after 5000 ->
        timeout
      end;
    true -> ask_nodes_for_commit(RestEntries,RouterName)
  end.
  
  

propagate_control_message([],Final_List,ForwardMessage) -> 
  % io:format("forward node have ~p~n",[Final_List]),
  lists:foreach(fun(RoutePid)->
    RoutePid ! ForwardMessage
    end,Final_List);
propagate_control_message([FirstEntry|RestEntries],List,ForwardMessage) ->
  {DestNodeName,RouteViaPid} = FirstEntry,
  if
    DestNodeName =/= '$NoInEdges' ->
      Result = lists:member(RouteViaPid, List),
      if
        Result == false ->
          New_List = lists:append([RouteViaPid],List);
        true ->
          New_List = List
      end;
    true -> New_List = List
  end,
  propagate_control_message(RestEntries,New_List,ForwardMessage).


