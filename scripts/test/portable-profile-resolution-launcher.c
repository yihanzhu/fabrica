#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <dirent.h>
#elif defined(__APPLE__)
#include <libproc.h>
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define PROCESS_LIMIT 32U
#define INVOCATION_SECONDS 300
#define ERROR_BYTES_MAX 256U

enum stop_reason {
    STOP_NONE = 0,
    STOP_PROCESS,
    STOP_TIME
};

static int set_limit(int resource, rlim_t value) {
    struct rlimit limit = {value, value};
    return setrlimit(resource, &limit);
}

static int regular_absolute(const char *path, int executable) {
    struct stat state;
    if (path == NULL || path[0] != '/' || lstat(path, &state) != 0 ||
        !S_ISREG(state.st_mode) || S_ISLNK(state.st_mode)) {
        return 0;
    }
    return !executable || access(path, X_OK) == 0;
}

static char *environment_value(const char *name, const char *value) {
    size_t size = strlen(name) + strlen(value) + 2;
    char *entry = malloc(size);
    if (entry == NULL || snprintf(entry, size, "%s=%s", name, value) < 0) {
        free(entry);
        return NULL;
    }
    return entry;
}

static int write_all(int descriptor, const char *bytes, size_t length) {
    size_t offset = 0U;
    while (offset < length) {
        ssize_t written = write(descriptor, bytes + offset, length - offset);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return -1;
        }
        offset += (size_t)written;
    }
    return 0;
}

static int stream_file(const char *path, int output) {
    char buffer[16384];
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat state;
    if (descriptor < 0 || fstat(descriptor, &state) != 0 ||
        !S_ISREG(state.st_mode)) {
        if (descriptor >= 0) {
            (void)close(descriptor);
        }
        return -1;
    }
    for (;;) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0 ||
            (count > 0 && write_all(output, buffer, (size_t)count) != 0)) {
            (void)close(descriptor);
            return -1;
        }
        if (count == 0) {
            break;
        }
    }
    return close(descriptor);
}

static int empty_regular_file(const char *path) {
    struct stat state;
    return lstat(path, &state) == 0 && S_ISREG(state.st_mode) &&
           !S_ISLNK(state.st_mode) && state.st_size == 0;
}

static int sanitized_error(const char *path) {
    char bytes[ERROR_BYTES_MAX + 1U];
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    ssize_t count;
    char *space;
    if (descriptor < 0) {
        return 0;
    }
    count = read(descriptor, bytes, ERROR_BYTES_MAX + 1U);
    (void)close(descriptor);
    if (count <= 0 || count > (ssize_t)ERROR_BYTES_MAX ||
        bytes[count - 1] != '\n') {
        return 0;
    }
    bytes[count] = '\0';
    if (strchr(bytes, '\n') != bytes + count - 1) {
        return 0;
    }
    space = strchr(bytes, ' ');
    if (space != NULL) {
        *space = '\0';
    } else {
        bytes[count - 1] = '\0';
    }
    if (strcmp(bytes, "E_USAGE") != 0 && strcmp(bytes, "E_INPUT") != 0 &&
        strcmp(bytes, "E_RUNTIME") != 0 && strcmp(bytes, "E_PARSE") != 0 &&
        strcmp(bytes, "E_CANONICAL") != 0 && strcmp(bytes, "E_LIMIT") != 0 &&
        strcmp(bytes, "E_SHAPE") != 0 && strcmp(bytes, "E_REF") != 0 &&
        strcmp(bytes, "E_RELATION") != 0 && strcmp(bytes, "E_REPOSITORY") != 0 &&
        strcmp(bytes, "E_OBJECT") != 0) {
        return 0;
    }
    if (space != NULL) {
        *space = ' ';
    } else {
        bytes[count - 1] = '\n';
    }
    for (ssize_t index = 0; index < count - 1; index++) {
        unsigned char character = (unsigned char)bytes[index];
        if (!(character == ' ' || character == '-' || character == '_' ||
              (character >= '0' && character <= '9') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= 'a' && character <= 'z'))) {
            return 0;
        }
    }
    return write_all(STDERR_FILENO, bytes, (size_t)count) == 0;
}

static int monotonic_seconds(time_t *seconds) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    *seconds = now.tv_sec;
    return 0;
}

#if defined(__linux__)
static unsigned process_group_count(pid_t group) {
    DIR *directory = opendir("/proc");
    struct dirent *entry;
    unsigned count = 0U;
    if (directory == NULL) {
        return PROCESS_LIMIT + 1U;
    }
    for (;;) {
        char path[64];
        char line[4096];
        char *end;
        FILE *stream;
        long observed_group;
        char state;
        long parent;
        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                count = PROCESS_LIMIT + 1U;
            }
            break;
        }
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9' ||
            strlen(entry->d_name) > 20U) {
            continue;
        }
        int path_length = snprintf(path, sizeof(path), "/proc/%s/stat", entry->d_name);
        if (path_length < 0 || (size_t)path_length >= sizeof(path)) {
            count = PROCESS_LIMIT + 1U;
            break;
        }
        stream = fopen(path, "r");
        if (stream == NULL) {
            continue;
        }
        if (fgets(line, sizeof(line), stream) == NULL) {
            (void)fclose(stream);
            continue;
        }
        (void)fclose(stream);
        end = strrchr(line, ')');
        if (end == NULL || sscanf(end + 1, " %c %ld %ld", &state, &parent,
                                  &observed_group) != 3) {
            continue;
        }
        (void)state;
        (void)parent;
        if ((pid_t)observed_group == group) {
            count++;
        }
    }
    (void)closedir(directory);
    return count;
}
#elif defined(__APPLE__)
static unsigned process_group_count(pid_t group) {
    for (unsigned attempt = 0U; attempt < 3U; attempt++) {
        int estimated = proc_listallpids(NULL, 0);
        pid_t *processes;
        int observed;
        unsigned count = 0U;
        if (estimated <= 0 || estimated > 1048576) {
            return PROCESS_LIMIT + 1U;
        }
        estimated += 64;
        processes = calloc((size_t)estimated, sizeof(*processes));
        if (processes == NULL) {
            return PROCESS_LIMIT + 1U;
        }
        observed = proc_listallpids(processes,
                                   estimated * (int)sizeof(*processes));
        if (observed < 0) {
            free(processes);
            return PROCESS_LIMIT + 1U;
        }
        if (observed < estimated) {
            for (int index = 0; index < observed; index++) {
                if (processes[index] > 0 && getpgid(processes[index]) == group) {
                    count++;
                }
            }
            free(processes);
            return count;
        }
        free(processes);
    }
    return PROCESS_LIMIT + 1U;
}
#else
static unsigned process_group_count(pid_t group) {
    (void)group;
    return PROCESS_LIMIT + 1U;
}
#endif

static int apply_child_limits(void) {
    if (set_limit(RLIMIT_CPU, 300) != 0 ||
#if !defined(__APPLE__)
        set_limit(RLIMIT_AS, 536870912) != 0 ||
#endif
        set_limit(RLIMIT_FSIZE, 67108864) != 0 ||
        set_limit(RLIMIT_NOFILE, 64) != 0) {
        return -1;
    }
    return 0;
}

static int supervise(const char *program, char *const child_argv[],
                     char *const child_env[], const char *sandbox) {
    char stdout_path[PATH_MAX];
    char stderr_path[PATH_MAX];
    int stdout_fd = -1;
    int stderr_fd = -1;
    pid_t child;
    int status = 0;
    enum stop_reason stopped = STOP_NONE;
    time_t started;
    struct timespec interval = {0, 10000000L};

    if (snprintf(stdout_path, sizeof(stdout_path), "%s/child.stdout", sandbox) < 0 ||
        snprintf(stderr_path, sizeof(stderr_path), "%s/child.stderr", sandbox) < 0) {
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    stdout_fd = open(stdout_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                     0600);
    stderr_fd = open(stderr_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                     0600);
    if (stdout_fd < 0 || stderr_fd < 0 || monotonic_seconds(&started) != 0) {
        if (stdout_fd >= 0) {
            (void)close(stdout_fd);
        }
        if (stderr_fd >= 0) {
            (void)close(stderr_fd);
        }
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    child = fork();
    if (child < 0) {
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    if (child == 0) {
        if (setpgid(0, 0) != 0 || dup2(stdout_fd, STDOUT_FILENO) < 0 ||
            dup2(stderr_fd, STDERR_FILENO) < 0 || close(stdout_fd) != 0 ||
            close(stderr_fd) != 0 || apply_child_limits() != 0) {
            _exit(75);
        }
        execve(program, child_argv, child_env);
        _exit(70);
    }
    (void)close(stdout_fd);
    (void)close(stderr_fd);
    if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) {
        (void)kill(child, SIGKILL);
        (void)waitpid(child, &status, 0);
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    for (;;) {
        pid_t observed = waitpid(child, &status, WNOHANG);
        time_t now;
        if (observed == child) {
            if (process_group_count(child) > 0U) {
                stopped = STOP_PROCESS;
            }
            break;
        }
        if (observed < 0 && errno != EINTR) {
            stopped = STOP_PROCESS;
            break;
        }
        if (process_group_count(child) > PROCESS_LIMIT) {
            stopped = STOP_PROCESS;
            break;
        }
        if (monotonic_seconds(&now) != 0 || now - started >= INVOCATION_SECONDS) {
            stopped = STOP_TIME;
            break;
        }
        (void)nanosleep(&interval, NULL);
    }
    if (stopped != STOP_NONE) {
        (void)kill(-child, SIGKILL);
        (void)kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        }
        if (stopped == STOP_TIME) {
            fputs("E_LIMIT time-limit\n", stderr);
        } else {
            fputs("E_LIMIT process-limit\n", stderr);
        }
        return 75;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
        empty_regular_file(stderr_path)) {
        if (stream_file(stdout_path, STDOUT_FILENO) != 0) {
            fputs("E_RUNTIME unexpected\n", stderr);
            return 70;
        }
        return 0;
    }
    if (WIFSIGNALED(status) &&
        (WTERMSIG(status) == SIGXCPU || WTERMSIG(status) == SIGXFSZ ||
         WTERMSIG(status) == SIGKILL)) {
        fputs("E_LIMIT resource-limit\n", stderr);
        return 75;
    }
    if (empty_regular_file(stdout_path) && sanitized_error(stderr_path)) {
        return WIFEXITED(status) ? WEXITSTATUS(status) : 75;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 75 &&
        empty_regular_file(stderr_path)) {
        fputs("E_LIMIT resource-limit\n", stderr);
        return 75;
    }
    if (!empty_regular_file(stdout_path)) {
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    fputs("E_RUNTIME unexpected\n", stderr);
    return 70;
}

int main(int argc, char **argv) {
    char *child_argv[6];
    char *child_env[9];
    char home[PATH_MAX];
    char temp[PATH_MAX];
    char tool_path[PATH_MAX];
    char path_value[PATH_MAX + 32];
    char *slash;
    const char *sandbox;
    int remove_helper = 0;

    if (argc == 2 && strcmp(argv[1], "trap-child") == 0) {
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "limit-child") == 0) {
        if (strcmp(argv[2], "process") == 0) {
            for (unsigned index = 0U; index < PROCESS_LIMIT + 8U; index++) {
                pid_t worker = fork();
                if (worker < 0) {
                    return 75;
                }
                if (worker == 0) {
                    for (;;) {
                        (void)pause();
                    }
                }
            }
            for (;;) {
                (void)pause();
            }
        }
        if (strcmp(argv[2], "file") == 0) {
            static char block[1048576];
            for (unsigned index = 0U; index < 68U; index++) {
                if (write_all(STDOUT_FILENO, block, sizeof(block)) != 0) {
                    return 75;
                }
            }
            return 0;
        }
        if (strcmp(argv[2], "silent") == 0) {
            return 71;
        }
        return 64;
    }
    if (argc == 4 && strcmp(argv[1], "limit-control") == 0 &&
        regular_absolute(argv[0], 1) && argv[3][0] == '/') {
        char *control_argv[] = {argv[0], "limit-child", argv[2], NULL};
        char *control_env[] = {"LC_ALL=C", NULL};
        return supervise(argv[0], control_argv, control_env, argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "loader-control") == 0 &&
        regular_absolute(argv[2], 0) && argv[3][0] == '/') {
        char *control_argv[] = {argv[0], "trap-child", NULL};
        char *control_env[5];
#if defined(__APPLE__)
        control_env[0] = environment_value("DYLD_INSERT_LIBRARIES", argv[2]);
        control_env[1] = strdup("DYLD_FORCE_FLAT_NAMESPACE=1");
#else
        control_env[0] = environment_value("LD_PRELOAD", argv[2]);
        control_env[1] = strdup("LD_BIND_NOW=1");
#endif
        control_env[2] = environment_value("YSTACK_TRAP_MARKER", argv[3]);
        control_env[3] = strdup("LC_ALL=C");
        control_env[4] = NULL;
        if (control_env[0] == NULL || control_env[1] == NULL ||
            control_env[2] == NULL || control_env[3] == NULL) {
            return 70;
        }
        execve(argv[0], control_argv, control_env);
        return 70;
    }

    if (argc == 7 && strcmp(argv[1], "resolve-missing-helper") == 0) {
        remove_helper = 1;
    }
    if (argc != 7 ||
        (strcmp(argv[1], "resolve") != 0 && remove_helper == 0) ||
        !regular_absolute(argv[2], 0) || !regular_absolute(argv[3], 1) ||
        !regular_absolute(argv[4], 1) || argv[5][0] != '/' || argv[6][0] != '/') {
        fputs("E_USAGE\n", stderr);
        return 64;
    }
    sandbox = getenv("YSTACK_TEST_SANDBOX");
    if (sandbox == NULL || sandbox[0] != '/' || strlen(sandbox) > PATH_MAX - 16) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    if (snprintf(home, sizeof(home), "%s/home", sandbox) < 0 ||
        snprintf(temp, sizeof(temp), "%s/tmp", sandbox) < 0 ||
        mkdir(home, 0700) != 0 || mkdir(temp, 0700) != 0) {
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }

    child_argv[0] = "/bin/bash";
    child_argv[1] = argv[2];
    child_argv[2] = "resolve";
    child_argv[3] = argv[5];
    child_argv[4] = argv[6];
    child_argv[5] = NULL;

    child_env[0] = environment_value("HOME", home);
    child_env[1] = environment_value("TMPDIR", temp);
    child_env[2] = strdup("LC_ALL=C");
    if (strlen(argv[4]) >= sizeof(tool_path)) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    strcpy(tool_path, argv[4]);
    slash = strrchr(tool_path, '/');
    if (slash == NULL || slash == tool_path) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    *slash = '\0';
    if (snprintf(path_value, sizeof(path_value), "%s:/usr/bin:/bin", tool_path) < 0) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    child_env[3] = environment_value("PATH", path_value);
    child_env[4] = strdup("YSTACK_RESOLVER_TRUSTED=1");
    child_env[5] = environment_value("YSTACK_RESOLVER_HELPER", argv[3]);
    child_env[6] = environment_value("YSTACK_RESOLVER_JQ", argv[4]);
    child_env[7] = strdup("GIT_TERMINAL_PROMPT=0");
    child_env[8] = NULL;
    for (size_t index = 0; index < 8; index++) {
        if (child_env[index] == NULL) {
            fputs("E_RUNTIME unexpected\n", stderr);
            return 70;
        }
    }
    if (remove_helper != 0 && unlink(argv[3]) != 0) {
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    return supervise("/bin/bash", child_argv, child_env, sandbox);
}
