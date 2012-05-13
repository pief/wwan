#!/usr/bin/perl
# Copyright 2012 Bjørn Mork <bjorn@mork.no>
# License: GPLv2

use strict;
use warnings;
use Getopt::Long;
use Device::USB;
use Data::Dumper;

# defaults
my %opt = (
    'verbose' => 1, 
    'debug' => 0, 
);

GetOptions(\%opt,
	   'vid=s',
	   'pid=s',
	   'if=s',
	   'debug|d+',
	   'verbose',
	   'help|h|?',
    );

&usage if ($opt{'help'} || !$opt{'vid'} || !$opt{'pid'});

my %sysname = (
    0    => "QMI_CTL",
    1    => "QMI_WDS",
    2    => "QMI_DMS",
    3    => "QMI_NAS",
    4    => "QMI_QOS",
    5    => "QMI_WMS",
    6    => "QMI_PDS",
    7    => "QMI_AUTH",
    8    => "QMI_AT",
    9    => "QMI_VOICE",
    0xa  => "QMI_CAT",
    0xb  => "QMI UIM",
    0xc  => "QMI PBM",
    0x10 => "QMI_LOC",
    0x11 => "QMI_SAR",
    0xe0 => "QMI_CAT", # duplicate!
    0xe1 => "QMI_RMS",
    0xe2 => "QMI_OMA",
    );

my $usb = Device::USB->new();
$usb->debug_mode($opt{'debug'});

my $dev = $usb->find_device(hex($opt{'vid'}), hex($opt{'pid'}));
die "Cannot find any such device: $opt{'vid'}:$opt{'pid'}\n" unless $dev;

warn "Device: ", sprintf("%04x:%04x", $dev->idVendor(), $dev->idProduct()), "\n" if $opt{'verbose'};

$dev->open();

my $cfg = $dev->config()->[0];

# cannot use ifnum as array idx as the numbering may not be consecutive...
my @intflist = grep { !$opt{'if'} || $_->[0]->bInterfaceNumber == $opt{'if'} } @{$cfg->interfaces()};
warn Dumper(\@intflist) if $opt{'debug'};

foreach (@intflist) {
    my $intf = $_->[0];
  
    # supported interfaces must have an interrupt endpoint and may have 2 bulk endpoints
    if ($intf->bNumEndpoints == 3) {
	warn "Candidate: ifnum=", $intf->bInterfaceNumber,"\n";
	&do_qmi($dev, $intf);
    } else {
	warn "Unsupported endpoint configuration on ifnum=", $intf->bInterfaceNumber,"\n";
    }
}


sub do_qmi {
    my ($dev, $intf) = @_;

    my $ifnum = $intf->bInterfaceNumber;
    if ($dev->claim_interface($ifnum) < 0) {
	warn "claim_interface failed for if $ifnum - need to unbind first?\n";
	return;
    }

    # QMI_CTL_MESSAGE_GET_VERSION_INFO
    my $qmi = pack("C*", map { hex } qw!01 0b 00 00 00 00 00 08 21 00 00 00!);
    &send_msg($dev, $ifnum, $qmi, length($qmi));

    # may have to skip a few unsolicted messages
    for (my $i = 0; $i < 10; $i++) {
	my ($len, $msg) = &recv_msg($dev, $ifnum);
	last if ($len < 0); # no need to repeat if complete failure
	last if ($len && &is_ver($msg, $len));
	# just give the device "enough time"...
	sleep(.5);
    }
    $dev->release_interface($ifnum);
}

#map { warn "num: ", $_->bInterfaceNumber(), "eps: ", $_->nNumEndpoints(), "\n" } @{$cfg->interfaces()};

# test if msg is a reply to a QMI_CTL_MESSAGE_GET_VERSION_INFO and print details if it is
sub is_ver {
    my ($msg, $len) = @_;

    warn sprintf "%02x " x length($msg) . "\n", unpack("C*", $msg) if $opt{'debug'};

    my $ret = {};
    @$ret{'tf','len','ctrl','sys','cid','flags','tid','msgid','tlvlen'} = unpack("CvCCCCCvv", $msg);

    # sanity check: tf is always one, sys must be QMI_CTL
    return undef unless ($ret->{tf} == 1 && $ret->{sys} == 0);

    # only interested in QMI_CTL_MESSAGE_GET_VERSION_INFO
    return undef unless ($ret->{'msgid'} == 0x0021);

    # add the tlv(s)
    my $tlvlen = $ret->{'tlvlen'};
    my $tlvs = substr($msg, 12);
    while ($tlvlen > 0) {
	my ($tlv, $len) = unpack("Cv", $tlvs);
	$ret->{'tlvs'}{$tlv} = substr($tlvs, 3, $len);
	$tlvlen -= $len + 3;
	$tlvs = substr($tlvs, $len + 3);
    }

    # success only if TLV 0x02 is 0 and TLV 0x01 exists
    return undef unless ((unpack("V", $ret->{'tlvs'}{0x02}) == 0) && exists($ret->{'tlvs'}{0x01}));

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

    return 1;
}


# send CDC encapsulated message to interface
sub send_msg {
    my ($dev, $ifnum, $msg, $len) = @_;
    my $ret = $dev->control_msg(0x21,   # USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE
				0,      # CDC SEND_ENCAPSULATED_COMMAND
				0,      # zero
				$ifnum, # wIndex = interface
				$msg,
				$len,
				1000);  # timeout in ms

    warn "control_msg() returned $ret\n" if $opt{'debug'};
    if ($ret != $len) {
	warn "Failed to send message - control_msg() returned $ret\n";
    }
    return $ret;
}

# recv CDC encapsulated message to interface
sub recv_msg {
    my ($dev, $ifnum) = @_;
    my $buf = 0 x 512; # pre-allocate buffer - libusb is not perl!
    my $ret = $dev->control_msg(0xa1,   # USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE
				1,      # CDC GET_ENCAPSULATED_RESPONSE
				0,      # zero
				$ifnum, # wIndex = interface
				$buf,
				512,
				1000);  # timeout in ms
    warn "control_msg() returned $ret\n" if $opt{'debug'};
    return ($ret, $buf);
}


sub usage {
    warn <<EOT
      Usage:
	$0 [--verbose] [--debug] --vid=<idVendor> --pid=<idProduct> [--if=<bInterfaceNumber>]

      Example:
	$0 --vid=1199 --pid=68a2 --if=8

      Note:
	It is necessary to unbind any driver from the interface(s)
	before testing.  This can be done by unloading the driver
	or writing to the driver's "unbind" file:

         # echo 2-4:1.8 > /sys/bus/usb/devices/2-4:1.8/driver/unbind


EOT
;
    exit 0;
}
