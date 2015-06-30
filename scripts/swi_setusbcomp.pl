#!/usr/bin/perl
# Copyright (c) 2015  Bjørn Mork <bjorn@mork.no>
# GPLv2

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use Encode;
use Devel::SimpleTrace;
use UUID::Tiny ':std';

my $maxctrl = 4096; # default, will be overridden by ioctl if supported
my $mgmt = "/dev/cdc-wdm0";
my $debug;

GetOptions(
    'device=s' => \$mgmt,
    'debug!' => \$debug,
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

    if ($debug) {
	my $n = length($buf);
	warn("[" . localtime . "] sending $n bytes to $mgmt\n");
	print "\n---\n";
	printf "%02x " x $n, unpack("C*", $buf);
	print "\n---\n";
    }

    return $buf;
}

# MBIM_CLOSE_MSG
sub mk_close_msg {
    my $buf = &init_msg_header(2); # MBIM_CLOSE_MSG  

    if ($debug) {
	my $n = length($buf);
	warn("[" . localtime . "] sending $n bytes to $mgmt\n");
	print "\n---\n";
	printf "%02x " x $n, unpack("C*", $buf);
	print "\n---\n";
    }

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

    if ($debug) {
	my $n = length($buf);
	warn("[" . localtime . "] sending $n bytes to $mgmt\n");
	print "\n---\n";
	printf "%02x " x $n, unpack("C*", $buf);
	print "\n---\n";
    }
    return $buf;
}

sub decode_mbim {
    my $msg = shift;
    my ($type, $len, $tid) = unpack("VVV", $msg);

    print "MBIM_MESSAGE_HEADER\n";
    printf "  MessageType:\t0x%08x\n", $type;
    printf "  MessageLength:\t%d\n", $len;
    printf "  TransactionId:\t%d\n", $tid;
    if ($type == 0x80000001 || $type == 0x80000002) { # MBIM_OPEN_DONE ||  MBIM_CLOSE_DONE 
	my $status = unpack("V", substr($msg, 12));
	printf "  Status:\t0x%08x\n", $status;
    } elsif ($type == 0x80000003) { # MBIM_COMMAND_DONE 
	my ($total, $current) = unpack("VV", substr($msg, 12)); # FragmentHeader  
	print "MBIM_FRAGMENT_HEADER\n";
	printf "  TotalFragments:\t0x%08x\n", $total;
	printf "  CurrentFragment:\t0x%08x\n", $current;

	my $uuid = uuid_to_string(substr($msg, 20, 16));
	my $service = &uuid_to_service($uuid);
	print "$service ($uuid)\n";

	my ($cid, $status, $infolen) = unpack("VVV", substr($msg, 36));
	my $info = substr($msg, 48);
	printf "  CID:\t0x%08x\n", $cid;
	printf "  Status:\t0x%08x\n", $status;
	print "InformationBuffer [$infolen]:\n";
	if ($infolen != length($info)) {
	    print "Fragmented data is not supported\n";
	} elsif ($service eq "EXT_QMUX") {
	    print Dumper(&decode_qmi($info));
	}
	# silently ignoring InformationBuffer payload of other services
    }
    # ignoring all other types of MBIM messages
}

### QMI helpers ###

use constant {
    QMI_CTL => 0x00,
    QMI_WDS => 0x01,
    QMI_DMS => 0x02,
    QMI_NAS => 0x03,
    QMI_WMS => 0x05,
    QMI_PDS => 0x06,
    QMI_LOC => 0x10,
};

# $tlvs = { type1 => packdata, type2 => packdata, .. 
sub mk_qmi {
    my ($sys, $cid, $msgid, $tlvs) = @_;

    # create tlvbytes
    my $tlvbytes = '';
    foreach my $tlv (keys %$tlvs) {
	$tlvbytes .= pack("Cv", $tlv, length($tlvs->{$tlv})) . $tlvs->{$tlv};
    }
    my $tlvlen = length($tlvbytes);
    if ($sys != QMI_CTL) {
	return pack("CvCCCCvvv", 1, 12 + $tlvlen, 0, $sys, $cid, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    } else {
	return pack("CvCCCCCvv", 1, 11 + $tlvlen, 0, QMI_CTL, 0, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    }
}

sub decode_qmi {
    my $packet = shift;
    return {} unless $packet;

    printf "%02x " x length($packet) . "\n", unpack("C*", $packet) if $debug;

    my $ret = {};
    @$ret{'tf','len','ctrl','sys','cid'} = unpack("CvCCC", $packet);
    return {} unless ($ret->{tf} == 1);

    # tid is 1 byte for QMI_CTL and 2 bytes for the others...
    @$ret{'flags','tid','msgid','tlvlen'} = unpack($ret->{sys} == QMI_CTL ? "CCvv" : "Cvvv" , substr($packet, 6));
    my $tlvlen = $ret->{'tlvlen'};
    my $tlvs = substr($packet, $ret->{'sys'} == QMI_CTL ? 12 : 13 );

    # add the tlvs
     while ($tlvlen > 0) {
	my ($tlv, $len) = unpack("Cv", $tlvs);
	$ret->{'tlvs'}{$tlv} = [ unpack("C*", substr($tlvs, 3, $len)) ];
	$tlvlen -= $len + 3;
	$tlvs = substr($tlvs, $len + 3);
     }
    return $ret;
}

### main ###

# open device now and keep it open until exit
open(F, "+<", $mgmt) || die "open $mgmt: $!\n";
autoflush F 1;

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

print F &mk_open_msg;
# wait for OPEN


# test QMI

# FIXME:  simpler to import a QMI encoder, than to manually fix up all these static arrays. And so much more readable...

# QMI_CTL_MESSAGE_GET_VERSION_INFO
print F &mk_command_msg('EXT_QMUX', 1, 1, &mk_qmi(0, 0, 0x0021, { 0x01 => 0xff }));

# wait for response (and decode?)

# allocate a DMS CID (or just reuse the one allocated by the MBIM firmware application?)
# QMI_CTL_GET_CLIENT_ID, TLV 0x01 => 2 (DMS)
print F &mk_command_msg('EXT_QMUX', 1, 1, &mk_qmi(0, 0, 0x0022, { 0x01 => 2 }));

# wait for response and decode
# => $dmscid


#QMI_DMS_SWI_SETUSBCOMP (or whatever)

# get USB comp = 0x555B
# set USB comp = 0x555C
# "Set FCC Authentication" =  0x555F
##print F &mk_command_msg('EXT_QMUX', 1, 1,  &mk_qmi(2, $dmscid, 0x555c, { 0x01 => $usbcomp}));
# wait for response and decode

#let's test a get first, eh?
print F &mk_command_msg('EXT_QMUX', 1, 1,  &mk_qmi(2, $dmscid, 0x555b));
# wait for response and decode

# release DMS CID
# QMI_CTL_RELEASE_CLIENT_ID
print F &mk_command_msg('EXT_QMUX', 1, 1, &mk_qmi(0, 0, 0x0022, { 0x01 =>  pack("C*", 2, $dmscid)}));
# wait for response and decode

print F &mk_close_msg;
# wait for response, close and exit

# close device
close(F);



sub usage {
    print STDERR <<EOH
Usage: $0 [options]  

Where [options] are


EOH
    ;
    exit;
}
