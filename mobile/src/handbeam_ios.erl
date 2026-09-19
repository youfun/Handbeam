-module(handbeam_ios).
-export([present_file/2]).
-on_load(init/0).

init() ->
    case os:getenv("MOB_BEAMS_DIR") of
        false -> ok;
        _ -> erlang:load_nif("handbeam_ios", 0)
    end.

present_file(_Path, _Mode) ->
    {error, nif_not_loaded}.
