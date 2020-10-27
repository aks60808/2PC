-module(router).
-import(lists,[append/1]).
-import(ets,[new/2,insert/2]).
-export([start/1]).


start(RouterName) ->
  Table = ets:new(routing_table,[public]),
  spawn(fun()-> process(RouterName,Table) end).
  


process(RouterName,Table)->
  receive
    % DestNode receive the message
    {message, Dest, From,Pid,Trace} when Dest == RouterName ->
      % send controller the receipt
      Pid ! {trace,self(),Trace},
      process(RouterName,Table);
    {message, Dest, From,Pid,Trace} ->
      NewTrace = lists:append(Trace),
      Pid! {message, Dest, self(),Pid,NewTrace},
      process(RouterName,Table);
    {control, _From, _Pid, SeqNum, ControlFun} when SeqNum == 0-> 
      % this is for the initial control message
      ControlFun(RouterName,Table),
      Obj = ets:match_object(Table,{'$0','$1'}),
      io:format("Routing Talbe of ~w (pid: ~w) : ~p~n",[RouterName,self(),Obj]),
      ok;
    {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
      % I am a root router
      % Children = ControlFun(RouterName,Table),
      % eventually send to controller
      Pid ! {committed,self(),SeqNum},
      % or
      Pid ! {abort,self(),SeqNum},
      ok;
    {control, _From, _Pid, SeqNum, ControlFun} -> 
      ControlFun(RouterName,Table),
      Obj = ets:match_object(Table,{'$0','$1'}),
      % io:format("Routing Talbe of ~w : ~p~n",[RouterName,Obj]),
      ok;
    {dump,From} ->
      Dump = ets:match(Table,'$1'),
      From ! {table,self(),Dump},
      ok;
    stop ->
      % de-allocate the table
      ets:delete(Table),
      ok




  end,
  ok.

