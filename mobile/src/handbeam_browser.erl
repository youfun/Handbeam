-module(handbeam_browser).
-export([command/1]).
-on_load(init/0).

init() ->
    case os:getenv("MOB_BEAMS_DIR") of
        false -> ok;
        _ -> erlang:load_nif("handbeam_browser", 0)
    end.

command(_Cmd) ->
    {error, nif_not_loaded}.
