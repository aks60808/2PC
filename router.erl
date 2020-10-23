-module(router).
-import(lists,[append/1]).
-import(ets,[new/2]).
-export([start/1]).


start(RouterName) ->
  Table = ets:new(routing_table,[]),
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
    {control, From, Pid, SeqNum, ControlFun} when From == Pid ->
      % I am a root router
      Children = ControlFun(Name,Table),
      % eventually send to controller
      Pid ! {committed,self(),SeqNum},
      % or
      Pid ! {abort,self(),SeqNum},
      ok;
    {control, From, Pid, SeqNum, ControlFun} -> ok;
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

