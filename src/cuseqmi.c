/*
 * cuseqmi - an example of how to use CUSE to create a shim between
 * the proprietary Qualcomm QMI SDK and the qmi_wwan driver in the
 * mainline Linux kernel.
 *
 * Based on CUSE example: Character device in Userspace
 *
 *   Copyright (C) 2008-2009  SUSE Linux Products GmbH
 *   Copyright (C) 2008-2009  Tejun Heo <tj@kernel.org>
 *
 * The Qualcomm QMI SDK interface expectations are pulled from the
 * nicely rewritten Qualcomm Gobi 2000/3000 driver by Elly Jones
 * <ellyjones@google.com>.  That driver is
 *
 *   Copyright (c) 2011, Code Aurora Forum. All rights reserved.
 *
 * The rest of the glue is
 *
 *   Copyright (C)  2013 Bjørn Mork <bjorn@mork.no>
 *
 * This program can be distributed under the terms of the GNU GPL.
 * See the file COPYING.
 *
 * Building it:
 *   gcc -Wall `pkg-config fuse --cflags --libs` -lpthread cuseqmi.c -o cuseqmi
 *
 *
 

TODO: 

- allow specifying a single QMI device, automatically creating
  the dummy usbX interface and /dev/qcqmiX
- open /dev/cdc-wdmY on startup, verify QMI, start reader thread
- demux all read data into a list of connected clients
- enforce the client registrations ioctls
 */

#define FUSE_USE_VERSION 29

#include <cuse_lowlevel.h>
#include <fuse_opt.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <linux/types.h>


#define IOCTL_QMI_GET_SERVICE_FILE      (0x8BE0 + 1)
#define IOCTL_QMI_GET_DEVICE_VIDPID     (0x8BE0 + 2)
#define IOCTL_QMI_GET_DEVICE_MEID       (0x8BE0 + 3)
#define IOCTL_QMI_CLOSE                 (0x8BE0 + 4)

#define DBG(fmt, arg...)						\
do {									\
	fprintf(stderr, "%s: " fmt "\n", __func__, ##arg);		\
} while (0)

struct qmux {
	__u8 tf;	/* always 1 */
	__u16 len;
	__u8 ctrl;
	__u8 service;
	__u8 qmicid;
} __attribute__((__packed__));

const size_t qmux_size = sizeof(struct qmux);

struct qmictl {
	struct qmux h;
	__u8 req;
	__u8 tid;
	__u16 msgid;
	__u16 tlvsize;
} __attribute__((__packed__));


/* global data */

/* /dev/cdc-wdmX: */
static int fin = 0;
static int fd;                               /* handle */
static int bufsz = 4096;                     /* message size */
static pthread_mutex_t wr_mutex = PTHREAD_MUTEX_INITIALIZER; /* write lock */
static __u16 vid = 0x1199;
static __u16 pid = 0x68a2;  /* USB vid:pid */
#define MEIDLEN 14
static char meid[MEIDLEN] = "0123456789abcd"; /* meid */

/* defining a QMI reply or indication message */
struct qmimsg {
	struct qmimsg *next; /* next message */
	size_t len;     /* length of msg */
	struct qmux h;  /* header, which will be stripped when sending to client */
	char msg[];
};

/* defining a client */
struct qclient {
	__u16 cid;
	struct qmimsg *rq;
	pthread_mutex_t rqlock;
	pthread_cond_t ready;  /* data available for reading */
	struct qclient *next;
};

/* unsorted list of open clients */
static struct qclient *clients = NULL;
static pthread_mutex_t cl_mutex = PTHREAD_MUTEX_INITIALIZER; /* client list lock */

struct qclient *new_client(int cid)
{
	struct qclient *client = malloc(sizeof(struct qclient));
	
	if (!client)
		return NULL;

	client->cid = cid;
	client->rq = NULL;
	pthread_mutex_init(&client->rqlock, NULL);
	pthread_cond_init(&client->ready, NULL);
	/* can always insert at head */
	pthread_mutex_lock(&cl_mutex);
	client->next = clients;
	clients = client;
	pthread_mutex_unlock(&cl_mutex);
	return client;
}

void destroy_client(struct qclient *client)
{
	struct qclient *p;
	struct qmimsg *m, *tmp;

	/* locate client in list */
	pthread_mutex_lock(&cl_mutex);
	if (clients == client)
		clients = client->next;
	else {
		for (p = clients; p && p->next != client; p = p->next);
		/* unlink client */
		if (p)
			p->next = client->next;
	}
	pthread_mutex_unlock(&cl_mutex);

	/* unlink all unread messages */
	pthread_mutex_lock(&client->rqlock);
	m = client->rq;
	while  (m) {
		tmp = m;
		m = m->next;
		free(tmp);
	}
	pthread_mutex_unlock(&client->rqlock);
	pthread_mutex_destroy(&client->rqlock);
	pthread_cond_destroy(&client->ready);
	free(client);
}

/* predefined QMI_CTL get versions message */
static char get_ver_msg[] = { 0x01, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x21, 0x00, 0x04, 0x00, 0x01, 0x01, 0x00, 0xff };

/* predefined QMI_CTL alloc CID message */
static char alloc_cid_msg[] = { 0x01, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x22, 0x00, 0x04, 0x00, 0x01, 0x01, 0x00, 0x00 };

/* predefined QMI_CTL release CID message */
static char release_cid_msg[] = {  0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x05, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00 };

/* check if msg is a reply to a "msgid" QMI_CTL message */
static int is_match(struct qmimsg *msg, __u16 msgid)
{
	struct qmictl *ctl = (struct qmictl *)&msg->h;
	return (ctl->h.ctrl == 0x80 &&
		ctl->h.service == 0 && 
		ctl->h.qmicid == 0 &&
		ctl->msgid == msgid);
}

/* send a QMI_CTL message and wait until timeout for the reply */
static int do_ctl(char *buf, size_t buflen, int timeout)
{
	int rc = 0;
	int retry = 5;
	struct qclient *client = new_client(0); /* QMI_CTL */
	struct qmictl *ctl;
	__u16 msgid;
	struct qmimsg *msg;

	DBG("");
	if (!client)
		return -ENOMEM;

	/* set up matching key */
	ctl = (struct qmictl *)buf;
	msgid = ctl->msgid;

	/* take the write lock - no one are allowed to write anything while we run this! */
	pthread_mutex_lock(&wr_mutex);
	rc = write(fd, buf, buf[1] + 1); /* assuming that we always construct valid QMUX... */
	pthread_mutex_unlock(&wr_mutex);

	pthread_mutex_lock(&client->rqlock);
retry:
	if (!client->rq)
		pthread_cond_wait(&client->ready, &client->rqlock);

	/* check the new message(s) and retry if not matching */
	do {
		msg = client->rq;
		if (msg)
			client->rq = msg->next;
	} while (msg && !is_match(msg, msgid));
	if (!msg && retry--)
		goto retry;

	pthread_mutex_unlock(&client->rqlock);

	/* destroy temporary client */
	destroy_client(client);

	/* may have timed out */
	if (!msg)
		return -ETIMEDOUT;

	if (msg->h.len < buflen)
		memcpy(buf, &msg->h, msg->h.len + 1);
	else
		rc = -EINVAL;

	free(msg);
	return rc;
}

static int get_ver(void)
{
	int rc;
	char *buf = malloc(bufsz);

	if (!buf)
		return -ENOMEM;

	/* initialize buf with default message */
	memcpy(buf, get_ver_msg, sizeof(get_ver_msg));
	rc = do_ctl(buf, bufsz, 5000);

	/* the reply will have two TLVs: Status + result

    # decode the list of supported systems in TLV 0x01
    my $data = $ret->{'tlvs'}{0x01};
    my $n = unpack("C", $data);
    $data = substr($data, 1);
    print "supports $n QMI subsystems:\n";
    for (my $i = 0; $i < $n; $i++) {
	my ($sys, $maj, $min) = unpack("Cvv", $data);
	my $system = $sysname{$sys} || sprintf("%#04x", $sys);
	print "  $system ($maj.$min)\n";
	$data = substr($data, 5);
    }
	*/

/*	n = buf[];
	for (i = 0; i < n; i++) {
		sys = buf[ + i * 5];
		maj = le16_to_cpu(*
		DBG("%02x: %u.%u", sys, maj, min);
	}
*/

	free(buf);
	return rc;
}

static int alloc_cid(struct qclient *client, __u8 system)
{
	int rc;
	char *buf = malloc(bufsz);

	if (!buf)
		return -ENOMEM;

	/* initialize buf with default message */
	memcpy(buf, alloc_cid_msg, sizeof(alloc_cid_msg));

	/* the last byte is the requested system */
	buf[sizeof(alloc_cid_msg) - 1] = system;
	
	/* send it */
	rc = do_ctl(buf, bufsz, 5000);

	/* the reply will have two TLVs: Status + result
	 *  01 17 00 80 00 00 01 01 22 00 0c 00 02 04 00 00 00 00 00 01 02 00 02 01
	 * we'll just blindly assume that the last byte is the wanted one
 	 */
	pthread_mutex_lock(&cl_mutex);
	if (rc < 0)
		client->cid = (__u16)-1;
	else
		client->cid = system << 8 | buf[0x17];
	pthread_mutex_unlock(&cl_mutex);

	free(buf);
	return rc;
}

static int release_cid(struct qclient *client)
{
	int rc;
	__u8 system, cid;
	char *buf;

	DBG("client=%p, cid=%04x", client, client->cid);
	system = client->cid >> 8 & 0xff;
	cid = client->cid & 0xff;

	/* invalidate now */
	pthread_mutex_lock(&cl_mutex);
	client->cid = (__u16)-1;
	pthread_mutex_unlock(&cl_mutex);

	buf = malloc(bufsz);
	if (!buf)
		return -ENOMEM;

	/* initialize buf with default message */
	memcpy(buf, release_cid_msg, sizeof(release_cid_msg));
	buf[sizeof(release_cid_msg) - 2] = system;
	buf[sizeof(release_cid_msg) - 1] = cid;

	/* send it */
	rc = do_ctl(buf, bufsz, 5000);
	free(buf);
	return rc;
}

/* -- eof from qcqmi.c --- */


static const char *usage =
"usage: cuseqmi [options]\n"
"\n"
"options:\n"
"    --help|-h             print this help message\n"
"    --maj=MAJ|-M MAJ      device major number\n"
"    --min=MIN|-m MIN      device minor number\n"
"    --name=NAME|-n NAME   device name (mandatory)\n"
"\n";

static void cuseqmi_open(fuse_req_t req, struct fuse_file_info *fi)
{
	struct qclient *client = new_client(-1); /* invalid CID */

	fprintf(stderr, "%s\n", __func__);
	if (!client) {
		fuse_reply_err(req, ENOMEM);
		return;
	}
	fi->nonseekable = 1;
	fi->fh = (uint64_t)client;
	fuse_reply_open(req, fi);
}

static void cuseqmi_release(fuse_req_t req, struct fuse_file_info *fi)
{
	struct qclient *client = (void *)fi->fh;

	fprintf(stderr, "%s\n", __func__);
	fi->fh = (uint64_t)NULL;
	destroy_client(client);
	fuse_reply_err(req, 0);
}

/* reply with the next queued message only */
static void cuseqmi_read(fuse_req_t req, size_t size, off_t off, struct fuse_file_info *fi)
{
	struct qmimsg *msg;
	struct qclient *client = (void *)fi->fh;

	/* fixme: don't wait if non-blocking */
	pthread_mutex_lock(&client->rqlock);
	if (!client->rq)
		pthread_cond_wait(&client->ready, &client->rqlock);
	msg = client->rq;
	if (msg)
		client->rq = msg->next;
	pthread_mutex_unlock(&client->rqlock);

	/* fixme:  verify that msg->len <= size */
	if (msg) {
		fuse_reply_buf(req, msg->msg, msg->len);
		free(msg);
	} else {
		fuse_reply_err(req, EAGAIN);
	}
}

static void qmuxify(char *buf, int cid, int len)
{
	struct qmux *q = (void *)buf;

	q->tf = 1;
	q->len = len + qmux_size - 1;
	q->ctrl = 0;
	q->service = cid >> 8 & 0xff;
	q->qmicid = cid & 0xff;
}

static void cuseqmi_write(fuse_req_t req, const char *buf, size_t size, off_t off, struct fuse_file_info *fi)
{
	char *wbuf;
	int status = 0;
	struct qclient *client = (void *)fi->fh;

	fprintf(stderr, "%s\n", __func__);
	if (!client) {
		DBG("Bad file data\n");
		status = -EBADF;
		goto err;
	}
	if (client->cid == (__u16)-1) {
		DBG("Client ID must be set before writing 0x%04X", client->cid);
		status = -EBADR;
		goto err;
	}
	wbuf = malloc(size + qmux_size);
	if (!wbuf) {
		status = -ENOMEM;
		goto err;
	}
	memcpy(wbuf + qmux_size, buf, size);
	qmuxify(wbuf, client->cid, size);

	/* lock for write */
	pthread_mutex_lock(&wr_mutex);
	status = write(fd, wbuf, size + qmux_size);
	pthread_mutex_unlock(&wr_mutex);

	if (status > qmux_size)
		status -= qmux_size;
	else
		status = -EIO;
	free(wbuf);

	if (status >= 0)
		fuse_reply_write(req, status);
	else
err:
		fuse_reply_err(req, -status);
}

static void cuseqmi_ioctl(fuse_req_t req, int cmd, void *arg,
			  struct fuse_file_info *fi, unsigned flags,
			  const void *in_buf, size_t in_bufsz, size_t out_bufsz)
{
	struct qclient *client = (void *)fi->fh;
	int ret = 0;

	fprintf(stderr, "%s: cmd=%#010x, arg=%p\n", __func__, cmd, arg);

/*	if (flags & FUSE_IOCTL_COMPAT) {
		fuse_reply_err(req, ENOSYS);
		return;
	}
*/
	switch (cmd) {

	case IOCTL_QMI_GET_SERVICE_FILE:
		if (client->cid != (__u16)-1) {
			DBG("Close the current connection before opening a new one\n");
			fuse_reply_err(req, EBADR);
                } else {
			__u8 cid = (long)arg;
			DBG("Setting up QMI for service %u", cid);
			ret = alloc_cid(client, cid);
			fuse_reply_ioctl(req, ret, NULL, 0);
		}
		break;

	/* Okay, all aboard the nasty hack express. If we don't have this
	 * ioctl() (and we just rely on userspace to close() the file
	 * descriptors), if userspace has any refs left to this fd (like, say, a
	 * pending read()), then the read might hang around forever. Userspace
	 * needs a way to cause us to kick people off those waitqueues before
	 * closing the fd for good.
	 *
	 * If this driver used workqueues, the correct approach here would
	 * instead be to make the file descriptor select()able, and then just
	 * use select() instead of aio in userspace (thus allowing us to get
	 * away with one thread total and avoiding the recounting mess
	 * altogether).
	 */
	case IOCTL_QMI_CLOSE:
		DBG("Tearing down QMI for service %lu", (long)arg);
		if (client->cid == (__u16)-1) {
			DBG("no qmi cid");
			ret = -EBADR;
			goto err;
		}

		ret = release_cid(client);
		fuse_reply_ioctl(req, ret, NULL, 0);
		break;

	case IOCTL_QMI_GET_DEVICE_VIDPID:
		DBG("IOCTL_QMI_GET_DEVICE_VIDPID, out_bufsz=%zu", out_bufsz);
                if (!out_bufsz) {
                        struct iovec iov = { arg, sizeof(__u32) };
                        fuse_reply_ioctl_retry(req, NULL, 0, &iov, 1);
                } else {
			__u32 vidpid = vid << 16 | pid;
			DBG("copying vid:pid to userspace\n");
                        fuse_reply_ioctl(req, 0,  &vidpid, sizeof(__u32));
		}
		break;

	case IOCTL_QMI_GET_DEVICE_MEID:
		DBG("IOCTL_QMI_GET_DEVICE_MEID, out_bufsz=%zu", out_bufsz);
                if (!out_bufsz) {
                        struct iovec iov = { arg, MEIDLEN };
                        fuse_reply_ioctl_retry(req, NULL, 0, &iov, 1);
                } else {
			DBG("copying MEID to userspace\n");
                        fuse_reply_ioctl(req, 0, &meid, MEIDLEN);
		}
		break;

	default:
		DBG("unsupported ioctl");
		fuse_reply_err(req, EINVAL);
	}
	return;
err:
	fuse_reply_err(req, -ret);
}

struct cuseqmi_param {
	unsigned		major;
	unsigned		minor;
	char			*dev_name;
	char			*qmi_name;
	int			is_help;
};

#define CUSEQMI_OPT(t, p) { t, offsetof(struct cuseqmi_param, p), 1 }

static const struct fuse_opt cuseqmi_opts[] = {
	CUSEQMI_OPT("-M %u",		major),
	CUSEQMI_OPT("--maj=%u",		major),
	CUSEQMI_OPT("-m %u",		minor),
	CUSEQMI_OPT("--min=%u",		minor),
	CUSEQMI_OPT("-n %s",		dev_name),
	CUSEQMI_OPT("--name=%s",	dev_name),
	CUSEQMI_OPT("-q %s",		qmi_name),
	CUSEQMI_OPT("--qmidev=%s",	qmi_name),
	FUSE_OPT_KEY("-h",		0),
	FUSE_OPT_KEY("--help",		0),
	FUSE_OPT_END
};

static int cuseqmi_process_arg(void *data, const char *arg, int key,
			       struct fuse_args *outargs)
{
	struct cuseqmi_param *param = data;

	(void)outargs;
	(void)arg;

	switch (key) {
	case 0:
		param->is_help = 1;
		fprintf(stderr, "%s", usage);
		return fuse_opt_add_arg(outargs, "-ho");
	default:
		return 1;
	}
}

/* add a copy of the complete QMUX in buf to client's read queue */
static void add_msg_to_client(struct qclient *client, char *buf, int len)
{
	struct qmimsg *new, *p;

	DBG("client=%p", client);

	/* allocate a new message entry */
	new = malloc(sizeof(struct qmimsg) + len - qmux_size);
	if (!new)
		return; /* FIMXE: warn about this */

	new->next = NULL; /* always at the end */
	new->len = len - qmux_size;
	memcpy(&new->h, buf, len);

	/* get the client lock */
	pthread_mutex_lock(&client->rqlock);
	if (!client->rq)
		client->rq = new;
	else {
		for (p = client->rq; p->next; p = p->next);
		p->next = new;
	}
	pthread_mutex_unlock(&client->rqlock);
	pthread_cond_signal(&client->ready);
}

/* allocate a copy of the QMUX in buf for every client that should receive it */
static void copy_msg_to_clients(char *buf, int len)
{
	struct qclient *p;
	struct qmux *q;
	int mask = 0, val = 0;
	__u8 flags;

	DBG("");
	
	/* analyze the QMI message first */
	if (len < sizeof(struct qmux) + 1)
		return;
	q = (struct qmux *)buf;
	flags = buf[qmux_size]; /* the first byte after the QMUX */

	if (q->service == 0) { /* QMI_CTL */
		if (flags == 0x01) /* QMI_CTL response */
			mask = 0xffff;
	} else { /* clients with this service */
		val = q->service << 8;
		mask = 0xff << 8;
		if (q->qmicid != 0xff) { /* only address clients with this cid */
			val |= q->qmicid;
			mask |= 0xff;
		}
	}

	/* cannot accept than anyone modifies the list while we're scanning it */
	pthread_mutex_lock(&cl_mutex);
	for (p = clients; p; p= p->next)
		if ((p->cid & mask) == val)
			add_msg_to_client(p, buf, len);
	pthread_mutex_unlock(&cl_mutex);
}

/* ==== reader thread ===== */

void *readcdcwdm(void *tmp)
{
	int n, rv;
	fd_set rfds;
	struct fuse_session **se = tmp;
	char *buf = malloc(bufsz);

	if (!buf)
		goto err;

	printf("Hello World! It's me\n");
	while (!fin) {
		FD_ZERO(&rfds);
		FD_SET(fd, &rfds);
		rv = select(1, &rfds, NULL, NULL, NULL);
		if (rv == -1) {
			perror("select()");
			fin = 1;
		} else if (FD_ISSET(fd, &rfds)) {
			n = read(fd, buf, bufsz);
			printf("%s: read %d bytes\n", __func__, n);
			
			/* find matching client(s) and link a copy into the rq */
			if (n > 0)
				copy_msg_to_clients(buf, n);
		} else
			fin = 1;
	}
	free(buf);
	perror("reader exiting:");
	
	/* terminate main loop */
	fuse_session_exit(*se);
err:
	pthread_exit(NULL);
}

static const struct cuse_lowlevel_ops cuseqmi_clop = {
	.open		= cuseqmi_open,
	.release        = cuseqmi_release,
	.read		= cuseqmi_read,
	.write		= cuseqmi_write,
	.ioctl		= cuseqmi_ioctl,
};

int main(int argc, char **argv)
{
	struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
	struct cuseqmi_param param = { 0, 0, NULL, 0 };
	char dev_name[128] = "DEVNAME=";
	const char *dev_info_argv[] = { dev_name };
	struct cuse_info ci;
	pthread_t readthread;
	int rc;

        struct fuse_session *se;
        int multithreaded;
 

	if (fuse_opt_parse(&args, &param, cuseqmi_opts, cuseqmi_process_arg)) {
		fprintf(stderr, "failed to parse option\n");
		return -1;
	}

	if (!param.is_help) {
		if (!param.dev_name || !param.qmi_name) {
			fprintf(stderr, "Error: device name missing\n");
			return -1;
		}
		strncat(dev_name, param.dev_name, sizeof(dev_name) - 9);
	}

	/* open QMI device */
	fd = open(param.qmi_name, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		perror("Error in open");
		return -1;
	}

	/* use the new ioctl to get the message size, falling back to
	 * static default if it fails
	 */


	/* run QMI_CTL get version, serial numbers etc */

	/* create qcqmi device */
	memset(&ci, 0, sizeof(ci));
	ci.dev_major = param.major;
	ci.dev_minor = param.minor;
	ci.dev_info_argc = 1;
	ci.dev_info_argv = dev_info_argv;
	ci.flags = CUSE_UNRESTRICTED_IOCTL;

/* expanding this:
	rc = cuse_lowlevel_main(args.argc, args.argv, &ci, &cuseqmi_clop,  NULL);
   to allow us to forcefully exit the loop
*/

        se = cuse_lowlevel_setup(args.argc, args.argv, &ci, &cuseqmi_clop, &multithreaded, NULL);
        if (se == NULL)
                return -1;

	/* create reader thread */
	rc = pthread_create(&readthread, NULL, readcdcwdm, &se);
	if (rc) {
		printf("ERROR; return code from pthread_create() is %d\n", rc);
		return -1;
	}

	if (multithreaded)
                rc = fuse_session_loop_mt(se);
        else
                rc = fuse_session_loop(se);

        cuse_lowlevel_teardown(se);
	printf("cuse_lowlevel_main returned %d\n", rc);
	pthread_cancel(readthread);
	fin = 1;
	close(fd);
	pthread_exit(NULL);
	return rc;
}
