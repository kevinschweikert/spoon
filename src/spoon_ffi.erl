-module(spoon_ffi).
-export([monotonic_time/0]).

monotonic_time() ->
    erlang:monotonic_time(millisecond).
