-module(router).
-import(lists,[append/1]).
-import(ets,[new/2,insert/2]).
-export([start/1]).


start(RouterName) ->
  Table = ets:new(routing_table,[public]),
  SpawnPid = spawn(fun()-> process(RouterName,Table) end),
  SpawnPid.
  


process(RouterName,Table)->
  receive
    % DestNode receive the message
    % {message, Dest, From,Pid,Trace} when Dest == RouterName ->
    %   % send controller the receipt
    %   Pid ! {trace,self(),Trace},
    %   process(RouterName,Table);
    % {message, Dest, From,Pid,Trace} ->
    %   NewTrace = lists:append(Trace),
    %   Pid! {message, Dest, self(),Pid,NewTrace},
    %   process(RouterName,Table);
    {control, _From, _Pid, SeqNum, ControlFun} when SeqNum == 0-> 
      % this is for the initial control message
      ControlFun(RouterName,Table),
      Obj = ets:match_object(Table,{'$0','$1'}),
      % io:format("[0] Routing Talbe of ~w (pid: ~w) : ~p~n",[RouterName,self(),Obj]),
      process(RouterName,Table);
    {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
      % I am a root router
      ForwardMessage = {control, From, Pid, SeqNum, ControlFun},
      ListofEntries = ets:match_object(Table,{'$0','$1'}),
      _Children = ControlFun(RouterName,Table),
      io:format("list of entry from ~w : ~p~n",[RouterName,ListofEntries]),
      % propagate_control_message(ListofEntries,[],ForwardMessage),
      Obj = ets:match_object(Table,{'$0','$1'}),
      io:format("[~w] Routing Talbe of ~w (pid: ~w) : ~p~n",[SeqNum,RouterName,self(),Obj]),
      % eventually send to controller
      % Pid ! {committed,self(),SeqNum},
      % % or
      % Pid ! {abort,self(),SeqNum},
      process(RouterName,Table);
    {control, From, _Pid, SeqNum, ControlFun} when From == RouterName -> 
      ControlFun(RouterName,Table),
      Obj = ets:match_object(Table,{'$0','$1'}),
      io:format("[~w] Routing Talbe of ~w (pid: ~w) : ~p~n",[SeqNum,RouterName,self(),Obj]),
      process(RouterName,Table);
    {control, From, Pid, SeqNum, ControlFun} -> 
      io:format("~w receive the propagate control msg~n",[RouterName]),
      ForwardMessage = {control, From, Pid, SeqNum, ControlFun},
      ListofEntries = ets:match_object(Table,{'$0','$1'}),
      _Children = ControlFun(RouterName,Table),
      propagate_control_message(ListofEntries,[],ForwardMessage),
      Obj = ets:match_object(Table,{'$0','$1'}),
      io:format("[~w] Routing Talbe of ~w (pid: ~w) : ~p~n",[SeqNum,RouterName,self(),Obj]),
      process(RouterName,Table);
    {dump,From} ->
      Dump = ets:match(Table,'$1'),
      From ! {table,self(),Dump},
      process(RouterName,Table);
    stop ->
      % de-allocate the table
      ets:delete(Table),
      ok




  end.


propagate_control_message([],Final_List,ForwardMessage) -> 
  io:format("forward node have ~p~n",[Final_List]),
  lists:foreach(fun(RoutePid)->
    RoutePid ! ForwardMessage
    end,Final_List);
propagate_control_message([FirstEntry|RestEntries],List,ForwardMessage) ->
  {_DestNodeName,RouteViaPid} = FirstEntry,
  Result = lists:member(RouteViaPid, List),
  if
    Result == false ->
      New_List = lists:append([RouteViaPid],List);
    true ->
      New_List = List
  end,
  propagate_control_message(RestEntries,New_List,ForwardMessage).


