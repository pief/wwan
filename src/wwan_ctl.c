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
static int wwan_simpin = 0;

/* saved values */
static struct termios restore_tios;

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

int wwan_getmgmt_fd(const char *device)
{
	int fd;
	struct termios tios;

	fprintf(stderr, "%s(): opening \"%s\"\n", __FUNCTION__, device);
        if ((fd = open(device,  O_RDWR)) < 0)
		fatal("%s(): failed to open '%s': %d %m\n", __FUNCTION__, device, errno);

	/* FIXME: don't do any termios things if we use a cdc-wdm device (which is *not* a tty!) */

	/* get current tty settings */
	if (tcgetattr(fd, &tios) < 0)
		if (errno = ENOTTY)
			/* don't do any termios things if we use a cdc-wdm device (which is *not* a tty!) */
			return fd;
		else
			fatal("%s(): tcgetattr: %m\n", __FUNCTION__);

	/* save'em so we can restor on exit */
	memcpy(&restore_tios, &tios, sizeof(restore_tios));

	/* if this works for pppd, then it works for us */
	tios.c_cflag     &= ~(CSIZE | CSTOPB | PARENB | CRTSCTS);
	tios.c_cflag     |= CS8 | CREAD | CLOCAL;
	tios.c_iflag      = IGNBRK | IGNPAR;
	tios.c_oflag      = 0;
	tios.c_lflag      = 0;
	tios.c_cc[VMIN]   = 1;
	tios.c_cc[VTIME]  = 0;


	/* we don't care much, but 115k is fine */
	cfsetospeed (&tios, B115200);
	cfsetispeed (&tios, B115200);

	while (tcsetattr(fd, TCSAFLUSH, &tios) < 0)
		if (errno != EINTR)
			fatal("%s(): tcsetattr: %m\n", __FUNCTION__);
	

	return fd;
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

int cmd(int fd, const char *cmd, char *buf, ssize_t bufsize)
{
	char *p;
	ssize_t n = 0;
	int ok = 0;

	if (wwan_debug > 1)
		fprintf(stderr, "%s() called with fd=%d, cmd=%s, buf=%p, bufsize=%d\n", __FUNCTION__, fd, cmd, buf, bufsize);

	sprintf(buf, "%s\r\n", cmd);
	write(fd, buf, strlen(buf));
	tcdrain(fd);

	while (!ok) {
		p = buf + n;
		n += read(fd, p, bufsize - n);
		buf[n] = 0;
		if (strstr(p, "OK"))
			ok = 1;
		else if (strstr(p, "ERROR"))
			ok = -1;
	}
	if (wwan_debug > 1)
		fprintf(stderr, "ok=%d, n=%d\n", ok, n);
	return n;
}

int main(int argc, char **argv)
{
	int mgmt_fd;
	ssize_t c;
	char buf[128];
	struct termios tios, restore_tios;

/*
	if (argc != 1)
		fatal("usage: %s gps|start|stop\n", argv[0]);
*/
	if (argc == 2)
		mgmt_fd = wwan_getmgmt_fd(argv[1]);
	else
		mgmt_fd = wwan_getmgmt_fd("/dev/ttyACM1");

	c = cmd(mgmt_fd, "ATI", buf, sizeof(buf));
	fprintf(stderr, "%s", buf);

	c = cmd(mgmt_fd, "AT+CPIN?", buf, sizeof(buf));
	fprintf(stderr, "%s", buf);

	if (strstr(buf, "+CPIN: SIM PIN")) {
		if (!wwan_simpin)
			fatal("SIM PIN required");
		sprintf(buf, "AT+CPIN=\"%04d\"", wwan_simpin);
		c = cmd(mgmt_fd, buf, buf, sizeof(buf));
		fprintf(stderr, "%s", buf);
	}		

	c = cmd(mgmt_fd, "AT+CGSM?", buf, sizeof(buf));
	fprintf(stderr, "%s", buf);

	c = cmd(mgmt_fd, "AT+GGSM?", buf, sizeof(buf));
	fprintf(stderr, "%s", buf);

        close (mgmt_fd);
        return 0;
}
