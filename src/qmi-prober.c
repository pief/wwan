/*
 *  Copyright 2012 Bjørn Mork <bjorn@mork.no>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License.
 */

#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <getopt.h>
#include <string.h>
#include <libusb.h>
#include <linux/types.h>

/* dump device info */
static void print_usb_device(libusb_device_handle *handle)
{
	libusb_device *dev;
	struct libusb_device_descriptor desc;
	int err;

	dev = libusb_get_device(handle);
	if (dev == NULL)
		return;

	err = libusb_get_device_descriptor(dev, &desc);
	if (err)
		return;

	printf("bLength=%d\nbDescriptorType=%d\nbDeviceClass=%x\nidVendor=%04x\nidProduct=%04x\n",
		desc.bLength, desc.bDescriptorType, desc.bDeviceClass, desc.idVendor, desc.idProduct);
}

/* open the given device */
static libusb_device_handle *open_device(char *device)
{
	uint16_t vendor_id = 0, product_id = 0;

	if ((sscanf(device, " %hx : %hx ", &vendor_id, &product_id) != 2) || (vendor_id == 0) || (product_id == 0))
		return NULL;

	return libusb_open_device_with_vid_pid(NULL, vendor_id, product_id);
}

static int read_reply(libusb_device_handle *handle, int interface, char *buf, int size)
{
	int ret;

        ret = libusb_control_transfer(handle, 
				LIBUSB_ENDPOINT_IN + LIBUSB_REQUEST_TYPE_CLASS + LIBUSB_RECIPIENT_INTERFACE,  /* 0xa1 */
				1, /* CDC GET_ENCAPSULATED_RESPONSE */
				0, /* zero */
				interface, /* wIndex = interface */
				buf,
				size,
				1000);

	if (ret >= (int)sizeof(struct qmux)) {
		fprintf(stderr, "\n== %s() returned %d bytes ==\n", __FUNCTION__, ret);
		dump_qmux(buf);
	}

	fprintf(stderr, "%s: libusb_control_transfer() returned %d\n",  __FUNCTION__, ret);
	return ret;
}

/* send control message to the device */
static int send_msg(libusb_device_handle *handle, int interface, char *buf, int size)
{
	int ret;

	fprintf(stderr, "\n== %s() ==\n", __FUNCTION__);
	dump_qmux(buf);

        ret = libusb_control_transfer(handle, 
				LIBUSB_REQUEST_TYPE_CLASS + LIBUSB_RECIPIENT_INTERFACE,  /* 0x21 */
				0, /* CDC SEND_ENCAPSULATED_COMMAND */ 
				0, /* zero */
				interface, /* wIndex = interface */
				buf,
				size,
				1000);
	fprintf(stderr, "%s: libusb_control_transfer() returned %d\n", __FUNCTION__, ret);
	return ret;
}

static struct option main_options[] = {
	{ "help",	0, 0, 'h' },
	{ 0, 0, 0, 0 }
};


void usage(char *prog)
{
	fprintf(stderr, "Usage: %s vid:pid\n\n", prog);
}

int main(int argc, char *argv[])
{
	char *prog, *device = NULL;
	int i, opt, ret, interface;
	libusb_device_handle *handle;
	char buf[500];
	int size = sizeof(buf), len;
	unsigned char cid = 0;

	prog = argv[0];
	while ((opt = getopt_long(argc, argv, "h", main_options, NULL)) != -1) {
		switch(opt) {
		case 'h':
			usage(prog);
			exit(0);
		}
	}

	if (optind >= argc) {
		usage(prog);
		exit(0);
	}

	device = strdup(argv[optind]);

	if (ret = libusb_init(NULL)) {
		fprintf(stderr, "libusb_init() failed: %d\n", ret);
		exit(1);
	}
	
	if (handle = open_device(device)) {

		/* FIXME: for each interface:
 		   - ignore if bound
		   - ignore unless containing interrupt endpoint (and either bulk in+out or nothing else?)
		*/
		
		ret = libusb_claim_interface (handle, interface);

		/* just send a static release cid=0 for system=255 to trigger a
		   QMI_ERR_INVALID_SERVICE_TYPE error
		*/
		unsigned char req[0x11] = { 0x01,	// .tf (always 1)
					    0x10, 0x00, // .len (excl .tf)
					    0x00,	// .ctrl (control point)
					    0x00,	// .service (QMI_CTL)
					    0x00,	// .cid (irrelevant for QMI_CTL)
					    0x00,	// .flags
					    0x00,	// .txid (don't care)
					    0x23, 0x00, // .msgid
					    0x05, 0x00, // .len
					    0x01,	// .tlvid
					    0x02, 0x00, // .tlvlen
					    0xff, 	// .tlv[0] == system (0xff does not exist)
					    0x0,	// .tlv[1] == cid (0 is impossible)
		};

		/* the expected static reply to the above request is: */
		unsigned char reply[0x13] = { 0x01,		// .tf (always 1)
					      0x12, 0x00,	// .len (excl .tf)
					      0x80,		// .ctrl (service)
					      0x00,		// .service (QMI_CTL)
					      0x00,		// .cid (irrelevant for QMI_CTL)
					      0x01,		// .flags (QMI_CTL response)
					      0x00,		// .txid
					      0x23, 0x00, 	// .msgid
					      0x07, 0x00, 	// .len
					      0x02,		// .tlvid
					      0x04, 0x00, 	// .tlvlen
					      0x01, 0x00,	// FAILED
					      0x1f, 0x00,	// QMI_ERR_INVALID_SERVICE_TYPE
		};

		print_usb_device(handle);

		i = send_msg(handle, interface, req, sizeof(req));

		/* should repeat a few times to flush pending unsolicted messages */
		sleep(2); /* just wait enough */
		i = read_reply(handle, interface, buf, size);

		ret = libusb_release_interface(handle, interface);
	} else {
		fprintf(stderr, "failed to open device \"%s\"\n", device);
	}
		
	libusb_exit(NULL);
}
