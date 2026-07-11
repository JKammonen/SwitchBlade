#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s STAGED_PATH DESTINATION_PATH\n", argv[0]);
        return 64;
    }

    struct stat destination_stat;
    if (lstat(argv[2], &destination_stat) == -1) {
        if (errno != ENOENT) {
            fprintf(stderr, "lstat(%s) failed: %s\n", argv[2], strerror(errno));
            return 1;
        }
        if (rename(argv[1], argv[2]) == -1) {
            fprintf(stderr, "rename(%s, %s) failed: %s\n", argv[1], argv[2], strerror(errno));
            return 1;
        }
        return 0;
    }

    if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) == -1) {
        fprintf(stderr, "atomic swap of %s and %s failed: %s\n", argv[1], argv[2], strerror(errno));
        return 1;
    }
    return 0;
}
