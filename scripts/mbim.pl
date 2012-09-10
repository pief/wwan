#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use Encode;
use Devel::SimpleTrace;
use UUID::Tiny ':std';

# per interface config
my %pin; $pin{1} = &strip_quotes($ENV{'IF_WWAN_PIN'}) if $ENV{'IF_WWAN_PIN'};
my $apn =  &strip_quotes($ENV{'IF_WWAN_APN'});

# output levels
my $verbose = 1;
my $debug = 1;

# sleep and read all rcvd messages?
my $monitor = 0;

# management device
my $mgmt = &strip_quotes($ENV{MGMT}) || "/dev/cdc-wdm0";

### functions used during enviroment variable parsing ###
sub usage {
    print STDERR <<EOH
Usage: $0 [options]  open|pin|close|monitor

Where [options] are

  --device=<cdc-wdm> (defaults to $mgmt)
  --pin=<code>
  --apn=<apn>
  --[no]verbose
  --[no]debug

EOH
    ;
    exit;
}


sub strip_quotes {
    my $x = shift;
    $x =~ s/"([^"]*)"/$1/ if $x;
    return $x;
}

## let command line override defaults
GetOptions(
    'device=s' => \$mgmt,
    'pin=s' => \$pin{1},
    'apn=s' => \$apn,
    'verbose!' => \$verbose,
    'debug!' => \$debug,
    'help|h|?' => \&usage,
    ) || &usage;

# the rest of the command line is left for the actual command to run
# network device is required
&usage unless $mgmt;

# internal state
my $tid = 1;		# transaction id
    

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

my %uuid = (
    UUID_BASIC_CONNECT => 'a289cc33-bcbb-8b4f-b6b0-133ec2aae6df',
    UUID_SMS           => '533fbeeb-14fe-4467-9f90-33a223e56c3f',
    UUID_USSD          => 'e550a0c8-5e82-479e-82f7-10abf4c3351f',
    UUID_PHONEBOOK     => '4bf38476-1e6a-41db-b1d8-bed289c25bdb',
    UUID_STK           => 'd8f20131-fcb5-4e17-8602-d6ed3816164c',
    UUID_AUTH          => '1d2b5ff7-0aa1-48b2-aa52-50f15767174e',
    UUID_DSS           => 'c08a26dd-7718-4382-8482-6e0d583c4d0e',
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
    $buf = &_push($buf, "V", 4096); # MaxControlTransfer 
    return $buf;
}

# MBIM_CLOSE_MSG
sub mk_close_msg {
    my $buf = &init_msg_header(2); # MBIM_CLOSE_MSG  
    return $buf;
}

# MBIM_COMMAND_MSG  
sub mk_command_msg {
    my ($service, $cid, $type, $info) = @_;

    my $uuid = string_to_uuid($uuid{"UUID_$service"}) || return '';
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
    return $buf;
}

# MBIM_HOST_ERROR_MSG  
sub mk_host_error_msg {
    my $errorcode = shift;
    my $buf = &init_msg_header(4); # MBIM_HOST_ERROR_MSG  
    $buf = &_push($buf, "V", $errorcode); # ErrorStatusCode  
    return $buf;
}


sub mk_cid_pin {
    my $pin = shift;

    # create the data buffer:
    my $data = pack("VVVVVV", 
		    2, #MBIMPinTypePin1  
		    0, #MBIMPinOperationEnter 
		    24, # offset
		    8, # PinSize  
		    0,
		    0);
    $data .= encode('utf16le', $pin);

    return &mk_command_msg('BASIC_CONNECT', 4, 1, $data);
}
    

sub decode_basic_connect {
    my ($cid, $info) = @_;

    if ($cid == 2) {
	print "CID 2 - MBIM_CID_SUBSCRIBER_READY_STATUS\n";
	my ($state, $idoff, $idsize, $iccidoff, $iccidsize, $flags, $ec ) = unpack("VVVVVVV", $info);
	print "  ReadyState:\t$state\n";
	print "  SubscriberIdOffset:\t$idoff\n";
	print "  SubscriberIdSize:\t$idsize\n";
	print "  SimIccIdOffset:\t$iccidoff\n";
	print "  SimIccIdSize:\t$iccidsize\n";
	printf "  ReadyInfo:\t0x%08x\n", $flags;
	print "  ElementCount (EC):\t$ec\n";
        # FIXME ignoring phone numbers for now...
	my $subscriberid = $idsize ? decode('utf16le', substr($info, $idoff, $idsize)) : '<none>';
	my $iccid = $iccidsize ? decode('utf16le', substr($info, $iccidoff, $iccidsize)) : '<none>';

	print "  SubscriberId:\t$subscriberid\n";
	print "  SimIccId:\t$iccid\n";

    } else {
	print "CID $cid decoding is not yet supported\n";
    }
}

sub decode_mbim {
    my $msg = shift;

    # decode message header
    my ($type, $len, $tid) = unpack("VVV", $msg);
    print "MBIM_MESSAGE_HEADER\n";
    printf "  MessageType:\t0x%08x\n", $type;
    printf "  MessageLength:\t0x%08x\n", $len;
    printf "  TransactionId:\t0x%08x\n", $tid;
    if ($type == 0x80000001) { # MBIM_OPEN_DONE
	my $status = unpack("V", substr($msg, 12));
	printf "Status:\t0x%08x\n", $status;

    } elsif ($type == 0x80000002) { # MBIM_CLOSE_DONE  
 	my $status = unpack("V", substr($msg, 12));
	printf "Status:\t0x%08x\n", $status;

    } elsif ($type == 0x80000003) { # MBIM_COMMAND_DONE  
	my ($total, $current) = unpack("VV", substr($msg, 12)); # FragmentHeader  
	print "MBIM_FRAGMENT_HEADER\n";
	printf "  TotalFragments:\t0x%08x\n", $total;
	printf "  CurrentFragment:\t0x%08x\n", $current;

	my $uuid = uuid_to_string(substr($msg, 20, 16));
	my $service = &uuid_to_service($uuid);
	print "DeviceServiceId:\t$uuid ($service)\n";

	my ($cid, $status, $infolen) = unpack("VVV", substr($msg, 36));
	my $info = substr($msg, 48);
	print "CID:\t$cid\n";
	printf "Status:\t0x%08x\n", $status;

	print "InformationBufferLength:\t$infolen\n";
	##print "InformationBuffer:\t$info\n";

	print "$service\n";
	if ($infolen != length($info)) {
	    print "Fragmented data is not yet supported\n";
	} elsif ($service eq 'BASIC_CONNECT') {
	    &decode_basic_connect($cid, $info);
	} else {
	    print "decoding of $service CIDs is not yet supported\n";
	}
	    
    } elsif ($type == 0x80000004) { # MBIM_FUNCTION_ERROR_MSG  
	my $status = unpack("V", substr($msg, 12));
	printf "ErrorStatusCode:\t0x%08x\n", $status;
    } elsif ($type == 0x80000007) { # MBIM_INDICATE_STATUS_MSG  
	my ($total, $current) = unpack("VV", substr($msg, 12)); # FragmentHeader  
	print "MBIM_FRAGMENT_HEADER\n";
	printf "  TotalFragments:\t0x%08x\n", $total;
	printf "  CurrentFragment:\t0x%08x\n", $current;

	my $uuid = uuid_to_string(substr($msg, 20, 16));
	my $service = &uuid_to_service($uuid);
	print "DeviceServiceId:\t$uuid ($service)\n";

	my ($cid, $infolen) = unpack("VV", substr($msg, 36));
	my $info = substr($msg, 44);
	print "CID:\t$cid\n";

	print "InformationBufferLength:\t$infolen\n";
	##print "InformationBuffer:\t$info\n";

	print "$service\n";
	if ($infolen != length($info)) {
	    print "Fragmented data is not yet supported\n";
	} elsif ($service eq 'BASIC_CONNECT') {
	    &decode_basic_connect($cid, $info);
	} else {
	    print "decoding of $service CIDs is not yet supported\n";
	}
    }
}

# read from F until timeout
sub read_mbim {
    my $match = shift;
    my $timeout = shift || 0;
    my $found = undef;

    warn("reading from $mgmt\n") if $debug;
    eval {
	local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
	my $raw;
	alarm $timeout;
	do {
	    my $len = 0;
	    if (!$raw) {
		$len = sysread(F, $raw, 4096);
		warn("[" . localtime . "] read $len bytes from $mgmt\n") if ($debug && $len);
	    }
	    if ($len) {
		print "\n---\n" if $debug;
		printf "%02x " x length($raw), unpack("C*", $raw) if $debug;
		print "\n---\n" if $debug;
		&decode_mbim($raw);
		$raw = '';
	    }
	} while (!$found);
	alarm 0;
	warn "got match!\n" if ($found && $debug);
    };
    if ($@) {
	die unless $@ eq "alarm\n";   # propagate unexpected errors
    }
}



### main ###

# open it now and keep it open until exit
open(F, "+<", $mgmt) || die "open $mgmt: $!\n";
autoflush F 1;

# get the command
my $cmd = shift;

if ($cmd eq "open") {
    print F &mk_open_msg;
} elsif ($cmd eq "close") {
    print F &mk_close_msg;
} elsif ($cmd eq "pin") {
    print F &mk_cid_pin($pin{1}) if $pin{1};
} elsif ($cmd eq "monitor") {
    &read_mbim;
} else {
    &usage;
}

# close device
close(F);

