/*
 * Small program to LUKS suspend devices before system suspend
 *
 * License: GNU GPLv3
 * Copyright: (c) 2018      Guilhem Moulin <guilhem@debian.org>
 *            (c) 2018-2020 Jonas Meurer <jonas@freesources.org>
 */

#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <err.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/resource.h>

#include <libcryptsetup.h>

#define SYSFS_POWER_SYNC_ON_SUSPEND "/sys/power/sync_on_suspend"
#define SYSFS_POWER_STATE           "/sys/power/state"

void usage() {
    printf("Usage: cryptsetup-suspend [-r|--reverse] <blkdev> [<blkdev> ...]\n"
           "      -r, --reverse             process luks devices in reverse order\n\n");
    exit(1);
}

/* Calculate free memory (MemAvailable + SwapFree) from /proc/meminfo */
uint32_t get_mem_swap_avail_kb() {
    FILE *meminfo = fopen("/proc/meminfo", "r");
    if (meminfo == NULL)
        err(EXIT_FAILURE, "couldn't open /proc/meminfo");

    int mem_avail_kb, swap_free_kb = 0;
    char line[256];
    while (fgets(line, sizeof(line), meminfo)) {
        if (strncmp(line, "MemAvailable", strlen("MemAvailable")) == 0) {
            if (sscanf(line, "MemAvailable: %d kB", &mem_avail_kb) != 1)
                errx(EXIT_FAILURE, "couldn't read MemAvailable from /proc/meminfo");
        } else if (strncmp(line, "SwapFree", strlen("SwapFree")) == 0) {
            if (sscanf(line, "SwapFree: %d kB", &swap_free_kb) != 1)
                errx(EXIT_FAILURE, "couldn't read SwapFree from /proc/meminfo");
        }
    }
    fclose(meminfo);

    uint32_t mem_swap_avail_kb = mem_avail_kb + swap_free_kb;
    if (mem_swap_avail_kb == 0)
       errx(EXIT_FAILURE, "error reading available memory and swap from /proc/meminfo");

    return mem_swap_avail_kb;
}

int main(int argc, char *argv[]) {
    int rv = 0;
    bool reverse = 0;
    int d_size;
    bool sync_on_suspend_reset = 0;
    FILE *sos = NULL;

    /* Process commandline arguments */
    if (argc < 2) {
        usage();
    } else if ((strcmp(argv[1], "-r") == 0) || (strcmp(argv[1], "--reverse") == 0)) {
        if (argc < 3)
            usage();

        reverse = 1;
        d_size = argc-2;
    } else {
        d_size = argc-1;
    }

    /* Read in devices */
    const char *devices[d_size];
    if (!reverse) {
        for (int i = 0; i < d_size; i++) {
            devices[i] = argv[i+1];
        }
    } else {
        for (int i = 0; i < d_size; i++) {
            devices[i] = argv[argc-i-1];
        }
    }

    /* Disable sync_on_suspend in Linux kernel
     *
     * Only available in Linux kernel >= 5.6 */
    if (access(SYSFS_POWER_SYNC_ON_SUSPEND, W_OK) < 0) {
        if (errno == ENOENT)
            warnx("kernel too old, can't disable sync on suspend");
    } else {
        sos = fopen(SYSFS_POWER_SYNC_ON_SUSPEND, "r+");
        if (!sos)
            err(EXIT_FAILURE, "couldn't open sysfs file");

        int sos_c = fgetc(sos);
        if (fgetc(sos) == EOF)
            err(EXIT_FAILURE, "couldn't read from file");

        if (sos_c == '0') {
            /* Already disabled */
        } else if (sos_c == '1') {
            sync_on_suspend_reset = 1;
            if (fputc('0', sos) <= 0)
                err(EXIT_FAILURE, "couldn't write to file");
        } else {
            errx(EXIT_FAILURE, "unexpected value from %s", SYSFS_POWER_SYNC_ON_SUSPEND);
        }

        fclose(sos);
    }

    /* Change process priority to -20 (highest) to avoid races between
     * the LUKS suspend(s) and the suspend-on-ram. */
    if (setpriority(PRIO_PROCESS, 0, -20) == -1)
        warn("can't lower process priority to -20");

    /* Get memory settings of keyslots from processed LUKS2 devices */
    uint32_t argon2i_max_memory_kb = 0;
    for (int i = 0; i < d_size; i++) {
        struct crypt_device *cd = NULL;
        if (crypt_init_by_name(&cd, devices[i])) {
            warnx("couldn't init LUKS device %s", devices[i]);
            rv = EXIT_FAILURE;
        } else {
            /* Only LUKS2 devices may use argon2i PBKDF */
            if (strcmp(crypt_get_type(cd), CRYPT_LUKS2) != 0)
                continue;
            int ks_max = crypt_keyslot_max(crypt_get_type(cd));
            for (int j = 0; j < ks_max; j++) {
                crypt_keyslot_info ki = crypt_keyslot_status(cd, j);
                /* Only look at active keyslots */
                if (ki != CRYPT_SLOT_ACTIVE && ki != CRYPT_SLOT_ACTIVE_LAST)
                    continue;
                struct crypt_pbkdf_type pbkdf_ki;
                if (crypt_keyslot_get_pbkdf(cd, j, &pbkdf_ki) < 0) {
                    warn("couldn't get PBKDF for keyslot %d of device %s", j, devices[i]);
                    rv = EXIT_FAILURE;
                } else {
                    if (pbkdf_ki.max_memory_kb > argon2i_max_memory_kb)
                        argon2i_max_memory_kb = pbkdf_ki.max_memory_kb;
                }
            }
        }
        crypt_free(cd);
    }

    /* Add some more memory to be on the save side
     * TODO: find a reasonable value */
    argon2i_max_memory_kb += 2 * 1024; // 2MB

    /* Check if we have enough memory available to prevent mlock() from
     * triggering the OOM killer. */
    uint32_t mem_swap_avail_kb = get_mem_swap_avail_kb();
    if (argon2i_max_memory_kb > mem_swap_avail_kb) {
        errx(EXIT_FAILURE, "Error: Available memory (%d kb) less than required (%d kb)",
                        mem_swap_avail_kb, argon2i_max_memory_kb);
    }

    /* Allocate and lock memory for later usage by LUKS resume in order to
     * prevent swapping out after LUKS devices (which might include swap
     * storage) have been suspended. */
    fprintf(stderr, "Allocating and mlocking memory: %d kb\n", argon2i_max_memory_kb);
    char *mem;
    if (!(mem = malloc(argon2i_max_memory_kb)))
        err(EXIT_FAILURE, "couldn't allocate enough memory");
    if (mlock(mem, argon2i_max_memory_kb) == -1)
        err(EXIT_FAILURE, "couldn't lock enough memory");
    /* Fill the allocated memory to make sure it's really reserved even if
     * memory pages are copy-on-write. */
    size_t i;
    size_t page_size = getpagesize();
    for (i = 0; i < argon2i_max_memory_kb; i += page_size)
        mem[i] = 0;

    /* Do the final filesystem sync since we disabled sync_on_suspend in
     * Linux kernel. */
    sync();

    for (int i = 0; i < d_size; i++) {
        struct crypt_device *cd = NULL;
        if (crypt_init_by_name(&cd, devices[i]) || crypt_suspend(cd, devices[i])) {
            warnx("couldn't suspend LUKS device %s", devices[i]);
            rv = EXIT_FAILURE;
        }
        crypt_free(cd);
    }

    fprintf(stderr, "Sleeping...\n");
    FILE *s = fopen(SYSFS_POWER_STATE, "w");
    if (!s)
        err(EXIT_FAILURE, "failed to open %s", SYSFS_POWER_STATE);
    if (fputs("mem", s) <= 0)
        err(EXIT_FAILURE, "couldn't write to %s", SYSFS_POWER_STATE);
    fclose(s);
    fprintf(stderr, "Resuming...\n");

    /* Restore original sync_on_suspend value */
    if (sync_on_suspend_reset) {
        sos = fopen(SYSFS_POWER_SYNC_ON_SUSPEND, "w");
        if (!sos)
            err(EXIT_FAILURE, "couldn't open sysfs file");
        if (fputc('1', sos) <= 0)
            err(EXIT_FAILURE, "couldn't write to file");
        fclose(sos);
    }

    return rv;
}
