%% mob_nfc_nif — Erlang NIF module for the mob_nfc tier-1 plugin.
%%
%% The zig side (priv/native/jni/mob_nfc_nif.zig) and the ObjC side
%% (priv/native/ios/mob_nfc_nif.m) register these NIFs under this module name
%% via their `mob_nfc_nif_nif_init` export. On device the NIF is statically
%% linked into the host binary; on a host dev build it isn't linked, so on_load
%% tolerates the load failure and the stubs fall back to nif_error until the
%% native merge links the sources in.
%%
%% Each async op captures the calling process (enif_self) and delivers results
%% as {:nfc, ...} messages to that process. See lib/mob_nfc.ex for the events.
-module(mob_nfc_nif).
-export([
    nfc_available/0,
    nfc_start_reading/1,
    nfc_start_writing/1,
    nfc_stop_reading/0
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_nfc_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

%% Returns true when the device has an NFC radio that is present and enabled.
nfc_available() ->
    erlang:nif_error(nif_not_loaded).

%% Start a reader session. _OptsJson is a JSON binary, e.g.
%% `{"alert":"Hold your phone near a tag"}` (the iOS reader-sheet prompt;
%% ignored on Android). Captures the caller; NDEF/tag events flow back to it.
nfc_start_reading(_OptsJson) ->
    erlang:nif_error(nif_not_loaded).

%% Start a write session. _OptsJson is a JSON binary, e.g.
%% `{"alert":"...","ndef":"<base64 NDEF message>"}`. Captures the caller; on tag
%% detection the encoded message is written and a {:nfc, :written | :error, _}
%% reply flows back.
nfc_start_writing(_OptsJson) ->
    erlang:nif_error(nif_not_loaded).

%% Stop the active reader session started by this process.
nfc_stop_reading() ->
    erlang:nif_error(nif_not_loaded).
