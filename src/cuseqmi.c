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
 *   gcc -Wall `pkg-config fuse --cflags --libs` cuseqmi.c -o cuseqmi
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

static void *cuseqmi_buf;
static size_t cuseqmi_size;

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
	fuse_reply_open(req, fi);
}

static void cuseqmi_read(fuse_req_t req, size_t size, off_t off,
			 struct fuse_file_info *fi)
{
	(void)fi;

	if (off >= cuseqmi_size)
		off = cuseqmi_size;
	if (size > cuseqmi_size - off)
		size = cuseqmi_size - off;

	fuse_reply_buf(req, cuseqmi_buf + off, size);
}

static void cuseqmi_write(fuse_req_t req, const char *buf, size_t size,
			  off_t off, struct fuse_file_info *fi)
{
	(void)fi;

	fuse_reply_write(req, size);
}


static void cuseqmi_ioctl(fuse_req_t req, int cmd, void *arg,
			  struct fuse_file_info *fi, unsigned flags,
			  const void *in_buf, size_t in_bufsz, size_t out_bufsz)
{
	(void)fi;

	fprintf(stderr, "%s: here\n", __func__);

	if (flags & FUSE_IOCTL_COMPAT) {
		fuse_reply_err(req, ENOSYS);
		return;
	}

	switch (cmd) {

	default:
		fuse_reply_err(req, EINVAL);
	}
}

struct cuseqmi_param {
	unsigned		major;
	unsigned		minor;
	char			*dev_name;
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

static const struct cuse_lowlevel_ops cuseqmi_clop = {
	.open		= cuseqmi_open,
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

	if (fuse_opt_parse(&args, &param, cuseqmi_opts, cuseqmi_process_arg)) {
		printf("failed to parse option\n");
		return 1;
	}

	if (!param.is_help) {
		if (!param.dev_name) {
			fprintf(stderr, "Error: device name missing\n");
			return 1;
		}
		strncat(dev_name, param.dev_name, sizeof(dev_name) - 9);
	}

	memset(&ci, 0, sizeof(ci));
	ci.dev_major = param.major;
	ci.dev_minor = param.minor;
	ci.dev_info_argc = 1;
	ci.dev_info_argv = dev_info_argv;
	ci.flags = CUSE_UNRESTRICTED_IOCTL;

	return cuse_lowlevel_main(args.argc, args.argv, &ci, &cuseqmi_clop,
				  NULL);
}
