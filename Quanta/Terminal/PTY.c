#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/ioctl.h>

int quanta_spawn_pty(int *master, const char *shell, const char *directory, char *const environment[]) {
    struct winsize size = {24, 80, 0, 0};
    int maxfd = getdtablesize();
    int pid = forkpty(master, 0, 0, &size);
    if (pid == 0) {
        for (int fd = 3; fd < maxfd; fd++) close(fd);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTSTP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        if (chdir(directory) != 0) _exit(126);
        char *const arguments[] = {(char *)shell, "-l", 0};
        execve(shell, arguments, environment);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}

void quanta_resize_pty(int master, unsigned short rows, unsigned short columns) {
    struct winsize size = {rows, columns, 0, 0};
    ioctl(master, TIOCSWINSZ, &size);
}
