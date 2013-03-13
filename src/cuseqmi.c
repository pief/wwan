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

#include "fioc.h"

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

static int cuseqmi_resize(size_t new_size)
{
	void *new_buf;

	if (new_size == cuseqmi_size)
		return 0;

	new_buf = realloc(cuseqmi_buf, new_size);
	if (!new_buf && new_size)
		return -ENOMEM;

	if (new_size > cuseqmi_size)
		memset(new_buf + cuseqmi_size, 0, new_size - cuseqmi_size);

	cuseqmi_buf = new_buf;
	cuseqmi_size = new_size;

	return 0;
}

static int cuseqmi_expand(size_t new_size)
{
	if (new_size > cuseqmi_size)
		return cuseqmi_resize(new_size);
	return 0;
}

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

	if (cuseqmi_expand(off + size)) {
		fuse_reply_err(req, ENOMEM);
		return;
	}

	memcpy(cuseqmi_buf + off, buf, size);
	fuse_reply_write(req, size);
}

static void fioc_do_rw(fuse_req_t req, void *addr, const void *in_buf,
		       size_t in_bufsz, size_t out_bufsz, int is_read)
{
	const struct fioc_rw_arg *arg;
	struct iovec in_iov[2], out_iov[3], iov[3];
	size_t cur_size;

	/* read in arg */
	in_iov[0].iov_base = addr;
	in_iov[0].iov_len = sizeof(*arg);
	if (!in_bufsz) {
		fuse_reply_ioctl_retry(req, in_iov, 1, NULL, 0);
		return;
	}
	arg = in_buf;
	in_buf += sizeof(*arg);
	in_bufsz -= sizeof(*arg);

	/* prepare size outputs */
	out_iov[0].iov_base =
		addr + (unsigned long)&(((struct fioc_rw_arg *)0)->prev_size);
	out_iov[0].iov_len = sizeof(arg->prev_size);

	out_iov[1].iov_base =
		addr + (unsigned long)&(((struct fioc_rw_arg *)0)->new_size);
	out_iov[1].iov_len = sizeof(arg->new_size);

	/* prepare client buf */
	if (is_read) {
		out_iov[2].iov_base = arg->buf;
		out_iov[2].iov_len = arg->size;
		if (!out_bufsz) {
			fuse_reply_ioctl_retry(req, in_iov, 1, out_iov, 3);
			return;
		}
	} else {
		in_iov[1].iov_base = arg->buf;
		in_iov[1].iov_len = arg->size;
		if (arg->size && !in_bufsz) {
			fuse_reply_ioctl_retry(req, in_iov, 2, out_iov, 2);
			return;
		}
	}

	/* we're all set */
	cur_size = cuseqmi_size;
	iov[0].iov_base = &cur_size;
	iov[0].iov_len = sizeof(cur_size);

	iov[1].iov_base = &cuseqmi_size;
	iov[1].iov_len = sizeof(cuseqmi_size);

	if (is_read) {
		size_t off = arg->offset;
		size_t size = arg->size;

		if (off >= cuseqmi_size)
			off = cuseqmi_size;
		if (size > cuseqmi_size - off)
			size = cuseqmi_size - off;

		iov[2].iov_base = cuseqmi_buf + off;
		iov[2].iov_len = size;
		fuse_reply_ioctl_iov(req, size, iov, 3);
	} else {
		if (cuseqmi_expand(arg->offset + in_bufsz)) {
			fuse_reply_err(req, ENOMEM);
			return;
		}

		memcpy(cuseqmi_buf + arg->offset, in_buf, in_bufsz);
		fuse_reply_ioctl_iov(req, in_bufsz, iov, 2);
	}
}

static void cuseqmi_ioctl(fuse_req_t req, int cmd, void *arg,
			  struct fuse_file_info *fi, unsigned flags,
			  const void *in_buf, size_t in_bufsz, size_t out_bufsz)
{
	int is_read = 0;

	(void)fi;

	if (flags & FUSE_IOCTL_COMPAT) {
		fuse_reply_err(req, ENOSYS);
		return;
	}

	switch (cmd) {
	case FIOC_GET_SIZE:
		if (!out_bufsz) {
			struct iovec iov = { arg, sizeof(size_t) };

			fuse_reply_ioctl_retry(req, NULL, 0, &iov, 1);
		} else
			fuse_reply_ioctl(req, 0, &cuseqmi_size,
					 sizeof(cuseqmi_size));
		break;

	case FIOC_SET_SIZE:
		if (!in_bufsz) {
			struct iovec iov = { arg, sizeof(size_t) };

			fuse_reply_ioctl_retry(req, &iov, 1, NULL, 0);
		} else {
			cuseqmi_resize(*(size_t *)in_buf);
			fuse_reply_ioctl(req, 0, NULL, 0);
		}
		break;

	case FIOC_READ:
		is_read = 1;
	case FIOC_WRITE:
		fioc_do_rw(req, arg, in_buf, in_bufsz, out_bufsz, is_read);
		break;

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
