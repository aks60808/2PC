-module(router).
-export([start/1]).


start(RouterName) ->
  spawn(fun()-> process(RouterName) end).

process(RouterName)->
  receive
    {control, From, Pid, 0,Content} ->
      io:format("~w recv ~w from ~w~n",[RouterName,Content,Pid]),
      process(RouterName);
    {control, From, Pid, SeqNum,Content} ->
      io:format("I recv not 0 seq from ~n"),
      process(RouterName)

  end,
  ok.