#include "erl_nif.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct {
    ErlNifMutex *mutex;
    int fd;
} lock_resource;

static ErlNifResourceType *lock_type;

static ERL_NIF_TERM error_atom(ErlNifEnv *env, int error) {
    const char *name;
    switch (error) {
    case EACCES: name = "eacces"; break;
    case EBADF: name = "closed"; break;
    case EEXIST: name = "eexist"; break;
    case EINVAL: name = "einval"; break;
    case EIO: name = "eio"; break;
    case EISDIR: name = "eisdir"; break;
    case EMFILE: name = "emfile"; break;
    case ENAMETOOLONG: name = "enametoolong"; break;
    case ENFILE: name = "enfile"; break;
    case ENOENT: name = "enoent"; break;
    case ENOMEM: name = "enomem"; break;
    case ENOSPC: name = "enospc"; break;
    case ENOTDIR: name = "enotdir"; break;
    case EROFS: name = "erofs"; break;
    default: name = "unknown"; break;
    }
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, name));
}

static int path_arg(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *bin, char **out) {
    if (!enif_inspect_binary(env, term, bin) || bin->size == 0 ||
        bin->size >= PATH_MAX || memchr(bin->data, '\0', bin->size) != NULL) return 0;
    *out = enif_alloc(bin->size + 1);
    if (*out == NULL) return 0;
    memcpy(*out, bin->data, bin->size);
    (*out)[bin->size] = '\0';
    return 1;
}

static int write_all_at(int fd, const unsigned char *data, size_t size, off_t offset) {
    size_t done = 0;
    while (done < size) {
        size_t remaining = size - done;
        size_t chunk = remaining > (size_t)SSIZE_MAX ? (size_t)SSIZE_MAX : remaining;
        ssize_t written = pwrite(fd, data + done, chunk, offset + (off_t)done);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { if (written == 0) errno = EIO; return -1; }
        done += (size_t)written;
    }
    return 0;
}

static int write_all(int fd, const unsigned char *data, size_t size) {
    size_t done = 0;
    while (done < size) {
        size_t remaining = size - done;
        size_t chunk = remaining > (size_t)SSIZE_MAX ? (size_t)SSIZE_MAX : remaining;
        ssize_t written = write(fd, data + done, chunk);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { if (written == 0) errno = EIO; return -1; }
        done += (size_t)written;
    }
    return 0;
}

static int sync_parent(const char *path) {
    char *copy = strdup(path);
    char *slash;
    int fd, result, saved;
    if (copy == NULL) { errno = ENOMEM; return -1; }
    slash = strrchr(copy, '/');
    if (slash == NULL) strcpy(copy, ".");
    else if (slash == copy) slash[1] = '\0';
    else *slash = '\0';
    fd = open(copy, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    free(copy);
    if (fd < 0) return -1;
    result = fsync(fd); saved = errno;
    if (close(fd) != 0 && result == 0) { result = -1; saved = errno; }
    errno = saved;
    return result;
}

static void lock_dtor(ErlNifEnv *env, void *object) {
    lock_resource *lock = object;
    (void)env;
    if (lock->mutex != NULL) {
        enif_mutex_lock(lock->mutex);
        if (lock->fd >= 0) { close(lock->fd); lock->fd = -1; }
        enif_mutex_unlock(lock->mutex);
        enif_mutex_destroy(lock->mutex);
        lock->mutex = NULL;
    }
}

static int get_open_lock(ErlNifEnv *env, ERL_NIF_TERM term, lock_resource **out) {
    return enif_get_resource(env, term, lock_type, (void **)out);
}

static ERL_NIF_TERM nif_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin; char *path; int fd, saved; lock_resource *lock; ERL_NIF_TERM term;
    (void)argc;
    if (!path_arg(env, argv[0], &bin, &path)) return enif_make_badarg(env);
    fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600); saved = errno; enif_free(path);
    if (fd < 0) return error_atom(env, saved);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        saved = errno; close(fd);
        if (saved == EWOULDBLOCK || saved == EAGAIN)
            return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "locked"));
        return error_atom(env, saved);
    }
    lock = enif_alloc_resource(lock_type, sizeof(*lock));
    if (lock == NULL) { close(fd); return error_atom(env, ENOMEM); }
    lock->mutex = enif_mutex_create("handbeam_storage_lock"); lock->fd = fd;
    if (lock->mutex == NULL) { close(fd); enif_release_resource(lock); return error_atom(env, ENOMEM); }
    term = enif_make_resource(env, lock); enif_release_resource(lock);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    lock_resource *lock; (void)argc;
    if (!get_open_lock(env, argv[0], &lock)) return enif_make_badarg(env);
    enif_mutex_lock(lock->mutex);
    if (lock->fd >= 0) { close(lock->fd); lock->fd = -1; }
    enif_mutex_unlock(lock->mutex);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_append(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    lock_resource *lock; ErlNifBinary path_bin, data; char *path; ErlNifUInt64 raw_offset;
    int fd = -1, saved = 0, created = 0; off_t offset; (void)argc;
    if (!get_open_lock(env, argv[0], &lock) || !path_arg(env, argv[1], &path_bin, &path))
        return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[2], &raw_offset) || !enif_inspect_binary(env, argv[3], &data)) {
        enif_free(path); return enif_make_badarg(env);
    }
    offset = (off_t)raw_offset;
    if (offset < 0 || (ErlNifUInt64)offset != raw_offset ||
        data.size > (size_t)(INT64_MAX - (int64_t)offset)) {
        enif_free(path); return enif_make_badarg(env);
    }
    enif_mutex_lock(lock->mutex);
    if (lock->fd < 0) saved = EBADF;
    else {
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0 && errno == ENOENT) {
            fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
            if (fd >= 0) created = 1;
            else if (errno == EEXIST) fd = open(path, O_RDWR | O_CLOEXEC);
        }
        if (fd < 0) saved = errno;
        else if (ftruncate(fd, offset) || write_all_at(fd, data.data, data.size, offset) ||
                 fsync(fd) || (created && sync_parent(path))) {
            saved = errno; (void)ftruncate(fd, offset); (void)fsync(fd);
        }
        if (fd >= 0 && close(fd) != 0 && saved == 0) saved = errno;
    }
    enif_mutex_unlock(lock->mutex); enif_free(path);
    return saved ? error_atom(env, saved) : enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_replace(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    lock_resource *lock; ErlNifBinary path_bin, data; char *path, *tmp; size_t length;
    int fd = -1, saved = 0; (void)argc;
    if (!get_open_lock(env, argv[0], &lock) || !path_arg(env, argv[1], &path_bin, &path))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[2], &data)) {
        enif_free(path); return enif_make_badarg(env);
    }
    length = strlen(path) + sizeof(".tmp.XXXXXX"); tmp = enif_alloc(length);
    if (tmp == NULL) { enif_free(path); return error_atom(env, ENOMEM); }
    snprintf(tmp, length, "%s.tmp.XXXXXX", path);
    enif_mutex_lock(lock->mutex);
    if (lock->fd < 0) saved = EBADF;
    else if ((fd = mkstemp(tmp)) < 0) saved = errno;
    else {
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || write_all(fd, data.data, data.size) || fsync(fd))
            saved = errno;
        if (close(fd) != 0 && saved == 0) saved = errno;
        fd = -1;
        if (saved == 0 && (rename(tmp, path) || sync_parent(path))) saved = errno;
    }
    if (fd >= 0) close(fd);
    if (saved) unlink(tmp);
    enif_mutex_unlock(lock->mutex); enif_free(tmp); enif_free(path);
    return saved ? error_atom(env, saved) : enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_remove(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    lock_resource *lock; ErlNifBinary bin; char *path; int saved = 0; (void)argc;
    if (!get_open_lock(env, argv[0], &lock) || !path_arg(env, argv[1], &bin, &path)) return enif_make_badarg(env);
    enif_mutex_lock(lock->mutex);
    if (lock->fd < 0) saved = EBADF;
    else if (unlink(path) || sync_parent(path)) saved = errno;
    enif_mutex_unlock(lock->mutex); enif_free(path);
    return saved ? error_atom(env, saved) : enif_make_atom(env, "ok");
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    ErlNifResourceFlags tried; (void)priv; (void)info;
    lock_type = enif_open_resource_type(env, NULL, "lock", lock_dtor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, &tried);
    return lock_type == NULL ? -1 : 0;
}

static ErlNifFunc funcs[] = {
    {"lock", 1, nif_lock, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 1, nif_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"append_sync", 4, nif_append, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"replace_sync", 3, nif_replace, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"remove_sync", 2, nif_remove, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(handbeam_storage, funcs, load, NULL, NULL, NULL)
