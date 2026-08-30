#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void profile_resolution_loader_marker(void) {
    const char *path = getenv("YSTACK_TRAP_MARKER");
    if (path != NULL && path[0] == '/') {
        int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (descriptor >= 0) {
            static const char marker[] = "loaded\n";
            (void)write(descriptor, marker, sizeof(marker) - 1U);
            (void)close(descriptor);
        }
    }
}
