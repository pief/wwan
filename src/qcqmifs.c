/*
  qcqmifs - an example of how to use FUSE to create a shim between the
  proprietary Qualcomm QMI SDK and the qmi_wwan driver in the mainline
  Linux kernel.
  
  This code is heavily based on the FUSE "hello" example, which is

    Copyright (C) 2001-2007  Miklos Szeredi <miklos@szeredi.hu>

  The Qualcomm QMI SDK interface expectations are pulled from the nicely
  rewritten Qualcomm Gobi 2000/3000 driver by Elly Jones <ellyjones@google.com>.
  That driver is 

    Copyright (c) 2011, Code Aurora Forum. All rights reserved.

  The rest of the glue is

    Copyright (C) 2012 Bjørn Mork <bjorn@mork.no>

  This program can be distributed under the terms of the GNU GPLv2.
  See the file COPYING.

  
  Building it:
  gcc -Wall `pkg-config fuse --cflags --libs` qcqmifs.c -o qcqmifs

  Running it (with the optional:
  # ./qcqmifs /mnt/whatever -d -o default_permissions,allow_other

  Using it:

  - all existing /dev/cdc-wdmX devices will get a mirror 
     device under the chosen mountpoint named /mnt/whatever/qcqmiX

  - create a symlink from /dev/qcqmi or /dev/qcqmi0 to the wanted
     mirror device

 Restrictions:

   - no dynamic device discovery.  Program must be restarted to detect
     new or removed devices

   - no automatic symlinking

   - /dev/qcqmiX where X > 0 is not supported by the SDK, so the symlink
     names cannot always match real device names


*/

/* FUSE API version */
#define FUSE_USE_VERSION 26

#include <fuse.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/types.h>
#include <dirent.h>

static int qcqmi_getattr(const char *path, struct stat *stbuf)
{
	int res = 0;
	int x;
	char name[] = "/dev/cdc-wdmX";

	fprintf(stderr, "%s: path=%s\n", __func__, path);

	if (strcmp(path, "/") == 0) {
		memset(stbuf, 0, sizeof(struct stat));
		stbuf->st_mode = S_IFDIR | 0755;
		stbuf->st_nlink = 2;
	} else {
		if (strncmp("/qcqmi", path, 6))
			return -EINVAL;

		x = strtoul(path + 6, NULL, 10);
		if (x > 9)
			return -EINVAL;

		sprintf(name, "/dev/cdc-wdm%u", x);
		res = stat(name, stbuf);
		stbuf->st_mode = S_IFREG | 0664;
	}

	return res;
}

static int cdcwdm_filter(const struct dirent *d)
{
	return !strncmp("cdc-wdm", d->d_name, 7);
}


/* create a directory mirror of the current /dev/cdc-wdmX devices */
static int qcqmi_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
			 off_t offset, struct fuse_file_info *fi)
{
	(void) offset;
	(void) fi;
	struct dirent **namelist;
	int i, n, x;
	char name[6];

	if (strcmp(path, "/") != 0)
		return -ENOENT;

	fprintf(stderr, "%s: path=%s\n", __func__, path);

	filler(buf, ".", NULL, 0);
	filler(buf, "..", NULL, 0);
	
	n = scandir("/dev", &namelist, cdcwdm_filter, alphasort);
	if (n < 0)
		return n;

	for (i = 0; i < n; i++) {
		x =  strtoul(namelist[i]->d_name + 7, NULL, 10);
		if (x < 10) {
			sprintf(name, "qcqmi%u", x);
			filler(buf, name, NULL, 0);
		}
		free(namelist[i]);
	}
	free(namelist);
	return 0;
}

struct cdcwdmdev {
	char *name;
	int fd;
	int cid;
};

static int qcqmi_open(const char *path, struct fuse_file_info *fi)
{
	int fd, x;
	char name[] = "/dev/cdc-wdmX";
	struct cdcwdmdev *handle;

	fprintf(stderr, "%s: path=%s\n", __func__, path);

	if (strncmp("/qcqmi", path, 6))
		return -EINVAL;

	x = strtoul(path + 6, NULL, 10);
	if (x > 9)
		return -EINVAL;
	sprintf(name, "/dev/cdc-wdm%u", x);

	fd = open(name, fi->flags);
	if (fd < 0) {
		fprintf(stderr, "%s: open(%s) returned %d, errno=%d\n", __func__, name, fd, errno);
		return -errno;
	}

	handle = malloc(sizeof(struct cdcwdmdev));
	handle->name = strdup(name);
	handle->fd = fd;
	handle->cid = -1; /* invalid */

	fi->nonseekable = 1;
	fi->fh = (uint64_t)handle;

	return 0;
}

static int qcqmi_release(const char *path, struct fuse_file_info *fi)
{
	struct cdcwdmdev *handle = (void *)fi->fh;

	fprintf(stderr, "%s: path=%s\n", __func__, path);

	fi->fh = (uint64_t)NULL;
	close(handle->fd);
	free(handle->name);
	free(handle);
	return 0;
}


static int qcqmi_read(const char *path, char *buf, size_t size, off_t offset,
		      struct fuse_file_info *fi)
{
	struct cdcwdmdev *handle = (void *)fi->fh;

	fprintf(stderr, "%s: path=%s, proxying to %s\n", __func__, path, handle->name);
	return 0;
}

static int qcqmi_write(const char *path, const char *buf, size_t size, off_t offset,
 		       struct fuse_file_info *fi)
{
	struct cdcwdmdev *handle = (void *)fi->fh;

	fprintf(stderr, "%s: path=%s, proxying to %s\n", __func__, path, handle->name);
	
	return size;
}

static int qcqmi_ioctl(const char *path, int cmd, void *arg,
		       struct fuse_file_info *fi, unsigned int flags, void *data)
{
	struct cdcwdmdev *handle = (void *)fi->fh;

	fprintf(stderr, "%s: path=%s, proxying to %s\n", __func__, path, handle->name);
	return  -EBADRQC;
}

static int qcqmi_chmod(const char *path, mode_t mode)
{
	fprintf(stderr, "%s: path=%s, mode=%x\n", __func__, path, mode);
	return 0;
}


static int qcqmi_chown(const char *path, uid_t uid, gid_t gid)
{
	fprintf(stderr, "%s: path=%s, uid=%u, gid=%u\n", __func__, path, uid, gid);
	return 0;
}

static int qcqmi_utimens(const char *path, const struct timespec tv[2])
{
	fprintf(stderr, "%s: path=%s, tv[0].tv_sec=%lu, tv[1].tv_sec=%lu\n", __func__, path, tv[0].tv_sec, tv[1].tv_sec);
	return 0;
}

/* must implement truncate to be able to write to an arbitrary offset */
static int qcqmi_truncate(const char *path, off_t offset)
{
	fprintf(stderr, "%s: path=%s, offset=%lx\n", __func__, path, offset);
	return 0;
}

static struct fuse_operations qcqmi_oper = {
	.getattr	= qcqmi_getattr,
	.readdir	= qcqmi_readdir,
	.open		= qcqmi_open,
	.release        = qcqmi_release,
	.read		= qcqmi_read,
	.write          = qcqmi_write,
	.ioctl          = qcqmi_ioctl,
//	.chown          = qcqmi_chown,
//	.chmod          = qcqmi_chmod,
//	.utimens        = qcqmi_utimens,
	.truncate       = qcqmi_truncate,
};

int main(int argc, char *argv[])
{
	/* run file system */
	return fuse_main(argc, argv, &qcqmi_oper, NULL);
}
