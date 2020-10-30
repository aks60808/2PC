-module(router).
-import(lists,[append/1]).
-import(ets,[new/2,insert/2]).
-export([start/1]).


start(RouterName) ->
  Table = ets:new(routing_table,[public]),
  SpawnPid = spawn(fun()-> process(RouterName,Table,0,false,[]) end),
  SpawnPid.
  


process(RouterName,Table,Cur_SeqNum,IsIn2PC,MsgQueue)->
  receive
    {can_you_commit,DestNodeName,FromPid,FromNodeName} when DestNodeName == RouterName->
      % I am the DestNode 
      % send RootNode back CanCommit via RootNode PID
      FromPid ! {i_can_commit,FromNodeName,RouterName},
      % update to In 2 PC status
      process(RouterName,Table,Cur_SeqNum,true,MsgQueue);
    {can_you_commit,DestNodeName,FromPid,FromNodeName} ->
      % this is not for me -> find which node should take care of it 
      [{_DestNodeName,RouterPid}] = ets:lookup(Table,DestNodeName),
      % forward 
      RouterPid !  {can_you_commit,DestNodeName,FromPid,FromNodeName},
      % only forward this cancommit request so Im not in 2PC
      process(RouterName,Table,Cur_SeqNum,false,MsgQueue);
    % DestNode receive the message
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
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,New_MsgQueue);
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
      process(RouterName,Table,Cur_SeqNum,IsIn2PC,New_MsgQueue);
    {control, _From, _Pid, SeqNum, ControlFun} when SeqNum == 0-> 
      % this is for the initial control message
      ControlFun(RouterName,Table),
      % children will be [] ,nothing spawned
      % not in 2PC !!
      process(RouterName,Table,SeqNum,false,MsgQueue);
    {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
      % I am a root router
      % ask all nodes can commit or not
      ListofEntries = ets:match_object(Table,{'$0','$1'}),
      ControlMessage = {control, self(), Pid, SeqNum, ControlFun},
      Temp_Table = Table,
      Children = ControlFun(RouterName,Temp_Table),
      propagate_control_message(ListofEntries,[],ControlMessage),
      Result = ask_nodes_for_commit(ListofEntries,Pid,RouterName),
      if
        Result == timeout orelse Result == abort orelse Children == abort ->
          send_doAbort(),
          % if timeout send abort
          Pid ! {abort,self(),SeqNum},
          % terminate the 2PC
          process(RouterName,Table,Cur_SeqNum,false,MsgQueue);
        true -> ok
      end,
      % eventually send to controller
      Pid ! {committed,self(),SeqNum},
      % finished 2PC
      process(RouterName,Table,SeqNum,false,MsgQueue);
    {control, From, Pid, SeqNum, ControlFun} -> 
      if
        Cur_SeqNum < SeqNum ->
          ControlMessage = {control, From, Pid, SeqNum, ControlFun},
          ListofEntries = ets:match_object(Table,{'$0','$1'}),
          propagate_control_message(ListofEntries,[],ControlMessage),
          % im doint it here
          Children = ControlFun(RouterName,Table),
          
          process(RouterName,Table,SeqNum,true,MsgQueue);
        true -> process(RouterName,Table,Cur_SeqNum,false,MsgQueue)
      end;
    {dump,From} ->
      Dump = ets:match(Table,'$1'),
      From ! {table,self(),Dump},
      process(RouterName,Table,Cur_SeqNum,false,MsgQueue);
    stop ->
      % de-allocate the table
      ets:delete(Table),
      ok
  end.
ask_nodes_for_commit([],_ControlPid,_RouterName) -> 
  true;
ask_nodes_for_commit([FirstEntry|RestEntries],ControlPid,RouterName) ->
  {DestNodeName,RouteViaPid} = FirstEntry,
  if
    DestNodeName =/= '$NoInEdges' ->
      io:format("send cancommit to ~w~n",[DestNodeName]),
      RouteViaPid ! {can_you_commit,DestNodeName,self(),RouterName};
    true -> ok
  end,
  receive
    {i_can_commit,_Me,From} when From == DestNodeName -> 
      io:format("~w recv the canCommit from ~w~n",[RouterName,From]),
      [NextEntry|OtherEntries] = RestEntries,
      {NextDestNodeName,_NextRouteViaPid} = NextEntry,
      if
        NextDestNodeName == '$NoInEdges' ->
          ask_nodes_for_commit(OtherEntries,ControlPid,RouterName);
        true -> 
          ask_nodes_for_commit(RestEntries,ControlPid,RouterName)
      end;
    {i_cannot_commit,_Me,_From} -> abort
  after 5000 ->
    timeout
  end.
  

propagate_control_message([],Final_List,ForwardMessage) -> 
  io:format("forward node have ~p~n",[Final_List]),
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


