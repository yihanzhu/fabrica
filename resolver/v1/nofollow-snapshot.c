#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif

#define ROOT_PATH_MAX 4096U
#define RECORD_PATH_MAX 4096U
#define CONFIG_FILE_MAX 1048576U
#define PACKED_REFS_MAX 16777216U
#define ADMIN_TOTAL_MAX 33554432U
#define OBJECT_FILE_MAX 67108864U
#define OBJECT_TOTAL_MAX 268435456U
#define OBJECT_ENTRY_MAX 262144U
#define OBJECT_NAME_MAX 16777216U
#define GLOBAL_TOTAL_MAX 536870912U

#define STAGE_NAME ".repository.git.stage"
#define REPOSITORY_NAME "repository.git"

enum error_kind {
    ERROR_NONE = 0,
    ERROR_REPOSITORY,
    ERROR_LIMIT
};

struct error_state {
    enum error_kind kind;
    const char *reason;
};

struct budget {
    uint64_t admin_limit;
    uint64_t object_limit;
    uint64_t entry_limit;
    uint64_t name_limit;
    uint64_t global_limit;
    uint64_t admin_used;
    uint64_t object_used;
    uint64_t entries_used;
    uint64_t names_used;
    uint64_t global_used;
};

struct bytes {
    unsigned char *data;
    size_t len;
};

struct stable_stat {
    dev_t dev;
    ino_t ino;
    mode_t mode;
    off_t size;
    time_t mtime_sec;
    long mtime_nsec;
    time_t ctime_sec;
    long ctime_nsec;
};

enum object_kind {
    OBJECT_LOOSE = 1,
    OBJECT_PACK,
    OBJECT_INDEX
};

struct object_item {
    enum object_kind kind;
    char directory[3];
    char name[80];
    struct stable_stat source;
};

struct object_items {
    struct object_item *items;
    size_t len;
    size_t cap;
};

struct directory_record {
    bool present;
    char name[3];
    struct stable_stat source;
};

struct object_inventory {
    struct object_items copies;
    struct directory_record loose_dirs[256];
    bool pack_present;
    struct stable_stat pack_source;
    struct stable_stat objects_source;
    dev_t objects_device;
};

struct config_facts {
    bool version_seen;
    unsigned version;
    bool object_format_seen;
    bool worktree_config;
    char algorithm[7];
};

struct repository_layout {
    int root_fd;
    int active_fd;
    int common_fd;
    int objects_fd;
    struct stable_stat root_stat;
    struct stable_stat common_stat;
    struct stable_stat objects_stat;
    struct bytes common_config;
    struct bytes worktree_config;
    bool has_worktree_config;
    char algorithm[7];
};

static void set_repository_error(struct error_state *error, const char *reason)
{
    if (error->kind == ERROR_NONE) {
        error->kind = ERROR_REPOSITORY;
        error->reason = reason;
    }
}

static void set_limit_error(struct error_state *error, const char *reason)
{
    if (error->kind == ERROR_NONE) {
        error->kind = ERROR_LIMIT;
        error->reason = reason;
    }
}

static int duplicate_fd(int fd)
{
#ifdef F_DUPFD_CLOEXEC
    int cloexec_copy = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    if (cloexec_copy >= 0 || errno != EINVAL) {
        return cloexec_copy;
    }
#endif
    int copy = dup(fd);
    if (copy >= 0) {
        (void)fcntl(copy, F_SETFD, FD_CLOEXEC);
    }
    return copy;
}

static void close_if_open(int *fd)
{
    if (*fd >= 0) {
        (void)close(*fd);
        *fd = -1;
    }
}

static void free_bytes(struct bytes *value)
{
    free(value->data);
    value->data = NULL;
    value->len = 0U;
}

static void stable_from_stat(const struct stat *source, struct stable_stat *target)
{
    target->dev = source->st_dev;
    target->ino = source->st_ino;
    target->mode = source->st_mode;
    target->size = source->st_size;
#if defined(__APPLE__)
    target->mtime_sec = source->st_mtimespec.tv_sec;
    target->mtime_nsec = source->st_mtimespec.tv_nsec;
    target->ctime_sec = source->st_ctimespec.tv_sec;
    target->ctime_nsec = source->st_ctimespec.tv_nsec;
#else
    target->mtime_sec = source->st_mtim.tv_sec;
    target->mtime_nsec = source->st_mtim.tv_nsec;
    target->ctime_sec = source->st_ctim.tv_sec;
    target->ctime_nsec = source->st_ctim.tv_nsec;
#endif
}

static bool stable_equal(const struct stable_stat *left,
                         const struct stable_stat *right)
{
    return left->dev == right->dev && left->ino == right->ino &&
           left->mode == right->mode && left->size == right->size &&
           left->mtime_sec == right->mtime_sec &&
           left->mtime_nsec == right->mtime_nsec &&
           left->ctime_sec == right->ctime_sec &&
           left->ctime_nsec == right->ctime_nsec;
}

static bool stat_fd_stable(int fd, const struct stable_stat *expected)
{
    struct stat observed;
    struct stable_stat stable;

    if (fstat(fd, &observed) != 0) {
        return false;
    }
    stable_from_stat(&observed, &stable);
    return stable_equal(expected, &stable);
}

static bool charge_global(struct budget *budget, uint64_t amount,
                          struct error_state *error)
{
    if (amount > budget->global_limit - budget->global_used) {
        set_limit_error(error, "global-total");
        return false;
    }
    budget->global_used += amount;
    return true;
}

static bool charge_admin(struct budget *budget, uint64_t amount,
                         struct error_state *error)
{
    if (amount > budget->admin_limit - budget->admin_used) {
        set_limit_error(error, "admin-total");
        return false;
    }
    if (!charge_global(budget, amount, error)) {
        return false;
    }
    budget->admin_used += amount;
    return true;
}

static bool charge_object(struct budget *budget, uint64_t amount,
                          struct error_state *error)
{
    if (amount > OBJECT_FILE_MAX) {
        set_limit_error(error, "object-file");
        return false;
    }
    if (amount > budget->object_limit - budget->object_used) {
        set_limit_error(error, "object-total");
        return false;
    }
    if (!charge_global(budget, amount, error)) {
        return false;
    }
    budget->object_used += amount;
    return true;
}

static bool charge_name(struct budget *budget, size_t length,
                        struct error_state *error)
{
    if (budget->entries_used == budget->entry_limit) {
        set_limit_error(error, "object-entries");
        return false;
    }
    if ((uint64_t)length > budget->name_limit - budget->names_used) {
        set_limit_error(error, "object-names");
        return false;
    }
    budget->entries_used++;
    budget->names_used += (uint64_t)length;
    return true;
}

static bool parse_limit(const char *text, uint64_t maximum, uint64_t *value)
{
    uint64_t parsed = 0U;
    const unsigned char *cursor = (const unsigned char *)text;

    if (*cursor == '\0') {
        return false;
    }
    while (*cursor != '\0') {
        unsigned digit;
        if (*cursor < '0' || *cursor > '9') {
            return false;
        }
        digit = (unsigned)(*cursor - '0');
        if (parsed > (maximum - digit) / 10U) {
            return false;
        }
        parsed = parsed * 10U + digit;
        cursor++;
    }
    *value = parsed;
    return true;
}

static bool valid_utf8(const unsigned char *text, size_t length)
{
    size_t index = 0U;

    while (index < length) {
        unsigned char first = text[index++];
        uint32_t code;
        size_t remaining;

        if (first < 0x80U) {
            if (first < 0x20U || first == 0x7fU) {
                return false;
            }
            continue;
        }
        if (first >= 0xc2U && first <= 0xdfU) {
            code = (uint32_t)(first & 0x1fU);
            remaining = 1U;
        } else if (first >= 0xe0U && first <= 0xefU) {
            code = (uint32_t)(first & 0x0fU);
            remaining = 2U;
        } else if (first >= 0xf0U && first <= 0xf4U) {
            code = (uint32_t)(first & 0x07U);
            remaining = 3U;
        } else {
            return false;
        }
        if (remaining > length - index) {
            return false;
        }
        for (size_t offset = 0U; offset < remaining; offset++) {
            unsigned char next = text[index++];
            if ((next & 0xc0U) != 0x80U) {
                return false;
            }
            code = (code << 6U) | (uint32_t)(next & 0x3fU);
        }
        if ((remaining == 1U && code < 0x80U) ||
            (remaining == 2U && code < 0x800U) ||
            (remaining == 3U && code < 0x10000U) ||
            (code >= 0xd800U && code <= 0xdfffU) || code > 0x10ffffU) {
            return false;
        }
    }
    return true;
}

static bool valid_absolute_input_path(const char *path)
{
    size_t length = strlen(path);
    size_t start;

    if (length == 0U || length > ROOT_PATH_MAX || path[0] != '/' ||
        !valid_utf8((const unsigned char *)path, length)) {
        return false;
    }
    if (length > 1U && path[length - 1U] == '/') {
        return false;
    }
    start = 1U;
    for (size_t index = 1U; index <= length; index++) {
        if (index == length || path[index] == '/') {
            size_t component = index - start;
            if (component == 0U ||
                (component == 1U && path[start] == '.') ||
                (component == 2U && path[start] == '.' &&
                 path[start + 1U] == '.')) {
                return false;
            }
            start = index + 1U;
        }
    }
    return true;
}

static int open_directory_component(int parent, const char *name)
{
    int fd = openat(parent, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat status;
    if (fd < 0 || fstat(fd, &status) != 0 || !S_ISDIR(status.st_mode)) {
        if (fd >= 0) {
            (void)close(fd);
        }
        return -1;
    }
    return fd;
}

static int open_absolute_directory(const char *path)
{
    int current;
    size_t length = strlen(path);
    size_t start = 1U;

    if (!valid_absolute_input_path(path)) {
        return -1;
    }
    current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK |
                            O_CLOEXEC);
    if (current < 0) {
        return -1;
    }
    if (length == 1U) {
        return current;
    }
    for (size_t index = 1U; index <= length; index++) {
        if (index == length || path[index] == '/') {
            char component[NAME_MAX + 1U];
            size_t component_length = index - start;
            int next;
            if (component_length > NAME_MAX) {
                (void)close(current);
                return -1;
            }
            memcpy(component, path + start, component_length);
            component[component_length] = '\0';
            next = open_directory_component(current, component);
            (void)close(current);
            if (next < 0) {
                return -1;
            }
            current = next;
            start = index + 1U;
        }
    }
    return current;
}

static bool split_absolute_parent(const char *path, char **parent_path,
                                  char **leaf)
{
    const char *slash;
    size_t parent_length;

    if (!valid_absolute_input_path(path) || strcmp(path, "/") == 0) {
        return false;
    }
    slash = strrchr(path, '/');
    parent_length = (slash == path) ? 1U : (size_t)(slash - path);
    *parent_path = malloc(parent_length + 1U);
    *leaf = strdup(slash + 1);
    if (*parent_path == NULL || *leaf == NULL) {
        free(*parent_path);
        free(*leaf);
        *parent_path = NULL;
        *leaf = NULL;
        return false;
    }
    memcpy(*parent_path, path, parent_length);
    (*parent_path)[parent_length] = '\0';
    return true;
}

/* Small private SHA-256 implementation used only for the opaque repository identity
 * and copied-file race evidence. It is not exposed as a general hashing command. */
struct sha256_state {
    uint32_t h[8];
    uint64_t bits;
    unsigned char block[64];
    size_t used;
};

static uint32_t rotate_right(uint32_t value, unsigned shift)
{
    return (value >> shift) | (value << (32U - shift));
}

static void sha256_transform(struct sha256_state *state,
                             const unsigned char block[64])
{
    static const uint32_t constants[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
        0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
        0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
        0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
        0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
        0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
        0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
    };
    uint32_t words[64];
    uint32_t a;
    uint32_t b;
    uint32_t c;
    uint32_t d;
    uint32_t e;
    uint32_t f;
    uint32_t g;
    uint32_t h;

    for (size_t index = 0U; index < 16U; index++) {
        size_t offset = index * 4U;
        words[index] = ((uint32_t)block[offset] << 24U) |
                       ((uint32_t)block[offset + 1U] << 16U) |
                       ((uint32_t)block[offset + 2U] << 8U) |
                       (uint32_t)block[offset + 3U];
    }
    for (size_t index = 16U; index < 64U; index++) {
        uint32_t s0 = rotate_right(words[index - 15U], 7U) ^
                      rotate_right(words[index - 15U], 18U) ^
                      (words[index - 15U] >> 3U);
        uint32_t s1 = rotate_right(words[index - 2U], 17U) ^
                      rotate_right(words[index - 2U], 19U) ^
                      (words[index - 2U] >> 10U);
        words[index] = words[index - 16U] + s0 + words[index - 7U] + s1;
    }
    a = state->h[0];
    b = state->h[1];
    c = state->h[2];
    d = state->h[3];
    e = state->h[4];
    f = state->h[5];
    g = state->h[6];
    h = state->h[7];
    for (size_t index = 0U; index < 64U; index++) {
        uint32_t s1 = rotate_right(e, 6U) ^ rotate_right(e, 11U) ^
                      rotate_right(e, 25U);
        uint32_t choice = (e & f) ^ ((~e) & g);
        uint32_t temporary1 = h + s1 + choice + constants[index] + words[index];
        uint32_t s0 = rotate_right(a, 2U) ^ rotate_right(a, 13U) ^
                      rotate_right(a, 22U);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temporary2 = s0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temporary1;
        d = c;
        c = b;
        b = a;
        a = temporary1 + temporary2;
    }
    state->h[0] += a;
    state->h[1] += b;
    state->h[2] += c;
    state->h[3] += d;
    state->h[4] += e;
    state->h[5] += f;
    state->h[6] += g;
    state->h[7] += h;
}

static void sha256_init(struct sha256_state *state)
{
    static const uint32_t initial[8] = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
    };
    memcpy(state->h, initial, sizeof(initial));
    state->bits = 0U;
    state->used = 0U;
}

static void sha256_update(struct sha256_state *state, const unsigned char *data,
                          size_t length)
{
    while (length > 0U) {
        size_t available = sizeof(state->block) - state->used;
        size_t amount = length < available ? length : available;
        memcpy(state->block + state->used, data, amount);
        state->used += amount;
        data += amount;
        length -= amount;
        state->bits += (uint64_t)amount * 8U;
        if (state->used == sizeof(state->block)) {
            sha256_transform(state, state->block);
            state->used = 0U;
        }
    }
}

static void sha256_final(struct sha256_state *state, unsigned char digest[32])
{
    uint64_t bits = state->bits;
    state->block[state->used++] = 0x80U;
    if (state->used > 56U) {
        while (state->used < 64U) {
            state->block[state->used++] = 0U;
        }
        sha256_transform(state, state->block);
        state->used = 0U;
    }
    while (state->used < 56U) {
        state->block[state->used++] = 0U;
    }
    for (size_t index = 0U; index < 8U; index++) {
        state->block[63U - index] = (unsigned char)(bits & 0xffU);
        bits >>= 8U;
    }
    sha256_transform(state, state->block);
    for (size_t index = 0U; index < 8U; index++) {
        digest[index * 4U] = (unsigned char)(state->h[index] >> 24U);
        digest[index * 4U + 1U] = (unsigned char)(state->h[index] >> 16U);
        digest[index * 4U + 2U] = (unsigned char)(state->h[index] >> 8U);
        digest[index * 4U + 3U] = (unsigned char)state->h[index];
    }
}

static void hex_digest(const unsigned char digest[32], char output[65])
{
    static const char hex[] = "0123456789abcdef";
    for (size_t index = 0U; index < 32U; index++) {
        output[index * 2U] = hex[digest[index] >> 4U];
        output[index * 2U + 1U] = hex[digest[index] & 0x0fU];
    }
    output[64] = '\0';
}

static bool valid_record_path(const char *path, bool allow_relative)
{
    size_t length = strlen(path);
    size_t start;

    if (length == 0U || length > RECORD_PATH_MAX ||
        !valid_utf8((const unsigned char *)path, length) ||
        path[length - 1U] == '/') {
        return false;
    }
    if (path[0] != '/' && !allow_relative) {
        return false;
    }
    start = path[0] == '/' ? 1U : 0U;
    for (size_t index = start; index <= length; index++) {
        if (index == length || path[index] == '/') {
            if (index == start) {
                return false;
            }
            start = index + 1U;
        }
    }
    return true;
}

static int record_path_start(int base_fd, const char *path)
{
    if (path[0] == '/') {
        return open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK |
                            O_CLOEXEC);
    }
    return duplicate_fd(base_fd);
}

static int open_record_directory(int base_fd, const char *path)
{
    int current;
    size_t length;
    size_t start;

    if (!valid_record_path(path, true)) {
        return -1;
    }
    length = strlen(path);
    start = path[0] == '/' ? 1U : 0U;
    current = record_path_start(base_fd, path);
    if (current < 0) {
        return -1;
    }
    for (size_t index = start; index <= length; index++) {
        if (index == length || path[index] == '/') {
            char component[NAME_MAX + 1U];
            size_t component_length = index - start;
            int next;
            if (component_length > NAME_MAX) {
                (void)close(current);
                return -1;
            }
            memcpy(component, path + start, component_length);
            component[component_length] = '\0';
            if (strcmp(component, ".") == 0) {
                start = index + 1U;
                continue;
            }
            next = open_directory_component(current, component);
            (void)close(current);
            if (next < 0) {
                return -1;
            }
            current = next;
            start = index + 1U;
        }
    }
    return current;
}

static int open_record_leaf(int base_fd, const char *path,
                            struct stable_stat *stable)
{
    char *copy;
    char *slash;
    char *leaf;
    int parent;
    int fd;
    struct stat status;

    if (!valid_record_path(path, true)) {
        return -1;
    }
    copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }
    slash = strrchr(copy, '/');
    if (slash == NULL) {
        parent = duplicate_fd(base_fd);
        leaf = copy;
    } else {
        leaf = slash + 1;
        if (slash == copy) {
            parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                  O_NONBLOCK | O_CLOEXEC);
        } else {
            *slash = '\0';
            parent = open_record_directory(base_fd, copy);
        }
    }
    if (parent < 0) {
        free(copy);
        return -1;
    }
    fd = openat(parent, leaf,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    (void)close(parent);
    if (fd < 0 || fstat(fd, &status) != 0 || !S_ISREG(status.st_mode)) {
        if (fd >= 0) {
            (void)close(fd);
        }
        free(copy);
        return -1;
    }
    stable_from_stat(&status, stable);
    free(copy);
    return fd;
}

static bool read_open_regular(int fd, const struct stable_stat *before,
                              size_t maximum, struct bytes *output,
                              struct budget *budget,
                              struct error_state *error,
                              const char *limit_reason,
                              const char *repository_reason)
{
    unsigned char extra;
    struct stat after_status;
    struct stable_stat after;
    size_t size;

    if (before->size < 0 || (uintmax_t)before->size > maximum) {
        set_limit_error(error, limit_reason);
        return false;
    }
    size = (size_t)before->size;
    if (!charge_admin(budget, (uint64_t)size, error)) {
        return false;
    }
    output->data = malloc(size + 1U);
    if (output->data == NULL) {
        set_repository_error(error, "io");
        return false;
    }
    output->len = size;
    for (size_t offset = 0U; offset < size;) {
        ssize_t count = pread(fd, output->data + offset, size - offset,
                              (off_t)offset);
        if (count <= 0) {
            set_repository_error(error, repository_reason);
            free_bytes(output);
            return false;
        }
        offset += (size_t)count;
    }
    if (pread(fd, &extra, 1U, (off_t)size) != 0 ||
        fstat(fd, &after_status) != 0) {
        set_repository_error(error, repository_reason);
        free_bytes(output);
        return false;
    }
    stable_from_stat(&after_status, &after);
    if (!stable_equal(before, &after)) {
        set_repository_error(error, "admin-changed");
        free_bytes(output);
        return false;
    }
    output->data[size] = '\0';
    return true;
}

static int open_optional_regular_at(int directory, const char *name,
                                    struct stable_stat *stable, bool *present,
                                    struct error_state *error,
                                    const char *reason)
{
    struct stat status;
    int fd;

    *present = false;
    if (fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) {
            return -1;
        }
        set_repository_error(error, reason);
        return -1;
    }
    if (!S_ISREG(status.st_mode)) {
        set_repository_error(error, reason);
        return -1;
    }
    fd = openat(directory, name,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &status) != 0 || !S_ISREG(status.st_mode)) {
        if (fd >= 0) {
            (void)close(fd);
        }
        set_repository_error(error, reason);
        return -1;
    }
    stable_from_stat(&status, stable);
    *present = true;
    return fd;
}

static bool read_optional_at(int directory, const char *name, size_t maximum,
                             struct bytes *output, bool *present,
                             struct budget *budget,
                             struct error_state *error,
                             const char *limit_reason,
                             const char *repository_reason)
{
    struct stable_stat stable;
    int fd = open_optional_regular_at(directory, name, &stable, present, error,
                                      repository_reason);
    bool ok;

    if (!*present) {
        return error->kind == ERROR_NONE;
    }
    ok = read_open_regular(fd, &stable, maximum, output, budget, error,
                           limit_reason, repository_reason);
    (void)close(fd);
    return ok;
}

static bool record_from_bytes(const struct bytes *input, const char *prefix,
                              char **record, struct error_state *error,
                              const char *reason)
{
    size_t prefix_length = prefix == NULL ? 0U : strlen(prefix);
    size_t end = input->len;

    if (end == 0U || memchr(input->data, '\0', end) != NULL) {
        set_repository_error(error, reason);
        return false;
    }
    if (end > 0U && input->data[end - 1U] == '\n') {
        end--;
        if (end > 0U && input->data[end - 1U] == '\r') {
            end--;
        }
    }
    if (end == 0U || memchr(input->data, '\n', end) != NULL ||
        memchr(input->data, '\r', end) != NULL || end < prefix_length ||
        (prefix_length != 0U &&
         memcmp(input->data, prefix, prefix_length) != 0)) {
        set_repository_error(error, reason);
        return false;
    }
    end -= prefix_length;
    if (end == 0U || end > RECORD_PATH_MAX) {
        set_repository_error(error, reason);
        return false;
    }
    *record = malloc(end + 1U);
    if (*record == NULL) {
        set_repository_error(error, "io");
        return false;
    }
    memcpy(*record, input->data + prefix_length, end);
    (*record)[end] = '\0';
    if (!valid_record_path(*record, true)) {
        free(*record);
        *record = NULL;
        set_repository_error(error, reason);
        return false;
    }
    return true;
}

static char *trim_ascii(char *text)
{
    char *end;
    while (*text == ' ' || *text == '\t') {
        text++;
    }
    end = text + strlen(text);
    while (end > text && (end[-1] == ' ' || end[-1] == '\t')) {
        *--end = '\0';
    }
    if (end - text >= 2 && text[0] == '"' && end[-1] == '"') {
        text++;
        end[-1] = '\0';
    }
    return text;
}

static bool parse_boolean(const char *value, bool *result)
{
    if (strcasecmp(value, "true") == 0 || strcasecmp(value, "yes") == 0 ||
        strcasecmp(value, "on") == 0 || strcmp(value, "1") == 0) {
        *result = true;
        return true;
    }
    if (strcasecmp(value, "false") == 0 || strcasecmp(value, "no") == 0 ||
        strcasecmp(value, "off") == 0 || strcmp(value, "0") == 0) {
        *result = false;
        return true;
    }
    return false;
}

static bool line_continues(const char *line)
{
    size_t length = strlen(line);
    size_t backslashes = 0U;
    while (length > 0U && line[length - 1U] == '\\') {
        backslashes++;
        length--;
    }
    return (backslashes & 1U) != 0U;
}

static bool parse_config(const struct bytes *input, bool common,
                         struct config_facts *facts,
                         struct error_state *error)
{
    char *copy;
    char *cursor;
    char section[64] = "";
    bool continuation = false;

    if (memchr(input->data, '\0', input->len) != NULL) {
        set_repository_error(error, "config-format");
        return false;
    }
    copy = malloc(input->len + 1U);
    if (copy == NULL) {
        set_repository_error(error, "io");
        return false;
    }
    memcpy(copy, input->data, input->len);
    copy[input->len] = '\0';
    cursor = copy;
    while (*cursor != '\0') {
        char *line = cursor;
        char *newline = strchr(cursor, '\n');
        char *text;
        bool next_continuation;

        if (newline != NULL) {
            *newline = '\0';
            cursor = newline + 1;
        } else {
            cursor += strlen(cursor);
        }
        if (*line != '\0' && line[strlen(line) - 1U] == '\r') {
            line[strlen(line) - 1U] = '\0';
        }
        next_continuation = line_continues(line);
        if (continuation) {
            continuation = next_continuation;
            continue;
        }
        text = trim_ascii(line);
        if (*text == '\0' || *text == '#' || *text == ';') {
            continuation = next_continuation;
            continue;
        }
        if (*text == '[') {
            char *close = strrchr(text, ']');
            char *name;
            size_t length = 0U;
            if (close == NULL) {
                set_repository_error(error, "config-format");
                free(copy);
                return false;
            }
            for (char *tail = close + 1; *tail != '\0'; tail++) {
                if (*tail != ' ' && *tail != '\t' && *tail != '#' &&
                    *tail != ';') {
                    set_repository_error(error, "config-format");
                    free(copy);
                    return false;
                }
                if (*tail == '#' || *tail == ';') {
                    break;
                }
            }
            *close = '\0';
            name = trim_ascii(text + 1);
            while (name[length] != '\0' && name[length] != ' ' &&
                   name[length] != '\t' && name[length] != '"') {
                if (!isalnum((unsigned char)name[length]) &&
                    name[length] != '-' && name[length] != '.') {
                    set_repository_error(error, "config-format");
                    free(copy);
                    return false;
                }
                length++;
            }
            if (length == 0U || length >= sizeof(section)) {
                set_repository_error(error, "config-format");
                free(copy);
                return false;
            }
            for (size_t index = 0U; index < length; index++) {
                section[index] = (char)tolower((unsigned char)name[index]);
            }
            section[length] = '\0';
            continuation = false;
            continue;
        }
        {
            char key[64];
            size_t key_length = 0U;
            char *value;
            bool boolean;

            while (text[key_length] != '\0' && text[key_length] != '=' &&
                   text[key_length] != ' ' && text[key_length] != '\t') {
                unsigned char character = (unsigned char)text[key_length];
                if (!isalnum(character) && character != '-') {
                    set_repository_error(error, "config-format");
                    free(copy);
                    return false;
                }
                if (key_length + 1U >= sizeof(key)) {
                    set_repository_error(error, "config-format");
                    free(copy);
                    return false;
                }
                key[key_length] = (char)tolower(character);
                key_length++;
            }
            if (section[0] == '\0' || key_length == 0U) {
                set_repository_error(error, "config-format");
                free(copy);
                return false;
            }
            key[key_length] = '\0';
            value = text + key_length;
            while (*value == ' ' || *value == '\t') {
                value++;
            }
            if (*value == '=') {
                value++;
            } else if (*value != '\0') {
                set_repository_error(error, "config-format");
                free(copy);
                return false;
            }
            value = trim_ascii(value);
            if (strcmp(section, "include") == 0 ||
                strcmp(section, "includeif") == 0) {
                set_repository_error(error, "config-include");
                free(copy);
                return false;
            }
            if (strcmp(key, "promisor") == 0 ||
                strcmp(key, "partialclonefilter") == 0) {
                set_repository_error(error, "promisor");
                free(copy);
                return false;
            }
            if (!common &&
                ((strcmp(section, "core") == 0 &&
                  strcmp(key, "repositoryformatversion") == 0) ||
                 strcmp(section, "extensions") == 0)) {
                set_repository_error(error, "storage-format");
                free(copy);
                return false;
            }
            if (common && strcmp(section, "core") == 0 &&
                strcmp(key, "repositoryformatversion") == 0) {
                if (facts->version_seen ||
                    (strcmp(value, "0") != 0 && strcmp(value, "1") != 0)) {
                    set_repository_error(error, "storage-format");
                    free(copy);
                    return false;
                }
                facts->version_seen = true;
                facts->version = (unsigned)(value[0] - '0');
            } else if (common && strcmp(section, "extensions") == 0 &&
                       strcmp(key, "objectformat") == 0) {
                if (facts->object_format_seen ||
                    strcasecmp(value, "sha256") != 0) {
                    set_repository_error(error, "storage-format");
                    free(copy);
                    return false;
                }
                facts->object_format_seen = true;
                memcpy(facts->algorithm, "sha256", 7U);
            } else if (common && strcmp(section, "extensions") == 0 &&
                       strcmp(key, "worktreeconfig") == 0) {
                if (!parse_boolean(value, &boolean)) {
                    set_repository_error(error, "storage-format");
                    free(copy);
                    return false;
                }
                facts->worktree_config = boolean;
            } else if (common && strcmp(section, "extensions") == 0) {
                set_repository_error(error, "storage-format");
                free(copy);
                return false;
            }
        }
        continuation = next_continuation;
    }
    free(copy);
    if (continuation) {
        set_repository_error(error, "config-format");
        return false;
    }
    if (common) {
        if (!facts->version_seen || facts->version > 1U ||
            (facts->object_format_seen && facts->version != 1U)) {
            set_repository_error(error, "storage-format");
            return false;
        }
        if (!facts->object_format_seen) {
            memcpy(facts->algorithm, "sha1", 5U);
        }
    }
    return true;
}

static bool packed_refs_has_replace(const struct bytes *packed)
{
    size_t start = 0U;
    while (start < packed->len) {
        size_t end = start;
        while (end < packed->len && packed->data[end] != '\n') {
            end++;
        }
        for (size_t index = start; index + 13U <= end; index++) {
            if (memcmp(packed->data + index, "refs/replace/", 13U) == 0 &&
                (index == start || packed->data[index - 1U] == ' ')) {
                return true;
            }
        }
        start = end < packed->len ? end + 1U : end;
    }
    return false;
}

static bool directory_has_entry(int directory, struct error_state *error,
                                const char *reason)
{
    int copy = duplicate_fd(directory);
    DIR *stream;
    struct dirent *entry;
    if (copy < 0) {
        set_repository_error(error, reason);
        return true;
    }
    stream = fdopendir(copy);
    if (stream == NULL) {
        (void)close(copy);
        set_repository_error(error, reason);
        return true;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            (void)closedir(stream);
            return true;
        }
    }
    if (errno != 0) {
        set_repository_error(error, reason);
        (void)closedir(stream);
        return true;
    }
    (void)closedir(stream);
    return false;
}

static bool reject_present_entry(int directory, const char *name,
                                 struct error_state *error,
                                 const char *reason)
{
    struct stat status;
    if (fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0) {
        set_repository_error(error, reason);
        return false;
    }
    if (errno != ENOENT) {
        set_repository_error(error, reason);
        return false;
    }
    return true;
}

static void layout_init(struct repository_layout *layout)
{
    memset(layout, 0, sizeof(*layout));
    layout->root_fd = -1;
    layout->active_fd = -1;
    layout->common_fd = -1;
    layout->objects_fd = -1;
}

static void layout_close(struct repository_layout *layout)
{
    close_if_open(&layout->objects_fd);
    close_if_open(&layout->common_fd);
    close_if_open(&layout->active_fd);
    close_if_open(&layout->root_fd);
    free_bytes(&layout->common_config);
    free_bytes(&layout->worktree_config);
}

static bool require_bare_markers(int root, struct error_state *error)
{
    struct stat status;
    int refs = -1;

    if (fstatat(root, "HEAD", &status, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(status.st_mode)) {
        set_repository_error(error, "layout");
        return false;
    }
    refs = open_directory_component(root, "refs");
    if (refs < 0) {
        set_repository_error(error, "layout");
        return false;
    }
    (void)close(refs);
    return true;
}

static bool check_replacement_state(int common, struct budget *budget,
                                    struct error_state *error)
{
    int refs = -1;
    int replace = -1;
    int info = -1;
    struct stat status;
    struct bytes packed = {0};
    bool present = false;
    bool ok = false;

    if (fstatat(common, "refs", &status, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISDIR(status.st_mode) ||
            (refs = open_directory_component(common, "refs")) < 0) {
            set_repository_error(error, "replacement-state");
            goto done;
        }
        if (fstatat(refs, "replace", &status, AT_SYMLINK_NOFOLLOW) == 0) {
            if (!S_ISDIR(status.st_mode) ||
                (replace = open_directory_component(refs, "replace")) < 0 ||
                directory_has_entry(replace, error, "replacement-state")) {
                set_repository_error(error, "replacement-state");
                goto done;
            }
        } else if (errno != ENOENT) {
            set_repository_error(error, "replacement-state");
            goto done;
        }
    } else if (errno != ENOENT) {
        set_repository_error(error, "replacement-state");
        goto done;
    }

    if (!read_optional_at(common, "packed-refs", PACKED_REFS_MAX, &packed,
                          &present, budget, error, "packed-refs",
                          "packed-refs")) {
        goto done;
    }
    if (present && packed_refs_has_replace(&packed)) {
        set_repository_error(error, "replacement-state");
        goto done;
    }

    if (fstatat(common, "info", &status, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISDIR(status.st_mode) ||
            (info = open_directory_component(common, "info")) < 0 ||
            !reject_present_entry(info, "grafts", error, "replacement-state")) {
            if (error->kind == ERROR_NONE) {
                set_repository_error(error, "replacement-state");
            }
            goto done;
        }
    } else if (errno != ENOENT) {
        set_repository_error(error, "replacement-state");
        goto done;
    }
    ok = true;

done:
    free_bytes(&packed);
    close_if_open(&info);
    close_if_open(&replace);
    close_if_open(&refs);
    return ok;
}

static bool resolve_repository_layout(const char *root_path,
                                      struct repository_layout *layout,
                                      struct budget *budget,
                                      struct error_state *error)
{
    struct stat dot_git_status;
    struct stat status;
    struct stable_stat gitfile_stable;
    struct bytes gitfile = {0};
    struct bytes commondir = {0};
    struct bytes backlink = {0};
    struct config_facts facts = {0};
    char *active_path = NULL;
    char *common_path = NULL;
    char *backlink_path = NULL;
    int gitfile_fd = -1;
    int backlink_fd = -1;
    bool commondir_present = false;
    bool backlink_present = false;
    bool config_present = false;
    bool worktree_present = false;
    bool linked = false;
    bool ok = false;

    layout->root_fd = open_absolute_directory(root_path);
    if (layout->root_fd < 0) {
        set_repository_error(error, "root");
        goto done;
    }
    if (fstat(layout->root_fd, &status) != 0 || !S_ISDIR(status.st_mode)) {
        set_repository_error(error, "root");
        goto done;
    }
    stable_from_stat(&status, &layout->root_stat);

    if (fstatat(layout->root_fd, ".git", &dot_git_status,
                AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT || !require_bare_markers(layout->root_fd, error)) {
            if (error->kind == ERROR_NONE) {
                set_repository_error(error, "layout");
            }
            goto done;
        }
        layout->active_fd = duplicate_fd(layout->root_fd);
        if (layout->active_fd < 0) {
            set_repository_error(error, "io");
            goto done;
        }
    } else if (S_ISDIR(dot_git_status.st_mode)) {
        layout->active_fd = open_directory_component(layout->root_fd, ".git");
        if (layout->active_fd < 0) {
            set_repository_error(error, "layout");
            goto done;
        }
    } else if (S_ISREG(dot_git_status.st_mode)) {
        linked = true;
        gitfile_fd = openat(layout->root_fd, ".git",
                            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (gitfile_fd < 0 || fstat(gitfile_fd, &status) != 0 ||
            !S_ISREG(status.st_mode)) {
            set_repository_error(error, "gitfile");
            goto done;
        }
        stable_from_stat(&status, &gitfile_stable);
        if (!read_open_regular(gitfile_fd, &gitfile_stable, RECORD_PATH_MAX,
                               &gitfile, budget, error, "admin-file",
                               "gitfile") ||
            !record_from_bytes(&gitfile, "gitdir: ", &active_path, error,
                               "gitfile")) {
            goto done;
        }
        layout->active_fd = open_record_directory(layout->root_fd, active_path);
        if (layout->active_fd < 0) {
            set_repository_error(error, "gitfile");
            goto done;
        }
    } else {
        set_repository_error(error, "layout");
        goto done;
    }

    if (!read_optional_at(layout->active_fd, "commondir", RECORD_PATH_MAX,
                          &commondir, &commondir_present, budget, error,
                          "admin-file", "commondir")) {
        goto done;
    }
    if (commondir_present) {
        if (!record_from_bytes(&commondir, NULL, &common_path, error,
                               "commondir")) {
            goto done;
        }
        layout->common_fd = open_record_directory(layout->active_fd, common_path);
        if (layout->common_fd < 0) {
            set_repository_error(error, "commondir");
            goto done;
        }
    } else {
        layout->common_fd = duplicate_fd(layout->active_fd);
        if (layout->common_fd < 0) {
            set_repository_error(error, "io");
            goto done;
        }
    }

    if (linked) {
        if (!read_optional_at(layout->active_fd, "gitdir", RECORD_PATH_MAX,
                              &backlink, &backlink_present, budget, error,
                              "admin-file", "backlink") ||
            !backlink_present ||
            !record_from_bytes(&backlink, NULL, &backlink_path, error,
                               "backlink")) {
            if (error->kind == ERROR_NONE) {
                set_repository_error(error, "backlink");
            }
            goto done;
        }
        backlink_fd = open_record_leaf(layout->active_fd, backlink_path,
                                       &layout->common_stat);
        if (backlink_fd < 0 ||
            layout->common_stat.dev != gitfile_stable.dev ||
            layout->common_stat.ino != gitfile_stable.ino) {
            set_repository_error(error, "backlink");
            goto done;
        }
        close_if_open(&backlink_fd);
    }

    if (fstat(layout->common_fd, &status) != 0 || !S_ISDIR(status.st_mode)) {
        set_repository_error(error, "layout");
        goto done;
    }
    stable_from_stat(&status, &layout->common_stat);

    if (!read_optional_at(layout->common_fd, "config", CONFIG_FILE_MAX,
                          &layout->common_config, &config_present, budget, error,
                          "admin-file", "admin-file") ||
        !config_present ||
        !parse_config(&layout->common_config, true, &facts, error)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "admin-file");
        }
        goto done;
    }
    if (!read_optional_at(layout->active_fd, "config.worktree", CONFIG_FILE_MAX,
                          &layout->worktree_config, &worktree_present, budget,
                          error, "admin-file", "admin-file")) {
        goto done;
    }
    layout->has_worktree_config = worktree_present;
    if (worktree_present &&
        !parse_config(&layout->worktree_config, false, &facts, error)) {
        goto done;
    }

    if (!check_replacement_state(layout->common_fd, budget, error)) {
        goto done;
    }
    layout->objects_fd = open_directory_component(layout->common_fd, "objects");
    if (layout->objects_fd < 0 || fstat(layout->objects_fd, &status) != 0 ||
        !S_ISDIR(status.st_mode)) {
        set_repository_error(error, "object-store");
        goto done;
    }
    stable_from_stat(&status, &layout->objects_stat);
    memcpy(layout->algorithm, facts.algorithm, sizeof(layout->algorithm));
    ok = true;

done:
    close_if_open(&backlink_fd);
    close_if_open(&gitfile_fd);
    free(active_path);
    free(common_path);
    free(backlink_path);
    free_bytes(&backlink);
    free_bytes(&commondir);
    free_bytes(&gitfile);
    return ok;
}

static bool lowercase_hex(const char *text, size_t length)
{
    for (size_t index = 0U; index < length; index++) {
        if (!((text[index] >= '0' && text[index] <= '9') ||
              (text[index] >= 'a' && text[index] <= 'f'))) {
            return false;
        }
    }
    return true;
}

static unsigned hex_byte(const char name[2])
{
    unsigned high = (unsigned)(name[0] <= '9' ? name[0] - '0' : name[0] - 'a' + 10);
    unsigned low = (unsigned)(name[1] <= '9' ? name[1] - '0' : name[1] - 'a' + 10);
    return high * 16U + low;
}

static bool add_object_item(struct object_items *items,
                            const struct object_item *item,
                            struct error_state *error)
{
    if (items->len == items->cap) {
        size_t capacity = items->cap == 0U ? 128U : items->cap * 2U;
        struct object_item *resized;
        if (capacity < items->cap || capacity > OBJECT_ENTRY_MAX) {
            set_limit_error(error, "object-entries");
            return false;
        }
        resized = realloc(items->items, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_repository_error(error, "io");
            return false;
        }
        items->items = resized;
        items->cap = capacity;
    }
    items->items[items->len++] = *item;
    return true;
}

static bool entry_stat(int directory, const char *name, dev_t device,
                       struct stable_stat *stable, struct error_state *error)
{
    struct stat status;
    if (fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        set_repository_error(error, "object-changed");
        return false;
    }
    if (status.st_dev != device) {
        set_repository_error(error, "object-device");
        return false;
    }
    stable_from_stat(&status, stable);
    return true;
}

static bool stable_directory_after(int directory,
                                   const struct stable_stat *before,
                                   struct error_state *error)
{
    if (!stat_fd_stable(directory, before)) {
        set_repository_error(error, "object-changed");
        return false;
    }
    return true;
}

static bool inventory_loose_directory(int directory, const char fanout[3],
                                      size_t oid_length,
                                      struct object_inventory *inventory,
                                      struct budget *budget,
                                      struct error_state *error,
                                      const struct stable_stat *directory_stat)
{
    int copy = duplicate_fd(directory);
    DIR *stream;
    struct dirent *entry;
    bool ok = false;

    if (copy < 0 || (stream = fdopendir(copy)) == NULL) {
        if (copy >= 0) {
            (void)close(copy);
        }
        set_repository_error(error, "object-store");
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        struct stable_stat stable;
        struct object_item item;
        size_t length;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        length = strlen(entry->d_name);
        if (!charge_name(budget, length, error) ||
            !entry_stat(directory, entry->d_name, inventory->objects_device,
                        &stable, error)) {
            goto done;
        }
        if (!S_ISREG(stable.mode)) {
            set_repository_error(error, "object-type");
            goto done;
        }
        if (length != oid_length - 2U || !lowercase_hex(entry->d_name, length)) {
            set_repository_error(error,
                                 (length == 38U || length == 62U)
                                     ? "object-format"
                                     : "object-name");
            goto done;
        }
        if (stable.size < 0 || !charge_object(budget, (uint64_t)stable.size, error)) {
            if (error->kind == ERROR_NONE) {
                set_repository_error(error, "object-file");
            }
            goto done;
        }
        memset(&item, 0, sizeof(item));
        item.kind = OBJECT_LOOSE;
        memcpy(item.directory, fanout, 3U);
        memcpy(item.name, entry->d_name, length + 1U);
        item.source = stable;
        if (!add_object_item(&inventory->copies, &item, error)) {
            goto done;
        }
    }
    if (errno != 0 || !stable_directory_after(directory, directory_stat, error)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "object-store");
        }
        goto done;
    }
    ok = true;
done:
    (void)closedir(stream);
    return ok;
}

static bool valid_pack_name(const char *name, size_t oid_length,
                            enum object_kind *kind, bool *metadata,
                            bool *promisor)
{
    size_t length = strlen(name);
    size_t prefix = 5U + oid_length;
    const char *extension;

    *metadata = false;
    *promisor = false;
    if (strcmp(name, "multi-pack-index") == 0) {
        *metadata = true;
        return true;
    }
    if (length <= prefix || memcmp(name, "pack-", 5U) != 0 ||
        !lowercase_hex(name + 5U, oid_length)) {
        if (strncmp(name, "multi-pack-index-", 17U) == 0) {
            const char *hash = name + 17U;
            if (strlen(hash) == oid_length + 7U &&
                lowercase_hex(hash, oid_length) &&
                (strcmp(hash + oid_length, ".bitmap") == 0 ||
                 strcmp(hash + oid_length, ".rev") == 0)) {
                *metadata = true;
                return true;
            }
        }
        return false;
    }
    extension = name + prefix;
    if (strcmp(extension, ".pack") == 0) {
        *kind = OBJECT_PACK;
        return true;
    }
    if (strcmp(extension, ".idx") == 0) {
        *kind = OBJECT_INDEX;
        return true;
    }
    if (strcmp(extension, ".promisor") == 0) {
        *promisor = true;
        return true;
    }
    if (strcmp(extension, ".bitmap") == 0 || strcmp(extension, ".rev") == 0 ||
        strcmp(extension, ".keep") == 0 || strcmp(extension, ".mtimes") == 0) {
        *metadata = true;
        return true;
    }
    return false;
}

static bool inventory_pack_directory(int directory, size_t oid_length,
                                     struct object_inventory *inventory,
                                     struct budget *budget,
                                     struct error_state *error,
                                     const struct stable_stat *directory_stat)
{
    int copy = duplicate_fd(directory);
    DIR *stream;
    struct dirent *entry;
    bool ok = false;

    if (copy < 0 || (stream = fdopendir(copy)) == NULL) {
        if (copy >= 0) {
            (void)close(copy);
        }
        set_repository_error(error, "object-store");
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        struct stable_stat stable;
        struct object_item item;
        enum object_kind kind = OBJECT_PACK;
        bool metadata;
        bool promisor;
        size_t length;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        length = strlen(entry->d_name);
        if (!charge_name(budget, length, error) ||
            !entry_stat(directory, entry->d_name, inventory->objects_device,
                        &stable, error)) {
            goto done;
        }
        if (!S_ISREG(stable.mode)) {
            set_repository_error(error, "object-type");
            goto done;
        }
        if (!valid_pack_name(entry->d_name, oid_length, &kind, &metadata,
                             &promisor)) {
            set_repository_error(error, "object-name");
            goto done;
        }
        if (promisor) {
            set_repository_error(error, "promisor");
            goto done;
        }
        if (metadata) {
            continue;
        }
        if (stable.size < 0 || !charge_object(budget, (uint64_t)stable.size, error)) {
            if (error->kind == ERROR_NONE) {
                set_repository_error(error, "object-file");
            }
            goto done;
        }
        memset(&item, 0, sizeof(item));
        item.kind = kind;
        memcpy(item.name, entry->d_name, length + 1U);
        item.source = stable;
        if (!add_object_item(&inventory->copies, &item, error)) {
            goto done;
        }
    }
    if (errno != 0 || !stable_directory_after(directory, directory_stat, error)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "object-store");
        }
        goto done;
    }
    ok = true;
done:
    (void)closedir(stream);
    return ok;
}

static bool valid_graph_name(const char *name, size_t oid_length)
{
    if (strcmp(name, "commit-graph-chain") == 0) {
        return true;
    }
    return strncmp(name, "graph-", 6U) == 0 &&
           strlen(name) == 6U + oid_length + 6U &&
           lowercase_hex(name + 6U, oid_length) &&
           strcmp(name + 6U + oid_length, ".graph") == 0;
}

static bool inventory_commit_graphs(int directory, size_t oid_length,
                                    struct object_inventory *inventory,
                                    struct budget *budget,
                                    struct error_state *error,
                                    const struct stable_stat *directory_stat)
{
    int copy = duplicate_fd(directory);
    DIR *stream;
    struct dirent *entry;
    bool ok = false;
    if (copy < 0 || (stream = fdopendir(copy)) == NULL) {
        if (copy >= 0) {
            (void)close(copy);
        }
        set_repository_error(error, "object-store");
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        struct stable_stat stable;
        size_t length;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        length = strlen(entry->d_name);
        if (!charge_name(budget, length, error) ||
            !entry_stat(directory, entry->d_name, inventory->objects_device,
                        &stable, error)) {
            goto done;
        }
        if (!S_ISREG(stable.mode)) {
            set_repository_error(error, "object-type");
            goto done;
        }
        if (!valid_graph_name(entry->d_name, oid_length)) {
            set_repository_error(error, "object-name");
            goto done;
        }
    }
    if (errno != 0 || !stable_directory_after(directory, directory_stat, error)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "object-store");
        }
        goto done;
    }
    ok = true;
done:
    (void)closedir(stream);
    return ok;
}

static bool inventory_info_directory(int directory, size_t oid_length,
                                     struct object_inventory *inventory,
                                     struct budget *budget,
                                     struct error_state *error,
                                     const struct stable_stat *directory_stat)
{
    int copy = duplicate_fd(directory);
    DIR *stream;
    struct dirent *entry;
    bool ok = false;
    if (copy < 0 || (stream = fdopendir(copy)) == NULL) {
        if (copy >= 0) {
            (void)close(copy);
        }
        set_repository_error(error, "object-store");
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        struct stable_stat stable;
        size_t length;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        length = strlen(entry->d_name);
        if (!charge_name(budget, length, error) ||
            !entry_stat(directory, entry->d_name, inventory->objects_device,
                        &stable, error)) {
            goto done;
        }
        if (strcmp(entry->d_name, "alternates") == 0 ||
            strcmp(entry->d_name, "http-alternates") == 0) {
            set_repository_error(error, "alternate");
            goto done;
        }
        if (strcmp(entry->d_name, "commit-graphs") == 0) {
            int graphs = -1;
            if (!S_ISDIR(stable.mode) ||
                (graphs = open_directory_component(directory, entry->d_name)) < 0 ||
                !inventory_commit_graphs(graphs, oid_length, inventory, budget,
                                         error, &stable)) {
                if (error->kind == ERROR_NONE) {
                    set_repository_error(error, "object-type");
                }
                if (graphs >= 0) {
                    (void)close(graphs);
                }
                goto done;
            }
            (void)close(graphs);
        } else {
            if (!S_ISREG(stable.mode)) {
                set_repository_error(error, "object-type");
                goto done;
            }
            if (strcmp(entry->d_name, "packs") != 0 &&
                strcmp(entry->d_name, "commit-graph") != 0) {
                set_repository_error(error, "object-name");
                goto done;
            }
        }
    }
    if (errno != 0 || !stable_directory_after(directory, directory_stat, error)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "object-store");
        }
        goto done;
    }
    ok = true;
done:
    (void)closedir(stream);
    return ok;
}

static int object_item_compare(const void *left_value, const void *right_value)
{
    const struct object_item *left = left_value;
    const struct object_item *right = right_value;
    if (left->kind == OBJECT_LOOSE && right->kind != OBJECT_LOOSE) {
        return -1;
    }
    if (left->kind != OBJECT_LOOSE && right->kind == OBJECT_LOOSE) {
        return 1;
    }
    if (left->kind == OBJECT_LOOSE) {
        int directory = strcmp(left->directory, right->directory);
        return directory != 0 ? directory : strcmp(left->name, right->name);
    }
    return strcmp(left->name, right->name);
}

static bool validate_pack_pairs(const struct object_inventory *inventory,
                                size_t oid_length,
                                struct error_state *error)
{
    size_t index = 0U;
    size_t prefix_length = 5U + oid_length;
    while (index < inventory->copies.len &&
           inventory->copies.items[index].kind == OBJECT_LOOSE) {
        index++;
    }
    while (index < inventory->copies.len) {
        size_t next = index + 1U;
        while (next < inventory->copies.len &&
               memcmp(inventory->copies.items[index].name,
                      inventory->copies.items[next].name, prefix_length) == 0) {
            next++;
        }
        if (next - index != 2U ||
            inventory->copies.items[index].kind ==
                inventory->copies.items[index + 1U].kind) {
            set_repository_error(error, "object-pair");
            return false;
        }
        index = next;
    }
    return true;
}

static bool inventory_objects(struct repository_layout *layout,
                              struct object_inventory *inventory,
                              struct budget *budget,
                              struct error_state *error)
{
    int copy;
    DIR *stream;
    struct dirent *entry;
    size_t oid_length = strcmp(layout->algorithm, "sha256") == 0 ? 64U : 40U;
    bool ok = false;

    memset(inventory, 0, sizeof(*inventory));
    inventory->objects_source = layout->objects_stat;
    inventory->objects_device = layout->objects_stat.dev;
    copy = duplicate_fd(layout->objects_fd);
    if (copy < 0 || (stream = fdopendir(copy)) == NULL) {
        if (copy >= 0) {
            (void)close(copy);
        }
        set_repository_error(error, "object-store");
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        struct stable_stat stable;
        size_t length;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        length = strlen(entry->d_name);
        if (!charge_name(budget, length, error) ||
            !entry_stat(layout->objects_fd, entry->d_name,
                        inventory->objects_device, &stable, error)) {
            goto done;
        }
        if (length == 2U && lowercase_hex(entry->d_name, 2U)) {
            unsigned slot;
            int directory;
            if (!S_ISDIR(stable.mode) ||
                (directory = open_directory_component(layout->objects_fd,
                                                      entry->d_name)) < 0) {
                set_repository_error(error, "object-type");
                goto done;
            }
            slot = hex_byte(entry->d_name);
            inventory->loose_dirs[slot].present = true;
            memcpy(inventory->loose_dirs[slot].name, entry->d_name, 3U);
            inventory->loose_dirs[slot].source = stable;
            if (!inventory_loose_directory(directory, entry->d_name, oid_length,
                                           inventory, budget, error, &stable)) {
                (void)close(directory);
                goto done;
            }
            (void)close(directory);
        } else if (strcmp(entry->d_name, "pack") == 0 ||
                   strcmp(entry->d_name, "info") == 0) {
            int directory;
            if (!S_ISDIR(stable.mode) ||
                (directory = open_directory_component(layout->objects_fd,
                                                      entry->d_name)) < 0) {
                set_repository_error(error, "object-type");
                goto done;
            }
            if (entry->d_name[0] == 'p') {
                inventory->pack_present = true;
                inventory->pack_source = stable;
                if (!inventory_pack_directory(directory, oid_length, inventory,
                                              budget, error, &stable)) {
                    (void)close(directory);
                    goto done;
                }
            } else if (!inventory_info_directory(directory, oid_length, inventory,
                                                 budget, error, &stable)) {
                (void)close(directory);
                goto done;
            }
            (void)close(directory);
        } else {
            if (!S_ISREG(stable.mode) && !S_ISDIR(stable.mode)) {
                set_repository_error(error, "object-type");
            } else {
                set_repository_error(error, "object-name");
            }
            goto done;
        }
    }
    if (errno != 0 ||
        !stable_directory_after(layout->objects_fd, &layout->objects_stat, error)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "object-store");
        }
        goto done;
    }
    qsort(inventory->copies.items, inventory->copies.len,
          sizeof(*inventory->copies.items), object_item_compare);
    if (!validate_pack_pairs(inventory, oid_length, error)) {
        goto done;
    }
    ok = true;
done:
    (void)closedir(stream);
    return ok;
}

struct destination_context {
    int parent_fd;
    int slot_fd;
    int stage_fd;
    char *slot_name;
    bool slot_created;
    bool stage_exists;
};

static void destination_init(struct destination_context *destination)
{
    memset(destination, 0, sizeof(*destination));
    destination->parent_fd = -1;
    destination->slot_fd = -1;
    destination->stage_fd = -1;
}

static bool same_identity(const struct stat *status,
                          const struct stable_stat *identity)
{
    return status->st_dev == identity->dev && status->st_ino == identity->ino;
}

static bool descriptor_has_ancestor(int descriptor,
                                    const struct stable_stat *identity)
{
    int current = duplicate_fd(descriptor);
    if (current < 0) {
        return true;
    }
    for (;;) {
        struct stat here;
        struct stat parent_status;
        int parent;
        if (fstat(current, &here) != 0) {
            (void)close(current);
            return true;
        }
        if (same_identity(&here, identity)) {
            (void)close(current);
            return true;
        }
        parent = open_directory_component(current, "..");
        if (parent < 0 || fstat(parent, &parent_status) != 0) {
            if (parent >= 0) {
                (void)close(parent);
            }
            (void)close(current);
            return true;
        }
        if (here.st_dev == parent_status.st_dev && here.st_ino == parent_status.st_ino) {
            (void)close(parent);
            (void)close(current);
            return false;
        }
        (void)close(current);
        current = parent;
    }
}

static bool directory_empty(int descriptor)
{
    int copy = duplicate_fd(descriptor);
    DIR *stream;
    struct dirent *entry;
    bool empty = true;
    if (copy < 0 || (stream = fdopendir(copy)) == NULL) {
        if (copy >= 0) {
            (void)close(copy);
        }
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            empty = false;
            break;
        }
    }
    if (errno != 0) {
        empty = false;
    }
    (void)closedir(stream);
    return empty;
}

static bool prepare_destination(const char *path,
                                const struct repository_layout *layout,
                                struct destination_context *destination,
                                struct error_state *error)
{
    char *parent_path = NULL;
    struct stat status;
    bool ok = false;

    if (!split_absolute_parent(path, &parent_path, &destination->slot_name)) {
        set_repository_error(error, "destination");
        goto done;
    }
    destination->parent_fd = open_absolute_directory(parent_path);
    if (destination->parent_fd < 0 ||
        descriptor_has_ancestor(destination->parent_fd, &layout->root_stat) ||
        descriptor_has_ancestor(destination->parent_fd, &layout->common_stat) ||
        descriptor_has_ancestor(destination->parent_fd, &layout->objects_stat)) {
        set_repository_error(error, "destination");
        goto done;
    }
    if (fstatat(destination->parent_fd, destination->slot_name, &status,
                AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT ||
            mkdirat(destination->parent_fd, destination->slot_name, 0700) != 0) {
            set_repository_error(error, "destination");
            goto done;
        }
        destination->slot_created = true;
    } else if (!S_ISDIR(status.st_mode)) {
        set_repository_error(error, "destination");
        goto done;
    }
    destination->slot_fd = open_directory_component(destination->parent_fd,
                                                     destination->slot_name);
    if (destination->slot_fd < 0 || fstat(destination->slot_fd, &status) != 0 ||
        status.st_uid != geteuid() || (status.st_mode & 0077U) != 0U ||
        descriptor_has_ancestor(destination->slot_fd, &layout->root_stat) ||
        descriptor_has_ancestor(destination->slot_fd, &layout->common_stat) ||
        descriptor_has_ancestor(destination->slot_fd, &layout->objects_stat) ||
        !directory_empty(destination->slot_fd)) {
        set_repository_error(error, "destination");
        goto done;
    }
    if (mkdirat(destination->slot_fd, STAGE_NAME, 0700) != 0) {
        set_repository_error(error, "publish");
        goto done;
    }
    destination->stage_exists = true;
    destination->stage_fd = open_directory_component(destination->slot_fd,
                                                      STAGE_NAME);
    if (destination->stage_fd < 0) {
        set_repository_error(error, "publish");
        goto done;
    }
    ok = true;
done:
    free(parent_path);
    return ok;
}

static void remove_tree_at(int parent, const char *name)
{
    int directory = open_directory_component(parent, name);
    int copy;
    DIR *stream;
    struct dirent *entry;
    if (directory < 0) {
        (void)unlinkat(parent, name, 0);
        return;
    }
    copy = duplicate_fd(directory);
    if (copy >= 0 && (stream = fdopendir(copy)) != NULL) {
        while ((entry = readdir(stream)) != NULL) {
            struct stat status;
            if (strcmp(entry->d_name, ".") == 0 ||
                strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            if (fstatat(directory, entry->d_name, &status,
                        AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(status.st_mode)) {
                remove_tree_at(directory, entry->d_name);
            } else {
                (void)unlinkat(directory, entry->d_name, 0);
            }
        }
        (void)closedir(stream);
    } else if (copy >= 0) {
        (void)close(copy);
    }
    (void)close(directory);
    (void)unlinkat(parent, name, AT_REMOVEDIR);
}

static void destination_close(struct destination_context *destination,
                              bool success)
{
    close_if_open(&destination->stage_fd);
    if (!success && destination->stage_exists && destination->slot_fd >= 0) {
        remove_tree_at(destination->slot_fd, STAGE_NAME);
    }
    close_if_open(&destination->slot_fd);
    if (!success && destination->slot_created && destination->parent_fd >= 0 &&
        destination->slot_name != NULL) {
        (void)unlinkat(destination->parent_fd, destination->slot_name,
                       AT_REMOVEDIR);
    }
    close_if_open(&destination->parent_fd);
    free(destination->slot_name);
    destination->slot_name = NULL;
}

static int make_directory_at(int parent, const char *name,
                             struct error_state *error)
{
    int descriptor;
    if (mkdirat(parent, name, 0700) != 0) {
        set_repository_error(error, "publish");
        return -1;
    }
    descriptor = open_directory_component(parent, name);
    if (descriptor < 0) {
        set_repository_error(error, "publish");
    }
    return descriptor;
}

static bool write_all(int descriptor, const unsigned char *data, size_t length)
{
    size_t offset = 0U;
    while (offset < length) {
        ssize_t count = write(descriptor, data + offset, length - offset);
        if (count <= 0) {
            return false;
        }
        offset += (size_t)count;
    }
    return true;
}

static bool write_private_file(int parent, const char *name,
                               const unsigned char *data, size_t length,
                               struct error_state *error)
{
    int descriptor = openat(parent, name,
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            0600);
    bool ok = false;
    if (descriptor < 0 || !write_all(descriptor, data, length) ||
        fchmod(descriptor, 0400) != 0) {
        set_repository_error(error, "publish");
        goto done;
    }
    ok = true;
done:
    if (descriptor >= 0) {
        (void)close(descriptor);
    }
    return ok;
}

static int open_source_file(int parent, const char *name,
                            const struct stable_stat *expected,
                            struct error_state *error)
{
    int descriptor = openat(parent, name,
                            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat status;
    struct stable_stat stable;
    if (descriptor < 0 || fstat(descriptor, &status) != 0 ||
        !S_ISREG(status.st_mode)) {
        if (descriptor >= 0) {
            (void)close(descriptor);
        }
        set_repository_error(error, "object-changed");
        return -1;
    }
    stable_from_stat(&status, &stable);
    if (!stable_equal(expected, &stable)) {
        (void)close(descriptor);
        set_repository_error(error, "object-changed");
        return -1;
    }
    return descriptor;
}

static bool copy_open_source(int source, const struct stable_stat *expected,
                             int destination_parent, const char *name,
                             struct error_state *error)
{
    int destination = openat(destination_parent, name,
                             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
                                 O_CLOEXEC,
                             0600);
    unsigned char buffer[65536];
    unsigned char extra;
    struct sha256_state hash;
    unsigned char digest[32];
    bool ok = false;
    off_t offset = 0;

    if (destination < 0) {
        set_repository_error(error, "publish");
        return false;
    }
    sha256_init(&hash);
    while (offset < expected->size) {
        size_t wanted = (uint64_t)(expected->size - offset) > sizeof(buffer)
                            ? sizeof(buffer)
                            : (size_t)(expected->size - offset);
        ssize_t count = pread(source, buffer, wanted, offset);
        if (count <= 0 || !write_all(destination, buffer, (size_t)count)) {
            set_repository_error(error, "object-changed");
            goto done;
        }
        sha256_update(&hash, buffer, (size_t)count);
        offset += count;
    }
    if (pread(source, &extra, 1U, expected->size) != 0 ||
        fchmod(destination, 0400) != 0) {
        set_repository_error(error, "object-changed");
        goto done;
    }
    sha256_final(&hash, digest);
    (void)digest[0];
    ok = true;
done:
    (void)close(destination);
    return ok;
}

static bool copy_loose_objects(const struct repository_layout *layout,
                               const struct object_inventory *inventory,
                               int destination_objects,
                               struct error_state *error)
{
    size_t index = 0U;
    while (index < inventory->copies.len &&
           inventory->copies.items[index].kind == OBJECT_LOOSE) {
        const char *fanout = inventory->copies.items[index].directory;
        unsigned slot = hex_byte(fanout);
        int source_directory = open_directory_component(layout->objects_fd, fanout);
        int destination_directory;
        if (source_directory < 0 ||
            !stat_fd_stable(source_directory,
                            &inventory->loose_dirs[slot].source)) {
            if (source_directory >= 0) {
                (void)close(source_directory);
            }
            set_repository_error(error, "object-changed");
            return false;
        }
        destination_directory = make_directory_at(destination_objects, fanout,
                                                  error);
        if (destination_directory < 0) {
            (void)close(source_directory);
            return false;
        }
        while (index < inventory->copies.len &&
               inventory->copies.items[index].kind == OBJECT_LOOSE &&
               strcmp(inventory->copies.items[index].directory, fanout) == 0) {
            const struct object_item *item = &inventory->copies.items[index];
            int source = open_source_file(source_directory, item->name,
                                          &item->source, error);
            if (source < 0 ||
                !copy_open_source(source, &item->source, destination_directory,
                                  item->name, error) ||
                !stat_fd_stable(source, &item->source)) {
                if (source >= 0) {
                    (void)close(source);
                }
                (void)close(destination_directory);
                (void)close(source_directory);
                if (error->kind == ERROR_NONE) {
                    set_repository_error(error, "object-changed");
                }
                return false;
            }
            (void)close(source);
            index++;
        }
        if (!stat_fd_stable(source_directory,
                            &inventory->loose_dirs[slot].source)) {
            set_repository_error(error, "object-changed");
            (void)close(destination_directory);
            (void)close(source_directory);
            return false;
        }
        (void)close(destination_directory);
        (void)close(source_directory);
    }
    return true;
}

static bool copy_pack_objects(const struct repository_layout *layout,
                              const struct object_inventory *inventory,
                              int destination_objects,
                              struct error_state *error)
{
    size_t index = 0U;
    int source_pack;
    int destination_pack;
    while (index < inventory->copies.len &&
           inventory->copies.items[index].kind == OBJECT_LOOSE) {
        index++;
    }
    if (index == inventory->copies.len) {
        return true;
    }
    source_pack = open_directory_component(layout->objects_fd, "pack");
    if (source_pack < 0 ||
        !stat_fd_stable(source_pack, &inventory->pack_source)) {
        if (source_pack >= 0) {
            (void)close(source_pack);
        }
        set_repository_error(error, "object-changed");
        return false;
    }
    destination_pack = make_directory_at(destination_objects, "pack", error);
    if (destination_pack < 0) {
        (void)close(source_pack);
        return false;
    }
    while (index < inventory->copies.len) {
        const struct object_item *first = &inventory->copies.items[index];
        const struct object_item *second = &inventory->copies.items[index + 1U];
        int first_fd = open_source_file(source_pack, first->name, &first->source,
                                        error);
        int second_fd = open_source_file(source_pack, second->name, &second->source,
                                         error);
        if (first_fd < 0 || second_fd < 0 ||
            !copy_open_source(first_fd, &first->source, destination_pack,
                              first->name, error) ||
            !copy_open_source(second_fd, &second->source, destination_pack,
                              second->name, error) ||
            !stat_fd_stable(first_fd, &first->source) ||
            !stat_fd_stable(second_fd, &second->source)) {
            close_if_open(&first_fd);
            close_if_open(&second_fd);
            (void)close(destination_pack);
            (void)close(source_pack);
            if (error->kind == ERROR_NONE) {
                set_repository_error(error, "object-changed");
            }
            return false;
        }
        (void)close(first_fd);
        (void)close(second_fd);
        index += 2U;
    }
    if (!stat_fd_stable(source_pack, &inventory->pack_source)) {
        set_repository_error(error, "object-changed");
        (void)close(destination_pack);
        (void)close(source_pack);
        return false;
    }
    (void)close(destination_pack);
    (void)close(source_pack);
    return true;
}

static bool publish_snapshot(const struct repository_layout *layout,
                             const struct object_inventory *inventory,
                             struct destination_context *destination,
                             struct error_state *error)
{
    static const unsigned char head[] =
        "ref: refs/heads/__ystack_unborn__\n";
    static const unsigned char sha1_config[] =
        "[core]\n"
        "\trepositoryformatversion = 0\n"
        "\tbare = true\n"
        "\tmultiPackIndex = false\n"
        "\tcommitGraph = false\n"
        "\tuseReplaceRefs = false\n";
    static const unsigned char sha256_config[] =
        "[core]\n"
        "\trepositoryformatversion = 1\n"
        "\tbare = true\n"
        "\tmultiPackIndex = false\n"
        "\tcommitGraph = false\n"
        "\tuseReplaceRefs = false\n"
        "[extensions]\n"
        "\tobjectFormat = sha256\n";
    const unsigned char *config = strcmp(layout->algorithm, "sha256") == 0
                                      ? sha256_config
                                      : sha1_config;
    size_t config_length = strcmp(layout->algorithm, "sha256") == 0
                               ? sizeof(sha256_config) - 1U
                               : sizeof(sha1_config) - 1U;
    int admin = -1;
    int objects = -1;
    int objects_info = -1;
    int refs = -1;
    int heads = -1;
    int tags = -1;
    int info = -1;
    bool ok = false;

    admin = make_directory_at(destination->stage_fd, "admin", error);
    objects = make_directory_at(destination->stage_fd, "objects", error);
    refs = make_directory_at(destination->stage_fd, "refs", error);
    info = make_directory_at(destination->stage_fd, "info", error);
    if (admin < 0 || objects < 0 || refs < 0 || info < 0) {
        goto done;
    }
    heads = make_directory_at(refs, "heads", error);
    tags = make_directory_at(refs, "tags", error);
    objects_info = make_directory_at(objects, "info", error);
    if (heads < 0 || tags < 0 || objects_info < 0 ||
        !write_private_file(destination->stage_fd, "config", config,
                            config_length, error) ||
        !write_private_file(destination->stage_fd, "HEAD", head,
                            sizeof(head) - 1U, error) ||
        !write_private_file(admin, "common-config", layout->common_config.data,
                            layout->common_config.len, error) ||
        (layout->has_worktree_config &&
         !write_private_file(admin, "worktree-config",
                             layout->worktree_config.data,
                             layout->worktree_config.len, error)) ||
        !copy_loose_objects(layout, inventory, objects, error) ||
        !copy_pack_objects(layout, inventory, objects, error) ||
        !stat_fd_stable(layout->objects_fd, &inventory->objects_source)) {
        if (error->kind == ERROR_NONE) {
            set_repository_error(error, "object-changed");
        }
        goto done;
    }
    if (renameat(destination->slot_fd, STAGE_NAME, destination->slot_fd,
                 REPOSITORY_NAME) != 0) {
        set_repository_error(error, "publish");
        goto done;
    }
    destination->stage_exists = false;
    ok = true;
done:
    close_if_open(&objects_info);
    close_if_open(&info);
    close_if_open(&tags);
    close_if_open(&heads);
    close_if_open(&refs);
    close_if_open(&objects);
    close_if_open(&admin);
    return ok;
}

static void repository_identity(const struct repository_layout *layout,
                                char output[65])
{
    char material[256];
    unsigned char digest[32];
    struct sha256_state hash;
    int length = snprintf(material, sizeof(material),
                          "ystack-repository-v1:%ju:%ju:%ju:%ju",
                          (uintmax_t)layout->common_stat.dev,
                          (uintmax_t)layout->common_stat.ino,
                          (uintmax_t)layout->objects_stat.dev,
                          (uintmax_t)layout->objects_stat.ino);
    sha256_init(&hash);
    sha256_update(&hash, (const unsigned char *)material, (size_t)length);
    sha256_final(&hash, digest);
    hex_digest(digest, output);
}

int main(int argc, char **argv)
{
    static const uint64_t maxima[5] = {
        ADMIN_TOTAL_MAX, OBJECT_TOTAL_MAX, OBJECT_ENTRY_MAX,
        OBJECT_NAME_MAX, GLOBAL_TOTAL_MAX
    };
    struct error_state error = {0};
    struct budget budget = {0};
    struct repository_layout layout;
    struct object_inventory inventory;
    struct destination_context destination;
    uint64_t limits[5];
    char identity[65];
    const char *generated_config;
    size_t generated_size;
    bool success = false;

    layout_init(&layout);
    memset(&inventory, 0, sizeof(inventory));
    destination_init(&destination);
    (void)umask(0077);

    if (argc != 9 || strcmp(argv[1], "snapshot-repository") != 0 ||
        !valid_absolute_input_path(argv[2]) ||
        !valid_absolute_input_path(argv[3])) {
        set_repository_error(&error, "invocation");
        goto done;
    }
    for (size_t index = 0U; index < 5U; index++) {
        if (!parse_limit(argv[index + 4U], maxima[index], &limits[index])) {
            set_repository_error(&error, "invocation");
            goto done;
        }
    }
    budget.admin_limit = limits[0];
    budget.object_limit = limits[1];
    budget.entry_limit = limits[2];
    budget.name_limit = limits[3];
    budget.global_limit = limits[4];

    if (!resolve_repository_layout(argv[2], &layout, &budget, &error) ||
        !inventory_objects(&layout, &inventory, &budget, &error)) {
        goto done;
    }
    generated_config = strcmp(layout.algorithm, "sha256") == 0
                           ? "[core]\n\trepositoryformatversion = 1\n\tbare = true\n\tmultiPackIndex = false\n\tcommitGraph = false\n\tuseReplaceRefs = false\n[extensions]\n\tobjectFormat = sha256\n"
                           : "[core]\n\trepositoryformatversion = 0\n\tbare = true\n\tmultiPackIndex = false\n\tcommitGraph = false\n\tuseReplaceRefs = false\n";
    generated_size = strlen(generated_config) +
                     strlen("ref: refs/heads/__ystack_unborn__\n");
    if (!charge_admin(&budget, (uint64_t)generated_size, &error) ||
        !prepare_destination(argv[3], &layout, &destination, &error) ||
        !publish_snapshot(&layout, &inventory, &destination, &error)) {
        goto done;
    }
    repository_identity(&layout, identity);
    if (printf("ok\t%s\t%s\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64
               "\t%" PRIu64 "\t%" PRIu64 "\n",
               layout.algorithm, identity, budget.admin_used,
               budget.object_used, budget.entries_used, budget.names_used,
               budget.global_used) < 0) {
        set_repository_error(&error, "io");
        goto done;
    }
    success = true;

done:
    destination_close(&destination, success);
    free(inventory.copies.items);
    layout_close(&layout);
    if (!success) {
        const char *kind = error.kind == ERROR_LIMIT ? "E_LIMIT" : "E_REPOSITORY";
        const char *reason = error.reason == NULL ? "unexpected" : error.reason;
        (void)fprintf(stderr, "%s %s\n", kind, reason);
        return 2;
    }
    return 0;
}
