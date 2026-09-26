/* handbeam_ios — thin C NIF. UIKit present lives in ios/AppDelegate.m. */
#include <erl_nif.h>
#include <string.h>

extern int sigil_present_file(const char *path, const char *mode);

static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;

static int copy_iolist(ErlNifEnv *env, ERL_NIF_TERM term, char *buf, size_t buf_size) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin) && !enif_inspect_iolist_as_binary(env, term, &bin))
    return 0;
  if (bin.size + 1 > buf_size)
    return 0;
  memcpy(buf, bin.data, bin.size);
  buf[bin.size] = 0;
  return 1;
}

static ERL_NIF_TERM nif_present_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  char path[4096];
  char mode[16];
  if (argc != 2)
    return enif_make_badarg(env);
  if (!copy_iolist(env, argv[0], path, sizeof(path)))
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "file_unavailable"));
  if (!copy_iolist(env, argv[1], mode, sizeof(mode)))
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "file_unavailable"));
  if (sigil_present_file(path, mode) != 0)
    return enif_make_tuple2(env, am_error, enif_make_atom(env, "file_unavailable"));
  return am_ok;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)load_info;
  am_ok = enif_make_atom(env, "ok");
  am_error = enif_make_atom(env, "error");
  return 0;
}

static ErlNifFunc nif_funcs[] = {{"present_file", 2, nif_present_file, 0}};

ERL_NIF_INIT(handbeam_ios, nif_funcs, load, NULL, NULL, NULL)
