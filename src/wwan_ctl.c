/* 
Copyright 2011 Bjørn Mork <bjorn@mork.no>
License: GPLv2
*/

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <stdarg.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>

/* default values for options */
static char *supported[] = { "0bdb:1900", NULL };
static int timeout = 10;	/* read timeout */
static char wwan_apn[] = "";
static int wwan_poweroff = 1;	/* power off radio when interface goes down? */
static char wwan_gpstty[] = "";
static int wwan_mode = 1;	/* Radio mode 1=auto, 5=GSM, 6=UTRAN */
static int wwan_roaming_ok = 0;	/* Disallow roaming by default */
static int wwan_debug = 0;
static char wwan_cfg_file[] = "/etc/default/wwan_ctl";

void dbg(const char *str, ...)
{
    va_list args;
    va_start(args, str);
    vfprintf(stderr, str, args);
}

void fatal(const char *str, ...)
{
    va_list args;
    va_start(args, str);
    vfprintf(stderr, str, args);
    exit(2);
}

int wwan_readcfg(void)
{
	return -1;
}

int wwan_checkdevice(void)
{
	return -1;
}

char *wwan_getgpsport(void)
{
	return "";
}

char *wwan_getmgmt(void)
{
	return "/dev/ttyACM1";
}

int wwan_verify_pin(void)
{
	return -1;
}

int wwan_enable_gps(void)
{
	return -1;
}

int wwan_connected(void)
{
	return -1;
}

int wwan_configure_account(void)
{
	return -1;
}

int wwan_power_radio_on(void)
{
	return -1;
}

int wwan_connect(void)
{
	return -1;
}

int wwan_disconnect(void)
{
	return -1;
}


int main (int argc, char **argv)
{
	int mgmt_fd;
	ssize_t n, c;
	char buf[512], *p;
	struct termios t;

	if (argc != 1)
		fatal("usage: %s gps|start|stop\n", argv[0]);

        if ((mgmt_fd = open(wwan_getmgmt(),  O_RDWR|O_SYNC)) < 0)
                fatal("failed to open '%s': %d %m\n", wwan_getmgmt(), errno);

	tcgetattr(mgmt_fd, &t);
	t.c_lflag &= ~(ICANON | ECHO);
	tcsetattr(mgmt_fd, TCSADRAIN, &t);

	sprintf(buf, "%s", "ATI\r\n");
	write(mgmt_fd, buf, strlen(buf));
	p = buf;
	c = 0;
	while (n = read(mgmt_fd, p, sizeof(buf) - c)) {
		p[n] = 0;
		fprintf(stderr, "%s", p);
		p += n;
		c += n;
	}
	buf[c] = 0;

	dbg("%s(): read %d bytes: %s", __FUNCTION__, c, buf);

        close (mgmt_fd);
        return 0;
}
