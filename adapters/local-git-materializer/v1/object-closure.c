#define _POSIX_C_SOURCE 200809L

/* Private exception boundary: https://github.com/yihanzhu/ystack/pull/229#issuecomment-5539240046 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define OBJECT_MAX 65536U
#define BYTE_MAX 268435456ULL
#define COMMIT_MAX 1048576ULL
#define TREE_MAX 16777216ULL
#define TABLE_SIZE 131071U

struct item { char oid[65]; };
struct set_slot { char oid[65]; int used; };

static void fail(const char *code)
{
    (void)fprintf(stderr, "%s\n", code);
    exit(1);
}

static void cap_limit(int resource, rlim_t ceiling)
{
    struct rlimit limit;
    if (getrlimit(resource, &limit) != 0) _exit(126);
    if (limit.rlim_cur > ceiling) limit.rlim_cur = ceiling;
    if (limit.rlim_max > ceiling) limit.rlim_max = ceiling;
    if (setrlimit(resource, &limit) != 0) _exit(126);
}

static void limit_child(void)
{
    cap_limit(RLIMIT_CPU, 120U);
#if !defined(__APPLE__)
    cap_limit(RLIMIT_DATA, 536870912U);
#if defined(RLIMIT_AS)
    cap_limit(RLIMIT_AS, 536870912U);
#endif
#endif
}

static uint64_t hash_oid(const char *value)
{
    uint64_t hash = 1469598103934665603ULL;
    while (*value != '\0') {
        hash ^= (unsigned char)*value++;
        hash *= 1099511628211ULL;
    }
    return hash;
}

static int valid_oid(const char *value, size_t length)
{
    size_t index;
    if (strlen(value) != length) return 0;
    for (index = 0; index < length; index++) {
        if (!((value[index] >= '0' && value[index] <= '9') ||
              (value[index] >= 'a' && value[index] <= 'f'))) return 0;
    }
    return 1;
}

static int remember(struct set_slot *set, const char *oid)
{
    size_t slot = (size_t)(hash_oid(oid) % TABLE_SIZE);
    size_t start = slot;
    do {
        if (!set[slot].used) {
            set[slot].used = 1;
            (void)strcpy(set[slot].oid, oid);
            return 1;
        }
        if (strcmp(set[slot].oid, oid) == 0) return 0;
        slot = (slot + 1U) % TABLE_SIZE;
    } while (slot != start);
    fail("E_SOURCE_LIMIT");
    return 0;
}

static void enqueue(struct item *queue, size_t *length, struct set_slot *set,
                    const char *oid, size_t oid_length)
{
    if (!valid_oid(oid, oid_length)) fail("E_SOURCE_GIT");
    if (!remember(set, oid)) return;
    if (*length >= OBJECT_MAX) fail("E_SOURCE_LIMIT");
    (void)strcpy(queue[*length].oid, oid);
    *length += 1U;
}

static void command(FILE *input, const char *name, const char *oid)
{
    if (fprintf(input, "%s %s\nflush\n", name, oid) < 0 || fflush(input) != 0)
        fail("E_SOURCE_GIT");
}

static void read_header(FILE *output, const char *expected, char *type,
                        unsigned long long *size)
{
    char *line = NULL;
    size_t capacity = 0U;
    char oid[65];
    char extra;
    ssize_t length = getline(&line, &capacity, output);
    if (length <= 0 || (size_t)length > 160U ||
        sscanf(line, "%64s %15s %llu %c", oid, type, size, &extra) != 3 ||
        strcmp(oid, expected) != 0) {
        free(line);
        fail("E_SOURCE_GIT");
    }
    free(line);
}

static unsigned char *read_contents(FILE *input, FILE *output, const char *oid,
                                    const char *expected_type,
                                    unsigned long long expected_size)
{
    char type[16];
    unsigned long long size;
    unsigned char *body;
    command(input, "contents", oid);
    read_header(output, oid, type, &size);
    if (strcmp(type, expected_type) != 0 || size != expected_size || size > SIZE_MAX)
        fail("E_SOURCE_GIT");
    body = malloc((size_t)size + 1U);
    if (body == NULL) fail("E_SOURCE_LIMIT");
    if (fread(body, 1U, (size_t)size, output) != (size_t)size || fgetc(output) != '\n') {
        free(body);
        fail("E_SOURCE_GIT");
    }
    body[size] = '\0';
    return body;
}

static void parse_commit(unsigned char *body, size_t size, struct item *queue,
                         size_t *length, struct set_slot *set, size_t oid_length)
{
    char *cursor = (char *)body;
    char *end = (char *)body + size;
    int tree_seen = 0;
    while (cursor < end) {
        char *newline = memchr(cursor, '\n', (size_t)(end - cursor));
        size_t line_length;
        if (newline == NULL) fail("E_SOURCE_GIT");
        line_length = (size_t)(newline - cursor);
        if (line_length == 0U) break;
        if (line_length == oid_length + 5U && memcmp(cursor, "tree ", 5U) == 0) {
            char oid[65];
            if (tree_seen) fail("E_SOURCE_GIT");
            (void)memcpy(oid, cursor + 5, oid_length); oid[oid_length] = '\0';
            enqueue(queue, length, set, oid, oid_length); tree_seen = 1;
        } else if (line_length == oid_length + 7U && memcmp(cursor, "parent ", 7U) == 0) {
            char oid[65];
            (void)memcpy(oid, cursor + 7, oid_length); oid[oid_length] = '\0';
            enqueue(queue, length, set, oid, oid_length);
        }
        cursor = newline + 1;
    }
    if (!tree_seen) fail("E_SOURCE_GIT");
}

static void parse_tree(unsigned char *body, size_t size, struct item *queue,
                       size_t *length, struct set_slot *set, size_t oid_length)
{
    size_t cursor = 0U;
    while (cursor < size) {
        size_t mode_start = cursor;
        size_t mode_length;
        size_t name_start;
        char oid[65];
        while (cursor < size && body[cursor] != ' ') cursor++;
        if (cursor == size || cursor == mode_start) fail("E_SOURCE_GIT");
        mode_length = cursor - mode_start;
        name_start = ++cursor;
        while (cursor < size && body[cursor] != '\0') cursor++;
        if (cursor == size || cursor == name_start) fail("E_SOURCE_GIT");
        cursor++;
        if (size - cursor < oid_length) fail("E_SOURCE_GIT");
        if (!(mode_length == 6U && memcmp(body + mode_start, "160000", 6U) == 0)) {
            size_t index;
            for (index = 0; index < oid_length; index++)
                (void)sprintf(oid + index * 2U, "%02x", body[cursor + index]);
            oid[oid_length * 2U] = '\0';
            enqueue(queue, length, set, oid, oid_length * 2U);
        }
        cursor += oid_length;
    }
}

int main(int argc, char **argv)
{
    int to_child[2], from_child[2], output_fd;
    pid_t child;
    FILE *input, *output;
    struct item *queue;
    struct set_slot *set;
    size_t length = 0U, cursor = 0U, oid_text_length, oid_raw_length;
    unsigned long long total = 0U;
    int status;
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        (void)puts("ystack-object-closure-v1");
        return 0;
    }
    if (argc != 6 || strcmp(argv[1], "walk") != 0) fail("E_USAGE");
    if (strcmp(argv[3], "sha1") == 0) { oid_text_length = 40U; oid_raw_length = 20U; }
    else if (strcmp(argv[3], "sha256") == 0) { oid_text_length = 64U; oid_raw_length = 32U; }
    else fail("E_USAGE");
    queue = calloc(OBJECT_MAX, sizeof(*queue)); set = calloc(TABLE_SIZE, sizeof(*set));
    if (queue == NULL || set == NULL) fail("E_SOURCE_LIMIT");
    output_fd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (output_fd < 0 || pipe(to_child) != 0 || pipe(from_child) != 0) fail("E_SOURCE_GIT");
    child = fork();
    if (child < 0) fail("E_SOURCE_GIT");
    if (child == 0) {
        limit_child();
        (void)dup2(to_child[0], STDIN_FILENO); (void)dup2(from_child[1], STDOUT_FILENO);
        close(to_child[1]); close(from_child[0]);
        execl("/usr/bin/git", "/usr/bin/git", "--no-replace-objects", "--git-dir", argv[2],
              "cat-file", "--batch-command", "--buffer", (char *)NULL);
        _exit(127);
    }
    close(to_child[0]); close(from_child[1]);
    input = fdopen(to_child[1], "w"); output = fdopen(from_child[0], "r");
    if (input == NULL || output == NULL) fail("E_SOURCE_GIT");
    enqueue(queue, &length, set, argv[4], oid_text_length);
    while (cursor < length) {
        char type[16]; unsigned long long size; unsigned char *body = NULL;
        const char *oid = queue[cursor++].oid;
        command(input, "info", oid); read_header(output, oid, type, &size);
        if (size > BYTE_MAX - total) fail("E_SOURCE_LIMIT");
        total += size;
        if (strcmp(type, "commit") == 0) {
            if (size > COMMIT_MAX) fail("E_SOURCE_LIMIT");
            body = read_contents(input, output, oid, type, size);
            parse_commit(body, (size_t)size, queue, &length, set, oid_text_length);
        } else if (strcmp(type, "tree") == 0) {
            if (size > TREE_MAX) fail("E_SOURCE_LIMIT");
            body = read_contents(input, output, oid, type, size);
            parse_tree(body, (size_t)size, queue, &length, set, oid_raw_length);
        } else if (strcmp(type, "blob") != 0) fail("E_SOURCE_GIT");
        free(body);
        if (dprintf(output_fd, "%s\n", oid) < 0) fail("E_SOURCE_GIT");
    }
    (void)fclose(input); (void)fclose(output); (void)close(output_fd);
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        fail("E_SOURCE_GIT");
    free(queue); free(set); return 0;
}
