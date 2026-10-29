// ================================================================
// Host pseudo-terminals for the virtual boards: Bluesim (test/sim_preload.c, `make sim-board`)
// and Verilator (sim/linux_bram/tb_top.cpp, `make sim-board-verilator`).
// ================================================================
#ifndef SIM_PTY_H
#define SIM_PTY_H

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

// Opens a pty, links it at $env (or dflt), returns the non-blocking master (-1 on failure).
static int sim_pty_make (const char *env, const char *dflt, const char *what)
{
    int fd = posix_openpt (O_RDWR | O_NOCTTY);
    if (fd < 0 || grantpt (fd) || unlockpt (fd)) { perror ("[sim] posix_openpt"); return -1; }
    const char *name = ptsname (fd);
    // Keep our own slave open in raw mode (never closed): the line discipline stays raw for
    // whoever attaches, and the master never sees EIO between clients.
    int slave = open (name, O_RDWR | O_NOCTTY);
    struct termios t;
    if (slave >= 0 && tcgetattr (slave, &t) == 0) { cfmakeraw (&t); tcsetattr (slave, TCSANOW, &t); }
    fcntl (fd, F_SETFL, fcntl (fd, F_GETFL) | O_NONBLOCK);
    const char *link = getenv (env);
    if (!link) link = dflt;
    unlink (link);
    if (symlink (name, link) != 0) link = name;
    fprintf (stderr, "[sim] %s: %s (%s)\n", what, link, name);
    return fd;
}

#endif
