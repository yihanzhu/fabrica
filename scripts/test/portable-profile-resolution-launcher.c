#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

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

int main(int argc, char **argv) {
    char *child_argv[6];
    char *child_env[9];
    char home[PATH_MAX];
    char temp[PATH_MAX];
    char tool_path[PATH_MAX];
    char path_value[PATH_MAX + 32];
    char *slash;
    const char *sandbox;

    if (argc == 2 && strcmp(argv[1], "trap-child") == 0) {
        return 0;
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

    if (argc != 7 || strcmp(argv[1], "resolve") != 0 ||
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

    if (set_limit(RLIMIT_CPU, 300) != 0 ||
#if !defined(__APPLE__)
        set_limit(RLIMIT_AS, 536870912) != 0 ||
#endif
        set_limit(RLIMIT_FSIZE, 67108864) != 0 ||
        set_limit(RLIMIT_NOFILE, 64) != 0) {
        fputs("E_LIMIT process-limit\n", stderr);
        return 75;
    }
#if defined(RLIMIT_NPROC) && !defined(__APPLE__)
    if (set_limit(RLIMIT_NPROC, 32) != 0) {
        fputs("E_LIMIT process-limit\n", stderr);
        return 75;
    }
#endif

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
    execve("/bin/bash", child_argv, child_env);
    (void)errno;
    fputs("E_RUNTIME unexpected\n", stderr);
    return 70;
}
