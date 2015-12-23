#!/usr/bin/perl
# Copyright (c) 2015  Bjørn Mork <bjorn@mork.no>
# GPLv2

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use UUID::Tiny ':std';
use IPC::Shareable;
use Fcntl ':mode';
use File::Basename;
use JSON;
use Time::HiRes qw (sleep);

my $maxctrl = 4096; # default, will be overridden by ioctl if supported
my $mgmt = "/dev/cdc-wdm0";
my $reset;
my $debug;
my $verbose = 1;
my $usbcomp;
 
# a few global variables
my $msgs;
my $dmscid;
my $tid = 1;

# defaulting to MBIM mode
my $mbim = 1;

GetOptions(
    'usbcomp=i' => \$usbcomp,
    'device=s' => \$mgmt,
    'reset!' => \$reset,
    'debug!' => \$debug,
    'verbose!' => \$verbose,
    'help|h|?' => \&usage,
    ) || &usage;


### MBIM helpers ###
sub _push {
    my ($buf, $format, @vars) = @_;

    my $add = pack($format, @vars);
    $buf .= $add;

    # update length
    my $len = unpack("V", substr($buf, 4, 4));
    $len += length($add);
    substr($buf, 4, 4) = pack("V", $len);
    return $buf;
}

sub _pop {
    my ($buf, $format, @vars) = @_;

    (@vars) = unpack($format, $buf);
    my $x = pack($format, @vars);
    return $buf .= pack($format, @vars);
}

my %msg = (
# Table 9‐3: Control messages sent from the host to the function 
    'MBIM_OPEN_MSG' => 1,
    'MBIM_CLOSE_MSG' => 2,
    'MBIM_COMMAND_MSG' => 3,
    'MBIM_HOST_ERROR_MSG' => 4, 

# Table 9‐9: Control Messages sent from function to host 
    'MBIM_OPEN_DONE' => 0x80000001,
    'MBIM_CLOSE_DONE' => 0x80000002,
    'MBIM_COMMAND_DONE' => 0x80000003,
    'MBIM_FUNCTION_ERROR_MSG' => 0x80000004,
    'MBIM_INDICATE_STATUS_MSG' => 0x80000007, 
    );

# Table 10‐3: Services Defined by MBIM 
my %uuid = (
    UUID_BASIC_CONNECT => 'a289cc33-bcbb-8b4f-b6b0-133ec2aae6df',
    UUID_SMS           => '533fbeeb-14fe-4467-9f90-33a223e56c3f',
    UUID_USSD          => 'e550a0c8-5e82-479e-82f7-10abf4c3351f',
    UUID_PHONEBOOK     => '4bf38476-1e6a-41db-b1d8-bed289c25bdb',
    UUID_STK           => 'd8f20131-fcb5-4e17-8602-d6ed3816164c',
    UUID_AUTH          => '1d2b5ff7-0aa1-48b2-aa52-50f15767174e',
    UUID_DSS           => 'c08a26dd-7718-4382-8482-6e0d583c4d0e',

# "well known" vendor specific services
    UUID_EXT_QMUX      => 'd1a30bc2-f97a-6e43-bf65-c7e24fb0f0d3', # ref unknown...
    UUID_MULTICARRIER  => '8b569648-628d-4653-9b9f-1025404424e1', # ref http://feishare.com/attachments/article/252/implementing-multimode-multicarrier-devices.pdf
    UUID_MSFWID        => 'e9f7dea2-feaf-4009-93ce-90a3694103b6', # http://msdn.microsoft.com/en-us/library/windows/hardware/jj248721.aspx
    UUID_MS_HOSTSHUTDOWN => '883b7c26-985f-43fa-9804-27d7fb80959c', # http://msdn.microsoft.com/en-us/library/windows/hardware/jj248720.aspx

    );

sub uuid_to_service {
    my $uuid = shift;
    my ($service) = grep { $uuid{$_} eq $uuid } keys %uuid;
    return 'UNKNOWN' unless $service;
    $service =~ s/^UUID_//;
    return $service;
}

# MBIM_MESSAGE_HEADER 
sub init_msg_header {
    my $type = shift;
    return &_push('', "VVV", $type, 0, $tid++);
}

# MBIM_FRAGMENT_HEADER 
sub push_fragment_header {
    my ($buf, $total, $current) = @_;
    return $buf = &_push($buf, "VV", $total, $current);
}

# MBIM_OPEN_MSG
sub mk_open_msg {
    my $buf = &init_msg_header(1); # MBIM_OPEN_MSG  
    $buf = &_push($buf, "V", $maxctrl); # MaxControlTransfer 

    printf "MBIM>: " . "%02x " x length($buf) . "\n", unpack("C*", $buf) if $debug;
    return $buf;
}

# MBIM_CLOSE_MSG
sub mk_close_msg {
    my $buf = &init_msg_header(2); # MBIM_CLOSE_MSG  

    printf "MBIM>: " . "%02x " x length($buf) . "\n", unpack("C*", $buf) if $debug;
    return $buf;
}

# MBIM_COMMAND_MSG  
sub mk_command_msg {
    my ($service, $cid, $type, $info) = @_;

    my $uuid = string_to_uuid($uuid{"UUID_$service"} || $service) || return '';
    my $buf = &init_msg_header(3); # MBIM_COMMAND_MSG  
    $buf = &push_fragment_header($buf, 1, 0);
    $uuid =~ tr/-//d;
    $buf = &_push($buf, "a*", $uuid); # DeviceServiceId  
    $buf = &_push($buf, "VVV",
		  $cid,    # CID
		  $type,   # 0 for a query operation, 1 for a Set operation. 
		  length($info), # InformationBufferLength  
	);
    $buf = &_push($buf, "a*", $info);  # InformationBuffer  
    printf "MBIM>: " . "%02x " x length($buf) . "\n", unpack("C*", $buf) if $debug;
    return $buf;
}

sub decode_mbim {
    my $msg = shift;
    my ($type, $len, $tid) = unpack("VVV", $msg);

    if ($debug) {
	print "MBIM_MESSAGE_HEADER\n";
	printf "  MessageType:\t0x%08x\n", $type;
	printf "  MessageLength:\t%d\n", $len;
	printf "  TransactionId:\t%d\n", $tid;
    }
    if ($type == 0x80000001 || $type == 0x80000002) { # MBIM_OPEN_DONE ||  MBIM_CLOSE_DONE 
	my $status = unpack("V", substr($msg, 12));
	printf "  Status:\t0x%08x\n", $status if $debug;
	# save message type
	push(@$msgs, { status => $type, index => scalar @$msgs, });
    } elsif ($type == 0x80000003) { # MBIM_COMMAND_DONE 
	my ($total, $current) = unpack("VV", substr($msg, 12)); # FragmentHeader  
	if ($debug) {
	    print "MBIM_FRAGMENT_HEADER\n";
	    printf "  TotalFragments:\t0x%08x\n", $total;
	    printf "  CurrentFragment:\t0x%08x\n", $current;
	}
	my $uuid = uuid_to_string(substr($msg, 20, 16));
	my $service = &uuid_to_service($uuid);
	print "$service ($uuid)\n"  if $debug;

	my ($cid, $status, $infolen) = unpack("VVV", substr($msg, 36));
	my $info = substr($msg, 48);
	if ($debug) {
	    printf "  CID:\t\t0x%08x\n", $cid;
	    printf "  Status:\t0x%08x\n", $status;
	    print "InformationBuffer [$infolen]:\n";
	}
	if ($infolen != length($info)) {
	    print "Fragmented MBIM transactions are not supported\n";
	} elsif ($service eq "EXT_QMUX") {
	    # save the decoded QMI message
	    my $lastqmi = &decode_qmi($info);
	    # save message
	    push(@$msgs, { status => 0, index => scalar @$msgs, qmi => $lastqmi}) if $lastqmi;
	}
	# silently ignoring InformationBuffer payload of other services
    }
    # ignoring all other types of MBIM messages
}

# read from F until timeout
sub reader {
    my $timeout = shift || 0;

    eval {
	local $SIG{ALRM} = sub { die "timeout\n" };
	local $SIG{TERM} = sub { die "close\n" };
	my $raw = '';
	my $msglen = 0;
	alarm $timeout;
	do {
	    my $len = 0;
	    if ($len < 3 || $len < $msglen) {
		my $tmp;
		my $n = sysread(F, $tmp, $maxctrl);
		if ($n) {
		    $len = $n;
		    $raw = $tmp;
		    printf "%s<: " . "%02x " x $n . "\n", $mbim ? "MBIM" : "QMI", unpack("C*", $tmp) if $debug;
		} else {
		    die "eof\n";
		}
	    }

	    # get expected message length
	    if ($mbim) {
		$msglen = unpack("V", substr($raw, 4, 4));
	    } else {
		$msglen = unpack("v", substr($raw, 1, 2)) + 1;
	    }

	    if ($len >= $msglen) {
		$len -= $msglen;

		if ($mbim) {
		    &decode_mbim(substr($raw, 0, $msglen));
		    die "close\n" if (grep { $_->{status} == 0x80000002 } @$msgs); # exit on CLOSE_DONE
		} else {
		    my $lastqmi = &decode_qmi(substr($raw, 0, $msglen));
		    push(@$msgs, { status => 0, index => scalar @$msgs, qmi => $lastqmi}) if $lastqmi;
		}
		$raw = substr($raw, $msglen);
		$msglen = 0;
	    } else {
		warn "$len < $msglen\n";
	    }
	} while (1);
	alarm 0;
    };
    if ($@) {
	die unless $@ =~ /^close/;   # propagate unexpected errors
    }
}

### QMI helpers ###

my %sysname = (
	0x00 => "QMI_CTL",	# Control service
	0x01 => "QMI_WDS",	# Wireless data service
	0x02 => "QMI_DMS",	# Device management service
	0x03 => "QMI_NAS",	# Network access service
	0x04 => "QMI_QOS",	# Quality of service, err, service 
	0x05 => "QMI_WMS",	# Wireless messaging service
	0x06 => "QMI_PDS",	# Position determination service
	0x07 => "QMI_AUTH",	# Authentication service
	0x08 => "QMI_AT",	# AT command processor service
	0x09 => "QMI_VOICE",	# Voice service
	0x0a => "QMI_CAT2",	# Card application toolkit service (new)
	0x0b => "QMI_UIM",	# UIM service
	0x0c => "QMI_PBM",	# Phonebook service
	0x0d => "QMI_QCHAT",	# QCHAT Service
	0x0e => "QMI_RMTFS",	# Remote file system service
	0x0f => "QMI_TEST",	# Test service
	0x10 => "QMI_LOC",	# Location service 
	0x11 => "QMI_SAR",	# Specific absorption rate service
	0x12 => "QMI_IMSS",	# IMS settings service
	0x13 => "QMI_ADC",	# Analog to digital converter driver service
	0x14 => "QMI_CSD",	# Core sound driver service
	0x15 => "QMI_MFS",	# Modem embedded file system service
	0x16 => "QMI_TIME",	# Time service
	0x17 => "QMI_TS",	# Thermal sensors service
	0x18 => "QMI_TMD",	# Thermal mitigation device service
	0x19 => "QMI_SAP",	# Service access proxy service
	0x1a => "QMI_WDA",	# Wireless data administrative service
	0x1b => "QMI_TSYNC",	# TSYNC control service 
	0x1c => "QMI_RFSA",	# Remote file system access service
	0x1d => "QMI_CSVT",	# Circuit switched videotelephony service
	0x1e => "QMI_QCMAP",	# Qualcomm mobile access point service
	0x1f => "QMI_IMSP",	# IMS presence service
	0x20 => "QMI_IMSVT",	# IMS videotelephony service
	0x21 => "QMI_IMSA",	# IMS application service
	0x22 => "QMI_COEX",	# Coexistence service
	0x23 => "QMI_RESERVED_35",	# Reserved
	0x24 => "QMI_PDC",	# Persistent device configuration service
	0x25 => "QMI_RESERVED_37",	# Reserved
	0x26 => "QMI_STX",	# Simultaneous transmit service
	0x27 => "QMI_BIT",	# Bearer independent transport service
	0x28 => "QMI_IMSRTP",	# IMS RTP service
	0x29 => "QMI_RFRPE",	# RF radiated performance enhancement service
	0x2a => "QMI_DSD",	# Data system determination service
	0x2b => "QMI_SSCTL",	# Subsystem control service
	0xe0 => "QMI_CAT",	# Card application toolkit service
	0xe1 => "QMI_RMS",	# Remote management service
    );

# dumped from GobiAPI_2013-07-31-1347/GobiConnectionMgmt/GobiConnectionMgmtAPIEnums.h
# using
# perl -e 'while (<>){ if (m!eQMI_SVC_([^,]*),\s*//\s*(\d+)\s(.*)!) { my $svc = $1; $svc = "CTL" if ($svc eq "CONTROL"); my $num = $2; my $descr = $3; printf "\t0x%02x => \"$descr\",\n", $num; } }' < /tmp/xx
my %sysdescr = (
	0x00 => "Control service",
	0x01 => "Wireless data service",
	0x02 => "Device management service",
	0x03 => "Network access service",
	0x04 => "Quality of service, err, service ",
	0x05 => "Wireless messaging service",
	0x06 => "Position determination service",
	0x07 => "Authentication service",
	0x08 => "AT command processor service",
	0x09 => "Voice service",
	0x0a => "Card application toolkit service (new)",
	0x0b => "UIM service",
	0x0c => "Phonebook service",
	0x0d => "QCHAT Service",
	0x0e => "Remote file system service",
	0x0f => "Test service",
	0x10 => "Location service ",
	0x11 => "Specific absorption rate service",
	0x12 => "IMS settings service",
	0x13 => "Analog to digital converter driver service",
	0x14 => "Core sound driver service",
	0x15 => "Modem embedded file system service",
	0x16 => "Time service",
	0x17 => "Thermal sensors service",
	0x18 => "Thermal mitigation device service",
	0x19 => "Service access proxy service",
	0x1a => "Wireless data administrative service",
	0x1b => "TSYNC control service ",
	0x1c => "Remote file system access service",
	0x1d => "Circuit switched videotelephony service",
	0x1e => "Qualcomm mobile access point service",
	0x1f => "IMS presence service",
	0x20 => "IMS videotelephony service",
	0x21 => "IMS application service",
	0x22 => "Coexistence service",
	0x23 => "Reserved",
	0x24 => "Persistent device configuration service",
	0x25 => "Reserved",
	0x26 => "Simultaneous transmit service",
	0x27 => "Bearer independent transport service",
	0x28 => "IMS RTP service",
	0x29 => "RF radiated performance enhancement service",
	0x2a => "Data system determination service",
	0x2b => "Subsystem control service",
	0xe0 => "Card application toolkit service",
	0xe1 => "Remote management service",
    );

# $tlvs = { type1 => packdata, type2 => packdata, .. 
sub mk_qmi {
    my ($sys, $cid, $msgid, $tlvs) = @_;

    # create tlvbytes
    my $tlvbytes = '';
    foreach my $tlv (keys %$tlvs) {
	$tlvbytes .= pack("Cv", $tlv, length($tlvs->{$tlv})) . $tlvs->{$tlv};
    }
    my $tlvlen = length($tlvbytes);
    if ($sys != 0) {
	return pack("CvCCCCvvv", 1, 12 + $tlvlen, 0, $sys, $cid, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    } else {
	return pack("CvCCCCCvv", 1, 11 + $tlvlen, 0, 0, 0, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    }
}

sub decode_qmi {
    my $packet = shift;
    return {} unless $packet;

    #    printf "%02x " x length($packet) . "\n", unpack("C*", $packet) if $debug;

    my $ret = {};
    @$ret{'tf','len','ctrl','sys','cid'} = unpack("CvCCC", $packet);
    return {} unless ($ret->{tf} == 1);

    # tid is 1 byte for QMI_CTL and 2 bytes for the others...
    @$ret{'flags','tid','msgid','tlvlen'} = unpack($ret->{sys} == 0 ? "CCvv" : "Cvvv" , substr($packet, 6));
    my $tlvlen = $ret->{'tlvlen'};
    my $tlvs = substr($packet, $ret->{'sys'} == 0 ? 12 : 13 );

    # add the tlvs
     while ($tlvlen > 0) {
	my ($tlv, $len) = unpack("Cv", $tlvs);
	$ret->{'tlvs'}{$tlv} = [ unpack("C*", substr($tlvs, 3, $len)) ];
	$tlvlen -= $len + 3;
	$tlvs = substr($tlvs, $len + 3);
     }
    return $ret;
}

sub qmiver {
    my $qmi = shift;

    # decode the list of supported systems in TLV 0x01
    my @data = @{$qmi->{'tlvs'}{0x01}};
    my $n = shift(@data);
    my $data = pack("C*", @data);
    print "supports $n QMI subsystems:\n";
    for (my $i = 0; $i < $n; $i++) {
	my ($sys, $maj, $min) = unpack("Cvv", $data);
	printf "  0x%02x ($maj.$min)\t'%s'\t- %s\n", $sys, $sysname{$sys} || 'unknown', $sysdescr{$sys} || '';
	$data = substr($data, 5);
    }
}

sub qmiok {
    my $qmi = shift;
    return exists($qmi->{tlvs}{0x02}) && (unpack("v", pack("C*", @{$qmi->{tlvs}{0x02}}[2..3])) == 0);
}

sub do_qmi {
    my $msgid = shift;
    my $qmi = shift;
    my $timeout = shift || 15;
    
    printf "QMI>: " . "%02x " x length($qmi) . "\n", unpack("C*", $qmi) if $debug;

    if ($mbim) {
	print F &mk_command_msg('EXT_QMUX', 1, 1, $qmi);
    } else {
	print F $qmi;
    }
    my $count = 10 * $timeout; # seconds timeout
    my $msg;

    # wait for a reply, leaving all messages in the queue
    for (my $i = $timeout; $i > 0; $i--) {
	($msg) = grep { !$_->{status} && $_->{qmi}->{msgid} == $msgid } @$msgs;
	last if $msg;
	sleep(0.1);
    }
    return unless $msg;
    
    my $status = &qmiok($msg->{qmi});
    printf "QMI msg '0x%04x' returned status = $status\n", $msgid if $verbose;
    return $status ? $msg->{qmi} : undef;
}


## Sierra USB comp
my %comps = (
    0  => 'HIP  DM    NMEA  AT    MDM1  MDM2  MDM3  MS',
    1  => 'HIP  DM    NMEA  AT    MDM1  MS',
    2  => 'HIP  DM    NMEA  AT    NIC1  MS',
    3  => 'HIP  DM    NMEA  AT    MDM1  NIC1  MS',
    4  => 'HIP  DM    NMEA  AT    NIC1  NIC2  NIC3  MS',
    5  => 'HIP  DM    NMEA  AT    ECM1  MS',
    6  => 'DM   NMEA  AT    QMI',
    7  => 'DM   NMEA  AT    RMNET1 RMNET2 RMNET3',
    8  => 'DM   NMEA  AT    MBIM',
    9  => 'MBIM',
    10 => 'NMEA MBIM',
    11 => 'DM   MBIM',
    12 => 'DM   NMEA  MBIM',
    13 => 'Config1: comp6    Config2: comp8',
    14 => 'Config1: comp6    Config2: comp9',
    15 => 'Config1: comp6    Config2: comp10',
    16 => 'Config1: comp6    Config2: comp11',
    17 => 'Config1: comp6    Config2: comp12',
    18 => 'Config1: comp7    Config2: comp8',
    19 => 'Config1: comp7    Config2: comp9',
    20 => 'Config1: comp7    Config2: comp10',
    21 => 'Config1: comp7    Config2: comp11',
    22 => 'Config1: comp7    Config2: comp12',
);

### main ###


# verify that the $mgmt device is a chardev provided by the cdc_mbim driver
my ($mode, $rdev) = (stat($mgmt))[2,6];
die "'$mgmt' is not a character device\n" unless S_ISCHR($mode);
my $driver = basename(readlink(sprintf("/sys/dev/char/%u:%u/device/driver", $rdev >> 8, $rdev & 0xff)));
if ($driver eq "qmi_wwan") {
    $mbim = undef;
} elsif ($driver ne "cdc_mbim") {
    die "'$mgmt' is provided by '$driver' - only MBIM or QMI devices are supported\n";
}

print "Running in ", $mbim ? "MBIM" : "QMI", " mode (driver=$driver)\n";

# open device now and keep it open until exit
open(F, "+<", $mgmt) || die "open $mgmt: $!\n";
autoflush F 1;
autoflush STDOUT 1;

# check message size
require 'sys/ioctl.ph';
eval 'sub IOCTL_WDM_MAX_COMMAND () { &_IOC( &_IOC_READ, ord(\'H\'), 0xa0, 2); }' unless defined(&IOCTL_WDM_MAX_COMMAND);
my $foo = '';
my $r = ioctl(F, &IOCTL_WDM_MAX_COMMAND, $foo);
if ($r) {
    $maxctrl = unpack("s", $foo);
} else {
    warn("ioctl failed: $!\n") if $debug;
}
print "MaxMessageSize=$maxctrl\n"  if $debug;

# fork the reader
my $pid = fork();
if ($pid == 0) { # child
    # shared rx message queue
    tie $msgs, 'IPC::Shareable', 'msgs', { create => 1, destroy => 0 } || die "tie failed\n";
    $msgs = [];
    &reader(60); # allow up to 60 seconds for the whole transaction
    print "exiting reader\n" if $debug;
    exit 0;
} elsif (!$pid) {
    die "fork() failed: $!\n";
}

# watch reader status
tie $msgs, 'IPC::Shareable', 'msgs', { create => 1, destroy => 1 } || die "tie failed\n";
$msgs = [];

if ($mbim) {
    # send OPEN and wait until reader has seen the OPEN_DONE message
    print F &mk_open_msg;

    # flushing all messages until OPEN_DONE
    while (!grep { $_->{status} == 0x80000001 } @$msgs) {
	$msgs = [];
	sleep(1);
    }
    print "MBIM OPEN succeeded\n" if $verbose;
}

my $lastqmi;

# verify QMI channel support with QMI_CTL_MESSAGE_GET_VERSION_INFO
unless ($lastqmi = &do_qmi(0x0021, &mk_qmi(0, 0, 0x0021, { 0x01 => pack("C", 255), }))) {
    print "Failed to verify QMI ", $mbim ? "vendor specific MBIM service" : "", "\n";
    &quit;
}
print $mbim ? "MBIM " : "", "QMI support verified\n";

&qmiver($lastqmi) if $verbose;

# allocate a DMS CID (or just reuse the one allocated by the MBIM firmware application?)
# QMI_CTL_GET_CLIENT_ID, TLV 0x01 => 2 (DMS)
unless ($lastqmi = &do_qmi(0x0022, &mk_qmi(0, 0, 0x0022, { 0x01 => pack("C", 2), }))) {
    print "Failed to get QMI DMS client ID\n";
    &quit;
}
$dmscid = $lastqmi->{'tlvs'}{0x01}[1]; # save the DMS CID
print "Got QMI DMS client ID '$dmscid'\n" if $verbose;

#QMI_DMS_SWI_SETUSBCOMP (or whatever)
# get USB comp = 0x555B
# set USB comp = 0x555C
# "Set FCC Authentication" =  0x555F
##print F &mk_command_msg('EXT_QMUX', 1, 1,  &mk_qmi(2, $dmscid, 0x555c, { 0x01 => $usbcomp}));
# wait for response and decode

# always get first.  We need the list of supported settings to allow set
$lastqmi = &do_qmi(0x555b, &mk_qmi(2, $dmscid, 0x555b, {}));
&quit unless $lastqmi;
my $current = $lastqmi->{'tlvs'}{0x10}[0];
my @supported = @{$lastqmi->{'tlvs'}{0x11}};
my $count = shift(@supported);

# basic sanity:
if ($count != $#supported + 1) {
    print "ERROR: array length mismatch, $count != $#supported\n";
    print to_json(\@supported),"\n";
    &quit;
}

&quit unless (grep { $current == $_ } @supported); # verify that the current comp is supported

# dump current settings
printf "Current USB composition: %d\n", $current;
if ($verbose) {
    print "USB compositions:\n";
    for my $i (sort { $a <=> $b } keys %comps) {
	printf "%s %2i - %-48s %sSUPPORTED\n", $i == $current ? '*' : ' ', $i, $comps{$i}, (grep { $i == $_ } @supported) ? '' : 'NOT ';
    }
}

# want a new setting?
&quit unless defined($usbcomp);

# no need to change to the current setting
if ($usbcomp == $current) {
    print "Current setting is already '$usbcomp'\n";
    &quit;
}

# verify that the new setting is supported
unless (grep { $usbcomp == $_ } @supported) {
    print "USB composition '$usbcomp' is not supported\n";
    &quit;
}

# attempt to change USB comp
if (!&do_qmi(0x555c, &mk_qmi(2, $dmscid, 0x555c, { 0x01 => pack("C", $usbcomp)}))) {
    print "Failed to change USB composition to '$usbcomp'\n";
}

&quit;

sub quit {
    if ($dmscid) {
	# reset device? DMS_SET_OPERATING_MODE => RESET
	if ($reset) {
	    &do_qmi(0x0023, &mk_qmi(2, $dmscid, 0x002e, { 0x01 =>  pack("C", 4)}));
	}

	# release DMS CID
	# QMI_CTL_RELEASE_CLIENT_ID
	&do_qmi(0x0023, &mk_qmi(0, 0, 0x0023, { 0x01 =>  pack("C*", 2, $dmscid)}));
    }

    if ($mbim) {
	# send CLOSE
	print F &mk_close_msg;
    } else {
	# simply signal reader to quit
	kill 'TERM', $pid;
    }

    # wait for the reader to exit (on CLOSE_DONE)
    waitpid($pid, 0);

    close(F);

    # dump all messages received
    print Dumper($msgs) if $debug;
    
    exit 0; # will exit parent
}
    
sub usage {
    print STDERR <<EOH
Usage: $0 [options]  

Where [options] are
  --device=<dev>        use <dev> for MBIM or QMI commands (default: '$mgmt')
  --usbcomp=<num>	change USB composition setting
  --reset		issue a QMI reset request
  --debug		enable verbose debug output
  --help		this help text

  The current setting and supported modes will always be displayed
  

EOH
    ;
    exit;
}
