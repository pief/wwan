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

sub msg_to_string {
    my $msg = shift;
    my ($name) = grep { $msg{$_} == $msg } keys %msg;
    return $name || '<unknown>';
}


# Table 9‐8: MBIM_PROTOCOL_ERROR_CODES 
my %error = (
    'MBIM_ERROR_TIMEOUT_FRAGMENT' => {
	'code' => 1,
	'text' => 'Shall be sent by the receiver if the time between the fragments exceeds the max fragment time. ', 
	'ref' => '9.3.4.1', },
    'MBIM_ERROR_FRAGMENT_OUT_OF_SEQUENCE' => {
	'code' => 2,
	'text' => 'Shall be sent by the receiver if a fragmented message is sent out of sequence', 
	'ref' => '9.3.4.2', },
    'MBIM_ERROR_LENGTH_MISMATCH' => { 
	'code' => 3,
	'text' => 'Shall be sent by the receiver if the InformationBufferLength with required padding does not match the total of MessageLength minus headers',
	'ref' => '9.3.4.3', },
    'MBIM_ERROR_DUPLICATED_TID' => {
	'code' => 4,
	'text' => 'Shall be sent by the receiver if two MBIM commands are sent with the same TID', 
	'ref' => '9.3.4.4', },
    'MBIM_ERROR_NOT_OPENED' => {
	'code' => 5,
	'text' => 'The function shall respond with this error code if it receives any MBIM commands prior to an open command or after a close command.', 
	'ref' => '9.3.4.5.', },
    'MBIM_ERROR_UNKNOWN' => {
	'code' => 6,
	'text' => 'Shall be sent by the function when an unknown error is detected on the MBIM layer.  Expected behavior is that the host resets the function if a MBIM_ERROR_UNKNOWN is received.',
	'ref' => '<none>', },
    'MBIM_ERROR_CANCEL' => {
	'code' => 7,
	'text' => 'Can be sent by the host to cancel a pending transaction.', 
	'ref' => '9.3.4.6', },
    'MBIM_ERROR_MAX_TRANSFER' => {
	'code' => 8,
	'text' => 'Shall be sent if the function does not support the maximum control transfer the host supports.', 
	'ref' => '9.3.1.1.', },
    );

sub error_to_string {
    my $error = shift;
    my ($name) = grep { $error{$_}->{code} == $error } keys %error;
    return $name || '<unknown>';
}


# Table 9‐15: MBIM_STATUS_CODES 
my %status = (
	'MBIM_STATUS_SUCCESS' => 0,
	'MBIM_STATUS_BUSY' => 1,
	'MBIM_STATUS_FAILURE' => 2,
	'MBIM_STATUS_SIM_NOT_INSERTED' => 3,
	'MBIM_STATUS_BAD_SIM' => 4,
	'MBIM_STATUS_PIN_REQUIRED' => 5,
	'MBIM_STATUS_PIN_DISABLED' => 6,
	'MBIM_STATUS_NOT_REGISTERED' => 7,
	'MBIM_STATUS_PROVIDERS_NOT_FOUND' => 8,
	'MBIM_STATUS_NO_DEVICE_SUPPORT' => 9,
	'MBIM_STATUS_PROVIDER_NOT_VISIBLE' => 10,
	'MBIM_STATUS_DATA_CLASS_NOT_AVAILABLE' => 11,
	'MBIM_STATUS_PACKET_SERVICE_DETACHED' => 12,
	'MBIM_STATUS_MAX_ACTIVATED_CONTEXTS' => 13,
	'MBIM_STATUS_NOT_INITIALIZED' => 14,
	'MBIM_STATUS_VOICE_CALL_IN_PROGRESS' => 15,
	'MBIM_STATUS_CONTEXT_NOT_ACTIVATED' => 16,
	'MBIM_STATUS_SERVICE_NOT_ACTIVATED' => 17,
	'MBIM_STATUS_INVALID_ACCESS_STRING' => 18,
	'MBIM_STATUS_INVALID_USER_NAME_PWD' => 19,
	'MBIM_STATUS_RADIO_POWER_OFF' => 20,
	'MBIM_STATUS_INVALID_PARAMETERS' => 21,
	'MBIM_STATUS_READ_FAILURE' => 22,
	'MBIM_STATUS_WRITE_FAILURE' => 23,
#  Reserved  24
	'MBIM_STATUS_NO_PHONEBOOK' => 25,
	'MBIM_STATUS_PARAMETER_TOO_LONG' => 26,
	'MBIM_STATUS_STK_BUSY' => 27,
	'MBIM_STATUS_OPERATION_NOT_ALLOWED' => 28,
	'MBIM_STATUS_MEMORY_FAILURE' => 29,
	'MBIM_STATUS_INVALID_MEMORY_INDEX' => 30,
	'MBIM_STATUS_MEMORY_FULL' => 31,
	'MBIM_STATUS_FILTER_NOT_SUPPORTED' => 32,
	'MBIM_STATUS_DSS_INSTANCE_LIMIT' => 33,
	'MBIM_STATUS_INVALID_DEVICE_SERVICE_OPERATION' => 34,
	'MBIM_STATUS_AUTH_INCORRECT_AUTN' => 35,
	'MBIM_STATUS_AUTH_SYNC_FAILURE' => 36,
	'MBIM_STATUS_AUTH_AMF_NOT_SET' => 37,
	'MBIM_STATUS_SMS_UNKNOWN_SMSC_ADDRESS' => 100,
	'MBIM_STATUS_SMS_NETWORK_TIMEOUT' => 101,
	'MBIM_STATUS_SMS_LANG_NOT_SUPPORTED' => 102,
	'MBIM_STATUS_SMS_ENCODING_NOT_SUPPORTED' => 103,
	'MBIM_STATUS_SMS_FORMAT_NOT_SUPPORTED' => 104,

# Device service specific status commands  
# 80000000h - FFFFFFFFh 

    );

sub status_to_string {
    my $status = shift;
    my ($name) = grep { $status{$_} == $status } keys %status;
    return $name || '<unknown>';
}

# Table 10‐3: Services Defined by MBIM 
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

# Table 10‐4: Defined CIDs and Message Formats for Commands and Results 
my %cid = (
    'MBIM_CID_DEVICE_CAPS' => { 'service' => 'BASIC_CONNECT', 'cid' => 1, },
    'MBIM_CID_SUBSCRIBER_READY_STATUS' => { 'service' => 'BASIC_CONNECT', 'cid' => 2, },
    'MBIM_CID_RADIO_STATE' => { 'service' => 'BASIC_CONNECT', 'cid' => 3, },
    'MBIM_CID_PIN' => { 'service' => 'BASIC_CONNECT', 'cid' => 4, },
    'MBIM_CID_PIN_LIST' => { 'service' => 'BASIC_CONNECT', 'cid' => 5, },
    'MBIM_CID_HOME_PROVIDER' => { 'service' => 'BASIC_CONNECT', 'cid' => 6, },
    'MBIM_CID_PREFERRED_PROVIDERS' => { 'service' => 'BASIC_CONNECT', 'cid' => 7, },
    'MBIM_CID_VISIBLE_PROVIDERS' => { 'service' => 'BASIC_CONNECT', 'cid' => 8, },
    'MBIM_CID_REGISTER_STATE' => { 'service' => 'BASIC_CONNECT', 'cid' => 9, },
    'MBIM_CID_PACKET_SERVICE' => { 'service' => 'BASIC_CONNECT', 'cid' => 10, },
    'MBIM_CID_SIGNAL_STATE' => { 'service' => 'BASIC_CONNECT', 'cid' => 11, },
    'MBIM_CID_CONNECT' => { 'service' => 'BASIC_CONNECT', 'cid' => 12, },
    'MBIM_CID_PROVISIONED_CONTEXTS' => { 'service' => 'BASIC_CONNECT', 'cid' => 13, },
    'MBIM_CID_SERVICE_ACTIVATION' => { 'service' => 'BASIC_CONNECT', 'cid' => 14, },
    'MBIM_CID_IP_CONFIGURATION' => { 'service' => 'BASIC_CONNECT', 'cid' => 15, },
    'MBIM_CID_DEVICE_SERVICES' => { 'service' => 'BASIC_CONNECT', 'cid' => 16, },
    'MBIM_CID_DEVICE_SERVICE_SUBSCRIBE_LIST' => { 'service' => 'BASIC_CONNECT', 'cid' => 19, },
    'MBIM_CID_PACKET_STATISTICS' => { 'service' => 'BASIC_CONNECT', 'cid' => 20, },
    'MBIM_CID_NETWORK_IDLE_HINT' => { 'service' => 'BASIC_CONNECT', 'cid' => 21, },
    'MBIM_CID_EMERGENCY_MODE' => { 'service' => 'BASIC_CONNECT', 'cid' => 22, },
    'MBIM_CID_IP_PACKET_FILTERS' => { 'service' => 'BASIC_CONNECT', 'cid' => 23, },
    'MBIM_CID_MULTICARRIER_PROVIDERS' => { 'service' => 'BASIC_CONNECT', 'cid' => 24, },
    'MBIM_CID_SMS_CONFIGURATION' => { 'service' => 'SMS', 'cid' => 1, },
    'MBIM_CID_SMS_READ' => { 'service' => 'SMS', 'cid' => 2, },
    'MBIM_CID_SMS_SEND' => { 'service' => 'SMS', 'cid' => 3, },
    'MBIM_CID_SMS_DELETE' => { 'service' => 'SMS', 'cid' => 4, },
    'MBIM_CID_SMS_MESSAGE_STORE_STATUS' => { 'service' => 'SMS', 'cid' => 5, },
    'MBIM_CID_USSD' => { 'service' => 'USSD', 'cid' => 1, },
    'MBIM_CID_PHONEBOOK_CONFIGURATION' => { 'service' => 'PHONEBOOK', 'cid' => 1, },
    'MBIM_CID_PHONEBOOK_READ' => { 'service' => 'PHONEBOOK', 'cid' => 2, },
    'MBIM_CID_PHONEBOOK_DELETE' => { 'service' => 'PHONEBOOK', 'cid' => 3, },
    'MBIM_CID_PHONEBOOK_WRITE' => { 'service' => 'PHONEBOOK', 'cid' => 4, },
    'MBIM_CID_STK_PAC' => { 'service' => 'STK', 'cid' => 1, },
    'MBIM_CID_STK_TERMINAL_RESPONSE' => { 'service' => 'STK', 'cid' => 2, },
    'MBIM_CID_STK_ENVELOPE' => { 'service' => 'STK', 'cid' => 3, },
    'MBIM_CID_AKA_AUTH' => { 'service' => 'AUTH', 'cid' => 1, },
    'MBIM_CID_AKAP_AUTH' => { 'service' => 'AUTH', 'cid' => 2, },
    'MBIM_CID_SIM_AUTH' => { 'service' => 'AUTH', 'cid' => 3, },
    'MBIM_CID_DSS_CONNECT' => { 'service' => 'DSS', 'cid' => 1, },
    );


sub cid_to_string {
    my ($service, $cid) = @_;
    my ($name) = grep { $cid{$_}->{service} eq $service && $cid{$_}->{cid} == $cid } keys %cid;
    return $name || '<unknown>';
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

# Table 10‐37: MBIM_PROVIDER 
sub decode_mbim_provider {
    my $info = shift;
    my ($off, $size, $state, $nameoff, $namesize, $class, $rssi, $errorrate)= unpack("VVVVVVVV", $info);
    print "    ProviderId:\t", $size ? substr($info, $off, $size): '<none>', "\n";
    print "    ProviderState:\t$state\n";
    print "    ProviderName:\t", $namesize ? substr($info, $nameoff, $namesize) : '<none>', "\n";
    print "    CellularClass:\t$class\n";
    print "    RSSI:\t$rssi\n";
    print "    ErrorRate:\t$errorrate\n";
}

# Table 10‐39: MBIM_PROVIDERS 
sub decode_mbim_providers {
    my $info = shift;
    my $ec = unpack("V", $info);
    print "  ElementCount (EC): $ec\n  ProvidersRefList:\n";
    for (my $i = 0; $i < $ec; $i++) {
	my ($off, $len) = unpack("VV", substr($info, 4 + 8 * $i, 8));
	&decode_mbim_provider(substr($info, $off, $len));
    }
}

sub decode_basic_connect {
    my ($cid, $info) = @_;

    if ($cid == 2) {
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

    } elsif ($cid == 4) {

    } elsif ($cid == 7) {

    } elsif ($cid == 9) {

    } elsif ($cid == 11) {
	my ($rssi, $errorrate, $interval, $rssitresh, $errorthresh)= unpack("VVVVV", $info);
	print "  RSSI:\t$rssi\n";
	print "  ErrorRate:\t$errorrate\n";
	print "  SignalStrengthInterval:\t$interval\n";
	print "  RSSIThreshold:\t$rssi\n";
	print "  ErrorRateThreshold:\t$errorrate\n";
    } else {
	print "CID $cid decoding is not yet supported\n";
    }
}

sub decode_sms {
    my ($cid, $info) = @_;

    if ($cid == 1) {
    } else {
	print "CID $cid decoding is not yet supported\n";
    }
}

sub decode_mbim {
    my $msg = shift;

    # decode message header
    my ($type, $len, $tid) = unpack("VVV", $msg);
    print "MBIM_MESSAGE_HEADER\n";
    printf "  MessageType:\t0x%08x (%s)\n", $type, &msg_to_string($type);
    printf "  MessageLength:\t%d\n", $len;
    printf "  TransactionId:\t%d\n", $tid;
    if ($type == 0x80000001) { # MBIM_OPEN_DONE
	my $status = unpack("V", substr($msg, 12));
	print "Status:\t$status (", &status_to_string($status), ")\n";

    } elsif ($type == 0x80000002) { # MBIM_CLOSE_DONE  
 	my $status = unpack("V", substr($msg, 12));
	print "Status:\t$status (", &status_to_string($status), ")\n";

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
	print "CID:\t$cid (", &cid_to_string($service, $cid), ")\n";
	print "Status:\t$status (", &status_to_string($status), ")\n";

	print "InformationBufferLength:\t$infolen\n";
	##print "InformationBuffer:\t$info\n";

	if ($infolen != length($info)) {
	    print "Fragmented data is not yet supported\n";
	} elsif ($service eq 'BASIC_CONNECT') {
	    &decode_basic_connect($cid, $info);
	} else {
	    print "decoding of $service CIDs is not yet supported\n";
	}
	    
    } elsif ($type == 0x80000004) { # MBIM_FUNCTION_ERROR_MSG  
	my $status = unpack("V", substr($msg, 12));
	print "ErrorStatusCode:\t$status (", &error_to_string($status), ")\n";
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
	print "CID:\t$cid (", &cid_to_string($service, $cid), ")\n";

	print "InformationBufferLength:\t$infolen\n";
	##print "InformationBuffer:\t$info\n";

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

