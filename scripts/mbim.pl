#!/usr/bin/perl
# Copyright (c) 2012  Bjørn Mork <bjorn@mork.no>
# GPLv2

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use Encode;
use Devel::SimpleTrace;
use UUID::Tiny ':std';
use Net::IP;

# default, will be overridden by ioctl if supported
my $maxctrl = 4096;

# per interface config
my %pin; $pin{1} = &strip_quotes($ENV{'IF_WWAN_PIN'}) if $ENV{'IF_WWAN_PIN'};
my $apn =  &strip_quotes($ENV{'IF_WWAN_APN'});
my $session = 0;

# output levels
my $verbose = 1;
my $debug = 1;

# internal state
my $tid = 1;		# transaction id

# sleep and read all rcvd messages?
my $monitor = 0;

# management device
my $mgmt = &strip_quotes($ENV{MGMT}) || "/dev/cdc-wdm0";

# QMI specifics
my $qmisys;
my $qmicid;


### functions used during enviroment variable parsing ###
sub usage {
    print STDERR <<EOH
Usage: $0 [options]  open|caps|pin|close|connect|disconnect|attach|detach|getreg|getservices|monitor|qmi|getunknown

Where [options] are

  --device=<cdc-wdm> (defaults to $mgmt)
  --pin=<code>
  --apn=<apn>
  --session=<id>
  --[no]verbose
  --[no]debug

only for "qmi" command:
  --qmisys=<hh>
  --qmicid=<hh>

followed by QMI message number and TLVs as a combination of hex values and byte streams
e.g
  0x0024 0x01 00 0x10 01 0f


Or for offline decoding only:

   $0 [--[no]debug] offline <message>

Example:

   $0 offline 01:00:00:80:10:00:00:00:01:00:00:00:00:00:00:00


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
    'session=i' => \$session,
    'verbose!' => \$verbose,
    'debug!' => \$debug,
    'tid=i' => \$tid,

    'qmisys=s' => \$qmisys,
    'qmicid=i' => \$qmicid,

    'help|h|?' => \&usage,
    ) || &usage;

# the rest of the command line is left for the actual command to run
# network device is required
&usage unless $mgmt;


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

## "well known" vendor specific services
    'MBIM_CID_QMI' => { 'service' => 'EXT_QMUX', 'cid' => 1, },

    'MBIM_CID_MULTICARRIER_CAPABILITIES' => { 'service' => 'MULTICARRIER', 'cid' => 1, },
    'MBIM_CID_LOCATION_INFO' => { 'service' => 'MULTICARRIER', 'cid' => 2, },
    'MBIM_CID_MULTICARRIER_CURRENT_CID_LIST' => { 'service' => 'MULTICARRIER', 'cid' => 3, },

    'MBIM_CID_MSFWID_FIRMWAREID' => { 'service' => 'MSFWID', 'cid' => 1, },

    'MBIM_CID_MS HOSTSHUTDOWN' => { 'service' => 'MS_HOSTSHUTDOWN', 'cid' => 1, },
    );


sub cid_to_string {
    my ($service, $cid) = @_;
    my ($name) = grep { $cid{$_}->{service} eq $service && $cid{$_}->{cid} == $cid } keys %cid;
    return $name || "<unknown> ($cid)";
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

# MBIM_HOST_ERROR_MSG  
sub mk_host_error_msg {
    my $errorcode = shift;
    my $buf = &init_msg_header(4); # MBIM_HOST_ERROR_MSG  
    $buf = &_push($buf, "V", $errorcode); # ErrorStatusCode  
    return $buf;
}

# Table 10‐62: MBIM_AUTH_PROTOCOL 
my %authproto = (
    0 => 'MBIMAuthProtocolNone', 
    1 => 'MBIMAuthProtocolPap', 
    2 => 'MBIMAuthProtocolChap',  
    3 => 'MBIMAuthProtocolMsChapV2',
    );

# Table 10‐63: MBIM_CONTEXT_IP_TYPE 
my %iptype = (
	0 => 'MBIMContextIPTypeDefault',
	1 => 'MBIMContextIPTypeIPv4',
	2 => 'MBIMContextIPTypeIPv6',
	3 => 'MBIMContextIPTypeIPv4v6',
	4 => 'MBIMContextIPTypeIPv4AndIPv6',
    );

# Table 10‐64: MBIM_ACTIVATION_STATE 
my %actstate = (
	0 => 'MBIMActivationStateUnknown',
	1 => 'MBIMActivationStateActivated',
	2 => 'MBIMActivationStateActivating',
	3 => 'MBIMActivationStateDeactivated',
	4 => 'MBIMActivationStateDeactivating',
    );


# Table 10‐65: MBIM_VOICE_CALL_STATE 
my %voicestate = (
	0 => 'MBIMVoiceCallStateNone',
	1 => 'MBIMVoiceCallStateInProgress',
	2 => 'MBIMVoiceCallStateHangUp',
    );

# Table 10‐66: MBIM_CONTEXT_TYPES 
my %context = (
'MBIMContextTypeNone' => 'B43F758C-A560-4B46-B35E-C5869641FB54',
'MBIMContextTypeInternet' => '7E5E2A7E-4E6F-7272-736B-656E7E5E2A7E',
'MBIMContextTypeVpn' => '9B9F7BBE-8952-44B7-83AC-CA41318DF7A0',
'MBIMContextTypeVoice' => '88918294-0EF4-4396-8CCA-A8588FBC02B2',
'MBIMContextTypeVideoShare' => '05A2A716-7C34-4B4D-9A91-C5EF0C7AAACC',
'MBIMContextTypePurchase' => 'B3272496-AC6C-422B-A8C0-ACF687A27217',
'MBIMContextTypeIMS' => '21610D01-3074-4BCE-9425-B53A07D697D6',
'MBIMContextTypeMMS' => '46726664-7269-6BC6-9624-D1D35389ACA9',
'MBIMContextTypeLocal' => 'A57A9AFC-B09F-45D7-BB40-033C39F60DB9',
    );
sub type_to_context {
    my $type = uc(shift);
    my ($context) = grep { $context{$_} eq $type } keys %context;
    return $context || '<unknown>';
}


# MBIM_CID_DEVICE_CAPS
sub mk_cid_device_caps {
    # query - empty data buffer
    return &mk_command_msg('BASIC_CONNECT', 1, 0, '');
}

sub mk_cid_register_state {
    # query - empty data buffer
    return &mk_command_msg('BASIC_CONNECT', 9, 0, '');
}

sub mk_cid_packet_service {
    my $attach = shift;
    my $data = pack("V", !$attach); # PacketServiceAction 0 => attach, 1 => detach

    return &mk_command_msg('BASIC_CONNECT', 10, 1, $data);
}

sub mk_cid_dss_connect {
    my ($uuid, $linkstate, $sessionid) = @_;

    warn "Connecting SessionID=$sessionid to \"$uuid\"\n";
    $sessionid ||= 0;
    # create the data buffer:
    my $data = string_to_uuid($uuid). pack("VV", 
		    $sessionid, # SessionId  
		    !!$linkstate, # DssLinkState 
	);
    return &mk_command_msg('DSS', 1, 1, $data);
}

sub mk_cid_connect {
    my ($apn, $activate, $sessionid) = @_;
    $sessionid ||= 0;
    warn "Connecting SessionID=$sessionid to \"$apn\"\n";
    $apn = encode('utf16le', $apn);
    my $apnlen = length($apn);
    # create the data buffer:
    my $data = pack("V11", 
		    $sessionid, # SessionId  
		    !!$activate, # ActivationCommand  
		    60, # AccessStringOffset
		    $apnlen, # AccessStringSize  
		    0, # UserNameOffset  
		    0, # UserNameSize  
		    0, # PasswordOffset  
		    0, # PasswordSize  
		    0, # Compression  
		    0, # AuthProtocol  
		    1, # IPType  (IPv4)
	);
    my $type = 0 ? 'Vpn' : 'Internet';
    $data .= string_to_uuid($context{"MBIMContextType$type"});
    $data .= $apn;
    return &mk_command_msg('BASIC_CONNECT', 12, 1, $data);
}

sub mk_ipv6_connect {
    my ($apn, $activate, $sessionid) = @_;
    $sessionid ||= 0;
    warn "Connecting SessionID=$sessionid to \"$apn\"\n";
    $apn = encode('utf16le', $apn);
    my $apnlen = length($apn);
    # create the data buffer:
    my $data = pack("V11", 
		    $sessionid, # SessionId  
		    !!$activate, # ActivationCommand  
		    60, # AccessStringOffset
		    $apnlen, # AccessStringSize  
		    0, # UserNameOffset  
		    0, # UserNameSize  
		    0, # PasswordOffset  
		    0, # PasswordSize  
		    0, # Compression  
		    0, # AuthProtocol  
		    2, # IPType  (IPv6)
	);
    my $type = 0 ? 'Vpn' : 'Internet';
    $data .= string_to_uuid($context{"MBIMContextType$type"});
    $data .= $apn;
    return &mk_command_msg('BASIC_CONNECT', 12, 1, $data);
}

sub mk_mms_connect {
    my ($apn, $activate, $sessionid) = @_;
    $sessionid ||= 0;
    warn "Connecting SessionID=$sessionid to \"$apn\"\n";
    $apn = encode('utf16le', $apn);
    my $apnlen = length($apn);
    # create the data buffer:
    my $data = pack("V11", 
		    $sessionid, # SessionId  
		    !!$activate, # ActivationCommand  
		    60, # AccessStringOffset
		    $apnlen, # AccessStringSize  
		    0, # UserNameOffset  
		    0, # UserNameSize  
		    0, # PasswordOffset  
		    0, # PasswordSize  
		    0, # Compression  
		    0, # AuthProtocol  
		    1, # IPType 
	);
    my $type = 'MMS';
    $data .= string_to_uuid($context{"MBIMContextType$type"});
    $data .= $apn;
    return &mk_command_msg('BASIC_CONNECT', 12, 1, $data);
}

sub decode_mbim_context {
    my $info = shift;

    my $id = unpack("V", $info);
    print "    ContextId:\t$id\n";
    my $type = uuid_to_string(substr($info, 4, 16));
    print "    ContextType:\t$type (", &type_to_context($type), ")\n"; 

    my ($apnoff, $apnlen, $useroff, $userlen, $pwoff, $pwlen, $comp, $auth) = unpack("V8", substr($info, 20));
    print "    AccessString:\t", $apnlen ? substr($info, $apnoff, $apnlen): '<none>', "\n";
    print "    UserName:\t", $userlen ? substr($info, $useroff, $userlen): '<none>', "\n";
    print "    Password:\t", $pwlen ? substr($info, $pwoff, $pwlen): '<none>', "\n";
    print "    Compression:\t$comp\n";
    print "    AuthProtocol:\t$auth\n";
}


sub mk_cid_radio_state {
    my $on = shift;
    return $on ? &mk_command_msg('BASIC_CONNECT', 3, 1, pack("V", 1)) : &mk_command_msg('BASIC_CONNECT', 3, 0, '');
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

# Table 10‐7: MBIM_DEVICE_TYPE 
my %devicetype = (
    1 => 'MBIMDeviceTypeEmbedded',
    2 => 'MBIMDeviceTypeRemovable',
    3 => 'MBIMDeviceTypeRemote',
);

# Table 10‐8: MBIM_CELLULAR_CLASS 
my %cellclass = (
    1 => 'MBIMCellularClassGsm',
    2 => 'MBIMCellularClassCdma',
    );
    
# Table 10‐9: MBIM_VOICE_CLASS 
my %voiceclass = (
    0 => 'MBIMVoiceClassUnknown',
    1 => 'MBIMVoiceClassNoVoice',
    2 => 'MBIMVoiceClassSeparateVoiceData',
    3 => 'MBIMVoiceClassSimultaneousVoiceData',
    );

# Table 10‐10: MBIM_SIM_CLASS 
my %simclass = (
    1 => 'MBIMSimClassSimLogical',
    2 => 'MBIMSimClassSimRemovable',
    );

# Table 10‐11: MBIM_DATA_CLASS 
my %dataclass = (
	0x0 => 'MBIMDataClassNone',
	0x1 => 'MBIMDataClassGPRS',
	0x2 => 'MBIMDataClassEDGE',
	0x4 => 'MBIMDataClassUMTS',
	0x8 => 'MBIMDataClassHSDPA',
	0x10 => 'MBIMDataClassHSUPA',
	0x20 => 'MBIMDataClassLTE',
#   40h - 8000h  Reserved for future GSM classes 
	0x10000 => 'MBIMDataClass1XRTT',
	0x20000 => 'MBIMDataClass1XEVDO',
	0x40000 => 'MBIMDataClass1XEVDORevA',
	0x80000 => 'MBIMDataClass1XEVDV',
	0x100000 => 'MBIMDataClass3XRTT',
	0x200000 => 'MBIMDataClass1XEVDORevB',
	0x400000 => 'MBIMDataClassUMB',
# 800000h - 40000000h Reserved for future CDMA classes 
	0x80000000 => 'MBIMDataClassCustom',
    );

# Table 10‐12: MBIM_SMS_CAPS 
my %smscaps = (
    1 => 'MBIMSmsCapsPduReceive',
    2 => 'MBIMSmsCapsPduSend',
    4 => 'MBIMSmsCapsTextReceive',
    8 => 'MBIMSmsCapsTextSend',
    );

# Table 10‐13: MBIM_CTRL_CAPS 
my %ctrlcaps = (
    0x01 => 'MBIMCtrlCapsRegManual',
    0x02 => 'MBIMCtrlCapsHwRadioSwitch',
    0x04 => 'MBIMCtrlCapsCdmaMobileIp',
    0x08 => 'MBIMCtrlCapsCdmaSimpleIp',
    0x10 => 'MBIMCtrlCapsMultiCarrier',
);

sub value_to_class {
    my $value = shift;
    my $rh_class = shift;
    my $ret = $rh_class->{$value} || 'Unknown';
    $ret =~ s/MBIM[A-Z][a-z]+(?:Class|Caps|Type)//;
    return  $ret;
}

sub flags_to_class {
    my $flags = shift;
    my $rh_class = shift;
    my @class =  map { my $x = $rh_class->{$_}; $x =~ s/MBIM[A-Z][a-z]+(?:Class|Caps|Type)//; $x } grep { $flags & $_ } sort { $a <=> $b } keys %$rh_class;

    return join(', ', @class) || 'None';
}

# Table 10‐16: MBIM_SUBSCRIBER_READY_STATE 
my %readystate = (
	0 => 'MBIMSubscriberReadyStateNotInitialized',
	1 => 'MBIMSubscriberReadyStateInitialized',
	2 => 'MBIMSubscriberReadyStateSimNotInserted',
	3 => 'MBIMSubscriberReadyStateBadSim',
	4 => 'MBIMSubscriberReadyStateFailure',
	5 => 'MBIMSubscriberReadyStateNotActivated',
	6 => 'MBIMSubscriberReadyStateDeviceLocked',
    );

# Table 10‐17: MBIM_UNIQUE_ID_FLAGS 
my %readyinfo = (
    0 => 'MBIMReadyInfoFlagsNone',
    1 => 'MBIMReadyInfoFlagsProtectUniqueID',
    );

# Table 10‐24: MBIM_PIN_TYPE 
my %pintype = (
	0 => 'MBIMPinTypeNone',
	1 => 'MBIMPinTypeCustom',
	2 => 'MBIMPinTypePin1',
	3 => 'MBIMPinTypePin2	',
	4 => 'MBIMPinTypeDeviceSimPin',
	5 => 'MBIMPinTypeDeviceFirstSimPin',
	6 => 'MBIMPinTypeNetworkPin',
	7 => 'MBIMPinTypeNetworkSubsetPin',
	8 => 'MBIMPinTypeServiceProviderPin',
	9 => 'MBIMPinTypeCorporatePin',
	10 => 'MBIMPinTypeSubsidyLock',
	11 => 'MBIMPinTypePuk1',
	12 => 'MBIMPinTypePuk2',
	13 => 'MBIMPinTypeDeviceFirstSimPuk',
	14 => 'MBIMPinTypeNetworkPuk',
	15 => 'MBIMPinTypeNetworkSubsetPuk',
	16 => 'MBIMPinTypeServiceProviderPuk',
	17 => 'MBIMPinTypeCorporatePuk',
);

# Table 10‐25: MBIM_PIN_STATE 
my %pinstate = (
    0 => 'MBIMPinStateUnlocked',
    1 => 'MBIMPinStateLocked',
);

sub decode_pin_state {
    my $info = shift;
    my ($type, $state, $attempts) = unpack("V3", $info);
    print "  PINType:\t$type ($pintype{$type})\n";
    print "  PINState:\t$state ($pinstate{$state})\n";
    print "  RemainingAttempts:\t$attempts\n";
}

# Table 10‐31: MBIM_PIN_MODE 
my %pinmode = (
    0 => 'MBIMPinModeNotSupported',
    1 => 'MBIMPinModeEnabled',
    2 => 'MBIMPinModeDisabled',
    );

# Table 10‐32: MBIM_PIN_FORMAT 
my %pinformat = (
    0 => 'MBIMPinFormatUnknown',
    1 => 'MBIMPinFormatNumeric',
    2 => 'MBIMPinFormatAlphaNumeric',
    );


sub decode_pin_desc {
    my ($info, $desc) = @_;
    my ($mode, $format, $min, $max) = unpack("V4", $info);
    $mode = $pinmode{$mode} || 'MBIMPinModeUnknown';
    $format = $pinformat{$format} || 'MBIMPinFormatUnknown';
    $mode =~ s/^MBIMPinMode//;
    $format =~ s/^MBIMPinFormat//;
    print "  $desc:\t$mode, $format, min = $min, max = $max\n";
}

# Table 10‐37: MBIM_PROVIDER 
sub decode_mbim_provider {
    my $info = shift;
    my ($off, $size, $state, $nameoff, $namesize, $class, $rssi, $errorrate)= unpack("VVVVVVVV", $info);
    print "    ProviderId:\t", &utf16_field($info, $off, $size), "\n";
    print "    ProviderState:\t$state\n";
    print "    ProviderName:\t", &utf16_field($info, $nameoff, $namesize), "\n";
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

# Table 10‐44: 3GPP TS 24.008 Cause codes for NwError  
my %nwerror = (
    0 => 'none',
    2 => 'International Mobile Subscriber',
    4 => 'IMSI unknown in VLR',
    6 => 'Illegal ME',
    7 => 'GPRS services not allowed',
    8 => 'GPRS and non‐GPRS services not allowed',
    11 => 'PLMN not allowed',
    12 => 'Location area not allowed',
    13 => 'Roaming not allowed in this',
    14 => 'GPRS services not allowed in this PLMN',
    15 => 'No suitable cells in location area',
    17 => 'Network failure',
    22 => 'Congestion',
    );


# Table 10‐46: MBIM_REGISTER_STATE 
my %regstate = (
    0 => 'MBIMRegisterStateUnknown',
    1 => 'MBIMRegisterStateDeregistered',
    2 => 'MBIMRegisterStateSearching',
    3 => 'MBIMRegisterStateHome', 
    4 => 'MBIMRegisterStateRoaming',
    5 => 'MBIMRegisterStatePartner',
    6 => 'MBIMRegisterStateDenied'
    );

# Table 10‐47: MBIM_REGISTER_MODE 
my %regmode = (
	0 => 'MBIMRegisterModeUnknown',
	1 => 'MBIMRegisterModeAutomatic',
	2 => 'MBIMRegisterModeManual',
    );

sub utf16_field {
    my ($buf, $off, $len) = @_;
    return $len ? "[$len] ". decode('utf16le', substr($buf, $off, $len)) : '[0] <none>';
}

# Table 10‐50: MBIM_REGISTRATION_STATE_INFO 
sub decode_registration_state {
    my $info = shift;
    my ($nwerr, $state, $mode, $availclass, $currclass, 
	$idoff, $idsize, $nameoff, $namesize,
	$roamtxt, $roamlen,
	$flag) = unpack("V12", $info);

    print "    NwError:\t$nwerr ($nwerror{$nwerr})\n";
    print "    RegisterState:\t$state ($regstate{$state})\n";
    print "    RegisterMode:\t$mode ($regmode{$mode})\n";
    printf "    AvailableDataClasses:\t0x%08x %s\n", $availclass, &flags_to_class($availclass, \%dataclass);
    printf "    CurrentCellularClass:\t0x%08x %s\n", $currclass, &value_to_class($currclass, \%dataclass);
    print "    ProviderId:\t", &utf16_field($info, $idoff, $idsize), "\n";
    print "    ProviderName:\t", &utf16_field($info, $nameoff, $namesize), "\n";
    print "    RoamingtText:\t", &utf16_field($info, $roamtxt, $roamlen), "\n";
    printf "    RegistrationFlag:\t0x%08x\n", $flag;    
}

# Table 10‐53: MBIM_PACKET_SERVICE_STATE 
my %packetstate = (
	0 => 'MBIMPacketServiceStateUnknown',
	1 => 'MBIMPacketServiceStateAttaching',
	2 => 'MBIMPacketServiceStateAttached',
	3 => 'MBIMPacketServiceStateDetaching',
	4 => 'MBIMPacketServiceStateDetached',
    );

# Table 10‐138: MBIM_DEVICE_SERVICE_ELEMENT 
sub decode_device_service {
    my $info = shift;

    my $uuid = uuid_to_string(substr($info, 0, 16));
    my $service = uuid_to_service($uuid);
    print "  $service ($uuid)\n";
    my ($payload, $max, $cids)= unpack("V3", substr($info, 16));
    printf "    DssPayload:\t0x%08x%s%s\n",  $payload, $payload & 0x1 ? "\tout" : '', $payload & 0x2 ? "\tin" : '';
    print "    MaxDssInstances:\t$max\n";  
    print "    CidCount:\t$cids\n";
    my @cids = unpack("V$cids", substr($info, 28, 4 * $cids));
    print "    CidList:\t", join(', ', @cids), "\n";
    foreach my $cid (@cids) {
	print "      ", &cid_to_string($service, $cid), "\n";
    }
}

# Table 10‐141: MBIM_EVENT_ENTRY 
sub decode_event_entry {
    my $info = shift;
    my $uuid = uuid_to_string(substr($info, 0, 16));
    my $service = uuid_to_service($uuid);
    print "  $service ($uuid)\n";
    my $cids = unpack("V", substr($info, 16, 4));
    print "    CidCount:\t$cids\n";
    my @cids = unpack("V$cids", substr($info, 20, 4 * $cids));
    print "    CidList:\t", join(', ', @cids), "\n";
    foreach my $cid (@cids) {
	print "      ", &cid_to_string($service, $cid), "\n";
    }
}

my %ipcfg = (
    0x01 => 'address',
    0x02 => 'gateway',
    0x04 => 'dns',
    0x08 => 'mtu',
);

# Table 10‐101: MBIM_IPV4_ADDRESS 
sub ipv4_address {
    my $info = shift;
    return join('.', unpack("C4", $info));
}
    
# Table 10‐103: MBIM_IPV6_ADDRESS 
sub ipv6_address {
    my $info = shift;
    my $x = sprintf "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x", unpack("C16", $info);
    my $ip = new Net::IP ($x);
    return $ip->short();
}

# Table 10‐102: MBIM_IPV4_ELEMENT 
sub ipv4_element {
    my $info = shift;
    my $pfxlen = unpack("V", $info);
    return &ipv4_address(substr($info, 4, 4)) . "/$pfxlen";
}

# Table 10‐104: MBIM_IPV6_ELEMENT 
sub ipv6_element {
    my $info = shift;
    my $pfxlen = unpack("V", $info);
    return &ipv6_address(substr($info, 4, 16)) . "/$pfxlen";
}

sub decode_basic_connect {
    my ($cid, $info, $is_cmd) = @_;

    if ($cid == 1) { # MBIM_CID_DEVICE_CAPS
	my ($type, $class, $voiceclass, $simclass, $dataclass, $smscaps, $ctrlcaps, $maxsessions, $custoff, $custlen, $idoff, $idlen, $fwoff, $fwlen, $hwoff, $hwlen) = unpack("V16", $info);
	print "  DeviceType:\t", &value_to_class($type, \%devicetype), " ($type)\n";
	printf "  CellularClass:\t0x%08x %s\n", $class, &value_to_class($class, \%cellclass);
	printf "  VoiceClass:\t0x%08x %s\n", $voiceclass, &value_to_class($voiceclass, \%voiceclass);
	printf "  SIMClass:\t0x%08x %s\n", $simclass, &value_to_class($simclass, \%simclass);
	printf "  DataClass:\t0x%08x %s\n", $dataclass, &flags_to_class($dataclass, \%dataclass);
	printf "  SMSCaps:\t0x%08x %s\n", $smscaps, &flags_to_class($smscaps, \%smscaps);
	printf "  ControlCaps:\t0x%08x %s\n", $ctrlcaps, &flags_to_class($ctrlcaps, \%ctrlcaps);
	print "  MaxSessions:\t$maxsessions\n";
	print "  CustomDataClass:\t", &utf16_field($info, $custoff, $custlen), "\n";
	print "  DeviceId:\t", &utf16_field($info, $idoff, $idlen), "\n";
	print "  FirmwareInfo:\t", &utf16_field($info, $fwoff, $fwlen), "\n";
	print "  HardwareInfo:\t", &utf16_field($info, $hwoff, $hwlen), "\n";
    } elsif ($cid == 2) { # MBIM_CID_SUBSCRIBER_READY_STATUS
	my ($state, $idoff, $idlen, $iccidoff, $iccidlen, $flags, $ec ) = unpack("VVVVVVV", $info);
	print "  ReadyState:\t$readystate{$state} ($state)\n";
	print "  SubscriberId:\t", &utf16_field($info, $idoff, $idlen), "\n";
	print "  SimIccId:\t", &utf16_field($info, $iccidoff, $iccidlen), "\n";
	print "  ReadyInfo:\t$readyinfo{$flags} ($flags)\n";
	print "  ElementCount (EC):\t$ec\n";
	for (my $i = 0; $i < $ec; $i++) {
	    my ($off, $len) = unpack("VV", substr($info, 28 + 8 * $i, 8));
	    print "    TelephoneNumber $i:\t", &utf16_field($info, $off, $len), "\n";
	}
    } elsif ($cid == 3) { # MBIM_CID_RADIO_STATE  
	my ($hw, $sw) = unpack("VV", $info);
	printf "  HwRadioState:\t%s\n", $hw ? 'on' : 'off'; 
	printf "  SwRadioState:\t%s\n", $sw ? 'on' : 'off'; 
    } elsif ($cid == 4) { # MBIM_CID_PIN
	&decode_pin_state($info);
    } elsif ($cid == 5) { # MBIM_CID_PIN_LIST
	my $i = 0;
	for my $pin (qw/Pin1 Pin2 DeviceSimPin DeviceFirstSimPin NetworkPin NetworkSubsetPin ServiceProviderPin CorporatePin SubsidyLock Custom/) {
	    &decode_pin_desc(substr($info, $i++ * 16, 16), $pin);
	}
    } elsif ($cid == 6) { # MBIM_CID_HOME_PROVIDER
	&decode_mbim_provider($info);
    } elsif ($cid == 7) { # MBIM_CID_PREFERRED_PROVIDERS
	&decode_mbim_providers($info);
    } elsif ($cid == 9) { # MBIM_CID_REGISTER_STATE
	&decode_registration_state($info);
    } elsif ($cid == 10) { #MBIM_CID_PACKET_SERVICE
	my ($nwerr, $state, $class, $upspeed, $downspeed) = unpack("V3Q<2", $info);
	print "  NwError:\t$nwerror{$nwerr} ($nwerr)\n";
	print "  PacketServiceState:\t$packetstate{$state} ($state)\n";
	printf "  HighestAvailableDataClass:\t0x%08x %s\n", $class, &flags_to_class($class, \%dataclass);
	print "  UplinkSpeed:\t$upspeed\n";
	print "  DownlinkSpeed:\t$downspeed\n";
    } elsif ($cid == 11) { # MBIM_CID_SIGNAL_STATE
	my ($rssi, $errorrate, $interval, $rssitresh, $errorthresh)= unpack("VVVVV", $info);
	print "  RSSI:\t$rssi\n";
	print "  ErrorRate:\t$errorrate\n";
	print "  SignalStrengthInterval:\t$interval\n";
	print "  RSSIThreshold:\t$rssi\n";
	print "  ErrorRateThreshold:\t$errorrate\n";
    } elsif ($cid == 12 && !$is_cmd) { # MBIM_CID_CONNECT
	my ($id, $state, $voicestate, $iptype)  = unpack("V4", $info);
	print "  SessionId:\t$id\n";
	print "  ActivationState:\t$actstate{$state} ($state)\n";
	print "  VoiceCallState:\t$voicestate{$voicestate} ($voicestate)\n";
	print "  IPType:\t$iptype{$iptype} ($iptype)\n";
	my $type = uuid_to_string(substr($info, 16, 16));
	print "  ContextType:\t$type (", &type_to_context($type), ")\n"; 
	my $nwerr = unpack("V", substr($info, 32, 4));
	print "  NwError:\t$nwerr (", $nwerror{$nwerr} || 'unknown', ")\n";
    } elsif ($cid == 12 && $is_cmd) { # MBIM_CID_CONNECT
	my ($id, $actcmd, $apnoff, $apnlen, $useroff, $userlen, $pwoff, $pwlen, $comp, $auth, $iptype)  = unpack("V11", $info);
	print "  SessionId:\t$id\n";
	print "  ActivationCommand:\t", $actcmd ? "Activate" : "Deactivate", "\n";
	print "  AccessString:\t", &utf16_field($info, $apnoff, $apnlen), "\n";
	print "  UserName:\t", &utf16_field($info, $useroff, $userlen), "\n";
	print "  Password:\t", &utf16_field($info, $pwoff, $pwlen), "\n";
	print "  Compression:\t",  $comp ? "Enable" : "None", "\n";
	print "  AuthProtocol:\t$authproto{$auth} ($auth)\n";
	print "  IPType:\t$iptype{$iptype} ($iptype)\n";
	my $type = uuid_to_string(substr($info, 44, 16));
	print "  ContextType:\t$type (", &type_to_context($type), ")\n"; 
    } elsif ($cid == 13) { # MBIM_CID_PROVISIONED_CONTEXTS
	my $ec = unpack("V", $info);
	print "  ElementCount (EC): $ec\n  ProvisionedContextRefList:\n";
	for (my $i = 0; $i < $ec; $i++) {
	    print "  Context #$i:\n";
	    my ($off, $len) = unpack("VV", substr($info, 4 + 8 * $i, 8));
	    &decode_mbim_context(substr($info, $off, $len));
	}

    } elsif ($cid == 15) { # MBIM_CID_IP_CONFIGURATION  
	my ($id, $ipv4cfg, $ipv6cfg, $ipv4c, $ipv4o, $ipv6c, $ipv6o, $ipv4gw, $ipv6gw, $ipv4dnsc, $ipv4dnso, $ipv6dnsc, $ipv6dnso, $ipv4mtu, $ipv6mtu)  = unpack("V15", $info);
	print "  SessionId:\t$id\n";
	printf "  IPv4ConfigurationAvailable:\t0x%08x %s\n", $ipv4cfg, &flags_to_class($ipv4cfg, \%ipcfg);
	printf "  IPv6ConfigurationAvailable:\t0x%08x %s\n", $ipv6cfg, &flags_to_class($ipv6cfg, \%ipcfg);
	print "  IPv4AddressCount:\t$ipv4c\n";
	for (my $i = 0; $i < $ipv4c; $i++) {
	    print "    ", &ipv4_element(substr($info, $ipv4o + $i * 8, 8)), "\n";
	}
	print "  IPv6AddressCount:\t$ipv6c\n";
	for (my $i = 0; $i < $ipv6c; $i++) {
	    print "    ", &ipv6_element(substr($info, $ipv6o + $i * 20, 20)), "\n";
	}
	print "  IPv4Gateway:\t", &ipv4_address(substr($info, $ipv4gw, 4)), "\n";
	print "  IPv6Gateway:\t", &ipv6_address(substr($info, $ipv6gw, 16)), "\n";
	print "  IPv4DnsServerCount:\t$ipv4dnsc\n";
	for (my $i = 0; $i < $ipv4dnsc; $i++) {
	    print "    ", &ipv4_address(substr($info, $ipv4dnso + $i * 4, 4)), "\n";
	}
	print "  IPv6DnsServerCount:\t$ipv6dnsc\n";
	for (my $i = 0; $i < $ipv6dnsc; $i++) {
	    print "    ", &ipv6_address(substr($info, $ipv6dnso + $i * 16, 16)), "\n";
	}
	print "  IPv4Mtu:\t$ipv4mtu\n";
	print "  IPv6Mtu:\t$ipv6mtu\n";
    } elsif ($cid == 16) { # MBIM_CID_DEVICE_SERVICES
	my ($dsc, $max) = unpack("VV", $info);
	print "  DeviceServicesCount (DSC):\t$dsc\n";
	print "  MaxDssSessions:\t$max\n";
	for (my $i = 0; $i < $dsc; $i++) {
	    my ($off, $len) = unpack("VV", substr($info, 8 + 8 * $i, 8));
	    &decode_device_service(substr($info, $off, $len));
	}
    } elsif ($cid == 19) { # MBIM_CID_DEVICE_SERVICE_SUBSCRIBE_LIST
	my $ec = unpack("V", $info);
	print "  ElementCount (EC): $ec\n  DeviceServiceSubscribeRefList:\n";
	for (my $i = 0; $i < $ec; $i++) {
	    my ($off, $len) = unpack("VV", substr($info, 4 + 8 * $i, 8));
	    &decode_event_entry(substr($info, $off, $len));
	}

    } else {
	print "CID $cid decoding is not yet supported\n";
	print join(' ', map { sprintf "%02x", $_ } unpack("C*", $info)), "\n";

    }
}

sub decode_ussd {
    my ($cid, $info) = @_;

    print "USSD CID $cid decoding is not yet supported\n";
}

# Table 10‐113: MBIM_PHONEBOOK_STATE 
my %phonebookstate = (
    0 => 'MBIMPhonebookNotInitialized',
    1 => 'MBIMPhonebookInitialized',
    );
sub decode_phonebook {
    my ($cid, $info) = @_;

    if ($cid == 1) { # MBIM_CID_PHONEBOOK_CONFIGURATION
	my ($state, $total, $used, $maxnumber, $maxname)  = unpack("V5", $info);
	print "  PhonebookState:\t$phonebookstate{$state}\n";
	print "  TotalNbrOfEntries:\t$total\n";  
	print "  UsedEntries:\t$used\n";
	print "  MaxNumberLength:\t$maxnumber\n";  
	print "  MaxNameLength:\t$maxname\n";
    } else {
	print "PHONEBOOK CID $cid decoding is not yet supported\n";
    }
}
sub decode_stk {
    my ($cid, $info) = @_;

    print "STK CID $cid decoding is not yet supported\n";
}
sub decode_auth {
    my ($cid, $info) = @_;

    print "AUTH CID $cid decoding is not yet supported\n";
}

# Table 10‐77: MBIM_SMS_STORAGE_STATE 
my %smsstoragestate = (
    0 => 'MBIMSmsStorageNotInitialized',
    1 => 'MBIMSmsStorageInitialized',
    );

# Table 10‐78: MBIM_SMS_FORMAT 
my %smsformat = (
    0 => 'MBIMSmsFormatPdu',
    1 => 'MBIMSmsFormatCdma', 
    );

# Table 10‐85: MBIM_SMS_MESSAGE_STATUS 
my %smsmsgstatus = (
    0 => 'MBIMSmsStatusNew',
    1 => 'MBIMSmsStatusOld',
    2 => 'MBIMSmsStatusDraft',
    3 => 'MBIMSmsStatusSent',
    );


# Table 10‐98: MBIM_SMS_STATUS_FLAGS 
my %smsflags = (
    0 => 'MBIM_SMS_FLAG_NONE',
    1 => 'MBIM_SMS_FLAG_MESSAGE_STORE_FULL',
    2 => 'MBIM_SMS_FLAG_NEW_MESSAGE',
    );






#################
#Stolen from http://nah6.com/~itsme/cvs-xdadevtools/perlutils/decodesms.pl

# todo: add support for decoding cell broadcast message pdu's  -> 23.041

# this script decodes raw smsses

# 27.005 - Use of Data Terminal Equipment - Data Circuit terminating Equipment (DTE-DCE) interface for Short Message Service (SMS) and Cell Broadcast Service (CBS)
#    describes the at-commands involved in sending/receiving smsses

# 23.040 - Technical realization of Short Message Service (SMS)
#    describes the encoding of smsses

# 23.038 - Technical realization of Short Message Service (SMS)
#    describes the data coding schemes
#
#  ms = mobilestation
#  SC = servicecenter
my @pdutypes= (
    # ms->SC       |   SC->ms
 [ 'deliver-report', 'deliver' ],  # 0
 [ 'submit',   'submit-report' ],  # 1
 [ 'command',  'status-report' ],  # 2
 [ 'unknown-out', 'unknown-in' ],  # 3
);
#  RP = Reply-Path
#   H = UDHI - userdata header indicator
# SRI = status report indicator
# SRR = status report requested
# MMS = moremessages
#  RD = reject dups
# VPF = validity period format

#  MR = message reference
#  OA = origination address
#  DA = destination address
#  VP = validity period
# PID = protocol id
# DCS = data coding scheme
#SCTS = sc timestamp
#  DT = discharge time
# UDL = userdata lenght
#  UD = user data
# FCS = failure cause -- encoded as 'i'
#  PI = parameter indicator : bitmask
#  CT = command type
#  MN = message number
# CDL = commandata length
#  CD = command data
my %typeinfo= (                                           # 7  6 5    4 3 2   1 0 |
'deliver-report'=> ",FCS,PI,PID,DCS,UDL,UD,",             # -  H -    -   -   MTI | FCS, PI, PID, DCS, UDL, UD
'deliver'=>        ",OA,PID,DCS,SCTS,UDL,UD,",            # RP H SRI  -   MMS MTI | OA, PID, DCS, SCTS, UDL, UD
'submit'=>         ",MR,DA,PID,DCS,VP,UDL,UD,",           # RP H SRR  VPF RD  MTI | MR, DA, PID, DCS, VP, UDL, UD
'submit-report'=>  ",FCS,PI,SCTS,PID,DCS,UDL,UD,",        # -  H -    -   -   MTI | FCS, PI, SCTS, PID, DCS, UDL, UD
'status-report'=>  ",MR,RA,SCTS,DT,ST,PI,PID,DCS,UDL,UD,",# -  H SRQ  -   MMS MTI | MR, RA, SCTS, DT, ST, PI, PID, DCS, UDL, UD
'command'=>        ",MR,PID,CT,MN,DA,CDL,CD,",            # -  H SRR  -   -   MTI | MR, PID, CT, MN, DA, CDL, CD
);
sub hasfield {
    my ($pdutype, $field)= @_;
    return $typeinfo{$pdutype} =~ /,$field,/i;
}
my @numtypes= ( 'unknown', 'international', 'national', 'network', 'subscriber', 'alpha', 'abbrev', 'reserved' );
my @plantypes= ( 'Unknown', 'ISDN_e164', 'undef2', 'Data_x121', 'Telex', 'SCspec5', 'SCspec6', 'undef7', 'National', 'Private', 'ERMES', 'undefb', 'undefc', 'undefd', 'undefe', 'Reserved');

# TP-PID  protocol identifier
# bit7,6 == 00, bit5=0 : sme-to-sme protocol
# bit7,6 == 00, bit5=1 : telematic interworking
#   00000		implicit - device type is specific to this SC, or can be concluded on the basis of the address
#   00001		telex (or teletex reduced to telex format)
#   00010		group 3 telefax
#   00011		group 4 telefax
#   00100		voice telephone (i.e. conversion to speech)
#   00101		ERMES (European Radio Messaging System)
#   00110		National Paging system (known to the SC)
#   00111		Videotex (T.100 [20] /T.101 [21])
#   01000		teletex, carrier unspecified
#   01001		teletex, in PSPDN
#   01010		teletex, in CSPDN
#   01011		teletex, in analog PSTN
#   01100		teletex, in digital ISDN
#   01101		UCI (Universal Computer Interface, ETSI DE/PS 3 01-3)
#   01110..01111		(reserved, 2 combinations)
#   10000		a message handling facility (known to the SC)
#   10001		any public X.400-based message handling system
#   10010		Internet Electronic Mail
#   10011..10111		(reserved, 5 combinations)
#   11000..11110		values specific to each SC, usage based on mutual agreement between the SME and the SC 	(7 combinations available for each SC)
#   11111		A GSM/UMTS mobile station. The SC converts the SM from the received TP-DCS to any data coding scheme supported by the MS ( default )

# bit7,6=01 
# 000000		Short Message Type 0
# 000001		Replace Short Message Type 1
# 000010		Replace Short Message Type 2
# 000011		Replace Short Message Type 3
# 000100		Replace Short Message Type 4
# 000101		Replace Short Message Type 5
# 000110		Replace Short Message Type 6
# 000111		Replace Short Message Type 7
# 001000..011101		Reserved
# 011110		Enhanced Message Service (Obsolete)
# 011111		Return Call Message
# 100000..111011		Reserved
# 111100		ANSI-136 R-DATA
# 111101		ME Data download
# 111110		ME De-personalization Short Message
# 111111		(U)SIM Data download

# section 4.3: AT+CMGS=<length><CR>PDUDATA<CTRLZ>
#    length excluding smsc address
# section 4.2: AT+CMGR=<index><CR>
#   -> +CMGR: <stat>,[alpha],<length><CRLF>pdu
# +CMT: [<alpha>],<length><CRLF>pdu
#
# http://www.computer.org/portal/site/computer/menuitem.5d61c1d591162e4b0ef1bd108bcd45f3/index.jsp?&pName=computer_level1_article&TheCat=1055&path=computer/homepage/Dec07&file=howthings.xml&xsl=article.xsl&


#      type
#  91   1   - international
#  a1   2   - national
#  d0   5   - 7bit ascii
#  01   0
#  81   0
# struct address {
#     char nrofdigits;
#     struct {
#         int onebit:1
#         int numbertype:3;
#         int numberingplan:4;
#     } type;
#     char value[ceil(nrofdigits/2)]
# }

# numbertype
# 0 Unknown
# 1 International number
# 2 National number
# 3 Network specific number
# 4 Subscriber number
# 5 Alphanumeric, (coded according to 3GPP TS 23.038 [9] GSM 7-bit default alphabet)
# 6 Abbreviated number
# 7 Reserved for extension
#
# numberingplan
# 0	Unknown
# 1	ISDN/telephone numbering plan (E.164 [17]/E.163[18])
# 2
# 3	Data numbering plan (X.121)
# 4	Telex numbering plan
# 5	Service Centre Specific plan 1)
# 6	Service Centre Specific plan 1)
# 7
# 8	National numbering plan
# 9	Private numbering plan
# a	ERMES numbering plan (ETSI DE/PS 3 01-3)
# b
# c
# d
# e
# f	Reserved for extension

# sms-submit:
#       bb  
# 00   MTI,RD,VPF,SRR,UDHI,RP
# 01   MR
# 02   TP-DA
# ..
#      TP-PID
#      TP-DCS
#      TP-VP
# ..
#      TP-UDL
#      TP-UD

# SMS-DELIVER:
#       b   b   b    b bb  
#       
# 00   ,SRI,UDHI,RP,MMS,MTI
# 01   TP-DA

# 9.2.3.1 - TP-Message-Type-Indicator  (TP-MTI)
#  bits 1,0 of byte0 of all pdu's
#      xmit          |   recv
#   0 DELIVER-REPORT | DELIVER
#   1 SUBMIT         | SUBMIT-REPORT
#   2 COMMAND        | STATUS-REPORT
#   3 -              | -
 
# 9.2.3.2 - TP-More-Messages-to-Send  (TP-MMS)
#  bit 2 of byte0  of SMS-DELIVER and SMS-STATUS-REPORT
#   0  More messages are waiting for the MS in this SC
#   1  No more messages are waiting for the MS in this SC

# 9.2.3.25 TP-Reject-Duplicates (TP-RD)
#  bit 2 of byte0 of SMS-SUBMIT
#   0 Instruct the SC to accept an SMS-SUBMIT for an SM still held in the SC which has the same TP-MR and the same TP-DA as a previously  submitted SM from  the same OA.
#   1 Instruct the SC to reject an SMS-SUBMIT for an SM still held in the SC which has the same TP-MR and the same TP-DA as the  previously submitted SM  from the same OA. 

# 9.2.3.3 - TP-Validity-Period-Format (TP-VPF)
#  bit 4,3 of byte0 of SMS-SUBMIT
#   0  TP-VP field not present
#   1  TP-VP field present - relative format
#   2  TP-VP field present - enhanced format
#   3  TP-VP field present - absolute format 

# 9.2.3.4 - TP-Status-Report-Indication (TP-SRI)
#  bit 5 of byte0 of SMS-DELIVER
#   0  A status report shall not be returned to the SME
#   1  A status report shall be returned to the SME

# 9.2.3.26 - TP-Status-Report-Qualifier (TP-SRQ)
#  bit 5 of byte0 of SMS-STATUS-REPORT
#   0 The SMS-STATUS-REPORT is the result of a SMS-SUBMIT.
#   1 The SMS-STATUS-REPORT is the result of an SMS-COMMAND

# 9.2.3.5 - TP-Status-Report-Request (TP-SRR)
#  bit 5 of byte0 of SMS-SUBMIT, SMS-COMMAND
#   0  A status report is not requested
#   1  A status report is requested

# 9.2.3.23 - TP-User-Data-Header-Indicator (TP-UDHI)
#  bit 6 of byte0 of all pdu's
#   0 The TP-UD field contains only the short message
#   1 The beginning of the TP-UD field contains a Header in addition to the short message.

# 9.2.3.17 - TP-Reply-Path (TP-RP)
#  bit 7 of byte0 of SMS-DELIVER and SMS--SUBMIT
#   0  TP-Reply-Path parameter is not set in this SMS-SUBMIT/DELIVER
#   1  TP-Reply-Path parameter is set in this SMS-SUBMIT/DELIVER

my %msgtypename=(
    0=> {0=>'DELIVER-REPORT', 1=>'DELIVER'},
    1=> {0=>'SUBMIT',         1=>'SUBMIT-REPORT'},
    2=> {0=>'COMMAND',        1=>'STATUS-REPORT'},
    3=> {0=>'-',              1=>'-'},
);


################# EO stolen code - more below 

sub decode_sms_pdu_record {
    my $info = shift;
 
    my ($index, $status, $off, $len) = unpack("V4", $info);
    print "    MessageIndex:\t$index\n";
    print "    MessageStatus:\t$smsmsgstatus{$status} ($status)\n";

    decodesms(undef, substr($info, $off, $len));

}

sub decode_sms_cdma_record {
    print "dummy function\n";
}

sub decode_sms {
    my ($cid, $info) = @_;

    if ($cid == 1) { # MBIM_CID_SMS_CONFIGURATION  
	my ($storagestate, $format, $max, $cdmasize, $off, $len)  = unpack("V6", $info);
	print "  SmsStorageState:\t$smsstoragestate{$storagestate}\n";
	print "  Format:\t$smsformat{$format}\n";
	print "  MaxMessages:\t$max\n";
	print "  CdmaShortMessageSize:\t$cdmasize\n";
	print "  ScAddress:\t", &utf16_field($info, $off, $len), "\n";

    } elsif ($cid == 2) { # MBIM_CID_SMS_READ
	my ($format, $ec) = unpack("V2", $info);
	print "  Format:\t$smsformat{$format}\n";
	print "  ElementCount (EC): $ec\n  SmsRefList:\n";
	for (my $i = 0; $i < $ec; $i++) {
	    my ($off, $len) = unpack("VV", substr($info, 8 + 8 * $i, 8));
	    if ($format == 0) {
		&decode_sms_pdu_record(substr($info, $off, $len));
	    } elsif ($format == 1) {
		&decode_sms_cdma_record(substr($info, $off, $len));
	    } else {
		print "Unsupported SMS format: $format\n";
	    }
	}
    } elsif ($cid == 5) { # MBIM_CID_SMS_MESSAGE_STORE_STATUS 
	my ($flag, $index) = unpack("V2", $info);
	print "  Flags:\t$smsflags{$flag} ($flag)\n";
	print "  MessageIndex:\t$index\n";
    } else {
	print "SMS CID $cid decoding is not yet supported\n";
    }
}
sub decode_dss {
    my ($cid, $info) = @_;
    if ($cid == 1) { # MBIM_CID_DSS_CONNECT
	# no info buffer
    } else {
	print "DSS CID $cid decoding is not yet supported\n";
    }
}

# use the external "qmiparse" utility to decode the embedded QMUX
sub decode_ext_qmux {
    my ($cid, $info) = @_;

    if ($cid == 1) { # MBIM_CID_QMI
	open(P, "|qmiparse") || return;
	print P $info;
	close(P);
    } else {
	print "EXT_QMUX CID $cid decoding is not yet supported\n";
    }
}

sub decode_msfwid {
    my ($cid, $info) = @_;

    if ($cid == 1) { # MBIM_CID_MSFWID_FIRMWAREID
	print "  FirmwareID:\t", uuid_to_string($info), "\n";
    } else {
	print "MSFWID $cid decoding is not yet supported\n";
    }
}

my %decoder = (
    "BASIC_CONNECT" => \&decode_basic_connect,
    "USSD" => \&decode_ussd,
    "PHONEBOOK" => \&decode_phonebook,
    "STK" => \&decode_stk,
    "AUTH" => \&decode_auth,
    "SMS" => \&decode_sms,
    "DSS" => \&decode_dss,

#vendor specific
    "EXT_QMUX" => \&decode_ext_qmux,

    "MSFWID" => \&decode_msfwid,
    );

my %frag;

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
	print &status_to_string($status), " ($status)\n";

    } elsif ($type == 0x80000002) { # MBIM_CLOSE_DONE  
 	my $status = unpack("V", substr($msg, 12));
	print &status_to_string($status), " ($status)\n";

    } elsif ($type == 0x80000003 or $type == 0x00000003) { # MBIM_COMMAND_DONE or MBIM_COMMAND
	my ($total, $current) = unpack("VV", substr($msg, 12)); # FragmentHeader  
	print "MBIM_FRAGMENT_HEADER\n";
	printf "  TotalFragments:\t0x%08x\n", $total;
	printf "  CurrentFragment:\t0x%08x\n", $current;

	# cache fragments for later?
	if ($total > 1) {
	    my $key = sprintf "%08x-%d", $type, $tid;
	    if ($current == 0) {
		$frag{$key} = $msg;
	    } else {
		$frag{$key} .= substr($msg, 20);
	    }
	    return if ($current < $total - 1);
	    $msg = delete $frag{$key};
	}	    

	my $uuid = uuid_to_string(substr($msg, 20, 16));
	my $service = &uuid_to_service($uuid);
	print "$service ($uuid)\n";

	my ($cid, $status, $infolen) = unpack("VVV", substr($msg, 36));
	my $info = substr($msg, 48);
	print &cid_to_string($service, $cid), " ($cid)\n";
	if ($type == 0x80000003) {
	    print &status_to_string($status), " ($status)\n";
	} else {
	    print $status ? 'SET_COMMAND' : 'QUERY_COMMAND', " ($status)\n";
	}
	print "InformationBuffer [$infolen]:\n";

	if ($infolen != length($info)) {
	    print "Fragmented data is not yet supported\n";
	} elsif (exists($decoder{$service})) {
	    $decoder{$service}($cid, $info, $type == 0x00000003) if $infolen; # Only on success!
	} else {
	    print "decoding of $service CIDs is not yet supported\n";
	    printf "%02x " x $infolen, unpack("C*", $info);
	    print "\n";	    
	}
    } elsif ($type == 0x80000004) { # MBIM_FUNCTION_ERROR_MSG  
	my $status = unpack("V", substr($msg, 12));
	print &error_to_string($status), "($status)\n";
    } elsif ($type == 0x80000007) { # MBIM_INDICATE_STATUS_MSG  
	my ($total, $current) = unpack("VV", substr($msg, 12)); # FragmentHeader  
	print "MBIM_FRAGMENT_HEADER\n";
	print "  TotalFragments:\t$total\n";
	print "  CurrentFragment:\t$current\n";

	# cache fragments for later?
	if ($total > 1) {
	    my $key = sprintf "%08x-%d", $type, $tid;
	    if ($current == 0) {
		$frag{$key} = $msg;
	    } else {
		$frag{$key} .= substr($msg, 20);
	    }
	    return if ($current < $total - 1);
	    $msg = delete $frag{$key};
	}	    

	my $uuid = uuid_to_string(substr($msg, 20, 16));
	my $service = &uuid_to_service($uuid);
	print "$service ($uuid)\n";

	my ($cid, $infolen) = unpack("VV", substr($msg, 36));
	my $info = substr($msg, 44);
	print &cid_to_string($service, $cid), " ($cid)\n";

	print "InformationBuffer [$infolen]:\n";
	##print "InformationBuffer:\t$info\n";

	if ($infolen != length($info)) {
	    print "Fragmented data is not yet supported\n";
	} elsif (exists($decoder{$service})) {
	    $decoder{$service}($cid, $info);
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
		    warn("[" . localtime . "] read $n bytes from $mgmt\n") if $debug;
		    print "\n---\n" if $debug;
		    printf "%02x " x $n, unpack("C*", $tmp) if $debug;
		    print "\n---\n" if $debug;
		} else {
		    $found = 1;
		}
	    }

	    # get expected message length
	    $msglen = unpack("V", substr($raw, 4, 4));

	    if ($len >= $msglen) {
		$len -= $msglen;
		&decode_mbim(substr($raw, 0, $msglen));
		$raw = substr($raw, $msglen);
		$msglen = 0;
	    } else {
		warn "$len < $msglen\n";
	    }
	} while (!$found);
	alarm 0;
	warn "got match!\n" if ($found && $debug);
    };
    if ($@) {
	die unless $@ eq "alarm\n";   # propagate unexpected errors
    }
}


### QMI stuff ###

# QMI_CTL_MESSAGE_GET_VERSION_INFO
my $qmiver = pack("C*", map { hex } qw!01 0f 00 00 00 00 00 08 21 00 04 00 01 01 00 ff!);

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
    0xa  => "QMI_CAT2",
    0xb  => "QMI UIM",
    0xc  => "QMI PBM",
    0xe  => "QMI RMTFS",
    0x10 => "QMI_LOC",
    0x11 => "QMI_SAR",
    0x14 => "QMI_CSD",
    0x15 => "QMI_EFS",
    0x17 => "QMI_TS",
    0x18 => "QMI_TMD",
    0x1a => "QMI_WDA",
    0x1e => "QMI_QCMAP",
    0x24 => "QMI_PDC",
    0xe0 => "QMI_CAT", # duplicate!
    0xe1 => "QMI_RMS",
    0xe2 => "QMI_OMA",
    );

sub qmi_sysnum {
    my $sys = uc(shift);

    return $sys if ($sys =~ /^\d+$/);

    if ($sys =~ s/^0X//) {
	return hex($sys);
    }

    $sys = 'QMI_'. $sys unless ($sys =~ /^QMI_/);
    my ($num) = grep { $sys eq $sysname{$_} } keys %sysname;
    return $num || 0;
}

# create a QMI message
sub mk_qmi {
    my $sys = &qmi_sysnum(shift);
    my $cid = shift || 1;
    my $msgid = shift;
    return '' unless ($msgid =~ s/^0x([0-9a-f]{4})$/$1/i);
    $msgid = hex($msgid);

    # anything else is considered TLV contents
    #  e.g:  0x01 00 0x10 01 0f => { 0x01 => 0, 0x10 => 0x0f01 }
    my $tlv;
    my @data;
    my $tlvbytes = '';
    foreach my $arg (@_) {
	# anything starting with 0x is considered a new TLV number
	if ($arg =~ s/^0x([0-9a-f]{2})$/$1/i) {
	    if ($tlv) {
		# all TLVs need some data
		return '' unless @data;
		$tlvbytes .= pack("CvC*", $tlv, $#data+1, @data);
		@data = ();
	    }
	    $tlv = hex($arg);
	} elsif ($tlv && $arg =~ /^[0-9a-f]{2}$/i) {
	    push(@data, hex($arg));
	} else {
	    return '';
	}
    }

    # finish up the last TLV
    if ($tlv) {
	# all TLVs need some data
	return '' unless @data;
	$tlvbytes .= pack("CvC*", $tlv, $#data+1, @data);
    }

    my $tlvlen = length($tlvbytes);
    if ($sys == 0) { # QMI_CTL
	return pack("CvCCCCCvv", 1, 11 + $tlvlen, 0, 0, 0, 0, $tid, $msgid, $tlvlen) . $tlvbytes;
    } else {
	return pack("CvCCCCvvv", 1, 12 + $tlvlen, 0, $sys, $cid, 0, $tid, $msgid, $tlvlen) . $tlvbytes;
    }
}  

### main ###

# get the command
my $cmd = shift;

# decode an message from the command line
# e.g. 01:00:00:80:10:00:00:00:01:00:00:00:00:00:00:00
if ($cmd eq "offline") {
    &decode_mbim(pack("C*", map { hex } split(/:/, shift)));
    exit(0);
}

# open it now and keep it open until exit
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


if ($cmd eq "open") {
    print F &mk_open_msg;
} elsif ($cmd eq "caps") {
    print F &mk_cid_device_caps;
} elsif ($cmd eq "close") {
    print F &mk_close_msg;
} elsif ($cmd eq "pin") {
    print F &mk_cid_pin($pin{1}) if $pin{1};
} elsif ($cmd eq "connect") {
    print F &mk_cid_connect($apn, 1, $session);
} elsif ($cmd eq "ipv6") {
    print F &mk_ipv6_connect($apn, 1, $session);
} elsif ($cmd eq "mms") {
    print F &mk_mms_connect($apn, 1, $session);
} elsif ($cmd eq "disconnect") {
    print F &mk_cid_connect('', 0, $session);
} elsif ($cmd eq "attach") {
    print F &mk_cid_packet_service(1);
} elsif ($cmd eq "detach") {
    print F &mk_cid_packet_service(0);
} elsif ($cmd eq "getreg") {
    print F &mk_cid_register_state();
} elsif ($cmd eq "getradiostate") {
    print F &mk_cid_radio_state;
} elsif ($cmd eq "setradiostate") {
    print F &mk_cid_radio_state(1);
} elsif ($cmd eq "getservices") {
    print F &mk_command_msg('BASIC_CONNECT', 16, 0, '');
} elsif ($cmd eq "getip") {
    print F &mk_command_msg('BASIC_CONNECT', 15, 0, pack("V15",  $session, 0 x 14));
} elsif ($cmd eq "dssconnect") {
    print F &mk_cid_dss_connect(shift, 1, $session);
} elsif ($cmd eq "dssdisconnect") {
    print F &mk_cid_dss_connect(shift, 0, $session);
} elsif ($cmd eq "monitor") {
    &read_mbim;
} elsif ($cmd eq "qmi") {
    if (defined($qmisys)) {
	print F &mk_command_msg('EXT_QMUX', 1, 1, &mk_qmi($qmisys, $qmicid, @ARGV));
    } else {
	print F &mk_command_msg('EXT_QMUX', 1, 1, pack("C*", map { hex } @ARGV));
    }
} elsif ($cmd eq "qmiver") {
    print F &mk_command_msg('EXT_QMUX', 1, 1, $qmiver);
} elsif ($cmd eq "unknown") {
    print F &mk_command_msg(shift, shift, 1, pack("C*", map { hex } @ARGV));
} elsif ($cmd eq "getunknown") {
    print F &mk_command_msg(shift, shift, 0, pack("C*", map { hex } @ARGV));
} else {
    &usage;
}

# close device
close(F);








##########



##########

sub decodesms {
##    my ($dir, $smshex)=@_;
    my ($dir, $data)=@_;

##    my $data= pack("H*", $smshex);
    my $ofs= 0;
    my $smsclen= unpack("C", substr($data, $ofs++, 1));
    my $smscdata= substr($data, $ofs, $smsclen);
    $ofs+=$smsclen;

    printf("smsc: %s\n", decode_address($smscdata));

    # if direction not known, assume it is outgoing when the smsc length == 0
    my $incoming= defined $dir ? $dir : $smsclen!=0;

    my $pduhdr= unpack("C", substr($data, $ofs++, 1));
    my $mti= ($pduhdr&3);
    my $pdutype= $pdutypes[$mti][$incoming];

    printf("%s %s\n", $pdutype, $mti?"done":"");

    if (hasfield($pdutype, "MR")) {
        # message reference
        my $mr= unpack("C", substr($data, $ofs++, 1));
        printf("MR: %02x\n", $mr);
    }
    if (hasfield($pdutype, "DA") || hasfield($pdutype, "OA")) {
        # destination/originating address
        my $srclen= unpack("C", substr($data, $ofs++, 1));
        my $srcnum= substr($data, $ofs, ($srclen-1)/2+2);
        $ofs += ($srclen-1)/2+2;
        printf("%s: %s\n", hasfield($pdutype, "DA")?"DA":hasfield($pdutype, "OA")?"OA":"??",
            decode_address($srcnum));
    }
    if (hasfield($pdutype, "PID")) {
        # protocol id
        # todo 
        my $protocol= unpack("C", substr($data, $ofs++, 1));
        printf("prot: %02x\n", $protocol);
        # 0x00
        # 0x0b
        # 0x0d
        # 0x10
    }
    my $dcs;
    if (hasfield($pdutype, "DCS")) {
        # data coding scheme
        # todo , see 23.038
        $dcs= unpack("C", substr($data, $ofs++, 1));
        printf("dcs: %02x\n", $dcs);
    }
    if (hasfield($pdutype, "VP") && ($pduhdr&0x18)) {
        # validity period
        my $vpf= ($pduhdr&0x18)>>3;
        my @fmt=qw(- rel enh abs);
        # rel: 1 byte
        # abs: 7 bytes
        # enh: 7 bytes
        if ($vpf==1) {
            my $vp= unpack("C", substr($data, $ofs++, 1));
            printf("VP: %s %d\n", $fmt[$vpf], $vp);
        }
        else {
            my $vp= substr($data, $ofs, 7);
            $ofs+=7;
            printf("VP: %s %s\n", $fmt[$vpf], unpack 'H*',$vp);
        }
    }
    if (hasfield($pdutype, "SCTS")) {
        # sc timestamp
        my $scts= unpack 'H*', unpack("a7", substr($data, $ofs, 7));
        $ofs+=7;
        $scts =~ s/(\w)(\w)/$2$1/g;
        printf("scts: %s\n", $scts);
    }
    my $udl;
    if (hasfield($pdutype, "UDL")) {
        # userdata length
        $udl= unpack("C", substr($data, $ofs++, 1));
    }
    if (hasfield($pdutype, "UD")) {
        # user data
        # $dcs=08 : unicode
        # $dcs=11 : 7bit
        if ($dcs&0x20) {
            printf("compressed[%02x]: %s\n", $udl, unpack("H*", substr($data, $ofs)));
        }
        elsif (($dcs&0x0c)==0) {
            # 7 bit data
            my $b7len= int(($udl*7)/8)+1;
            my $ud= substr($data, $ofs, $b7len);
            $ofs += $b7len;
	    my $dcode = substr(sms7to8bit($ud),0,$udl*2);
            printf("msg: '%s'\n", $dcode);
	    $dcode =~ tr/\@//d;
	    printf("msg: '%s'\n", decode('utf8', $dcode)) ;
        }
        elsif (($dcs&0x0c)==0x04) {
            # 8 bit data
            my $ud= substr($data, $ofs, $udl);
            $ofs += ($udl*7)/8;
            printf("msg: '%s'\n", $ud);
        }
        elsif (($dcs&0x0c)==0x08) {
            # ucs2 data
            my $ud= substr($data, $ofs, $udl);
            $ofs += $udl;
            printf("msg: U'%s'\n", pack("U*", unpack("n*",$ud)));
        }
        # 0x91
        # 0xd0
        else {
            printf("msg: unknown encoding: %s\n", unpack("H*", substr($data, $ofs)));
        }
    }
    printf("leftover: %d\n", length($data)-$ofs);
}

sub decode_address {
    return "-" if ($_[0] eq "");
    my ($typebyte, $addr)= unpack("Ca*", $_[0]);
    my ($one, $type, $plan)=(($typebyte>>7)&1, ($typebyte>>4)&7, $typebyte&0xf);

    return sprintf("%d.%s.%s:%s", $one, $numtypes[$type], $plantypes[$plan], decodenumber($addr, $type))
}
sub sms7to8bit {
my @xlat= (
"@", "Â£", "\$", "Â¥", "eÌ€", "eÌ", "uÌ€", "iÌ€", "oÌ€", "CÌ§", "\n", "Ã˜", "Ã¸", "\r", "AÌŠ", "aÌŠ",
"âˆ†", "_", "Î¦", "Î“", "Î›", "Î©", "Î ", "Î¨", "Î£", "Î˜", "Îž", "\x1b", "Ã†", "Ã¦", "ÃŸ", "EÌ", 
"\x20", "!", "\x22", "#", "Â¤", "%", "&", "\x27", "(", ")", "*", "+", ",", "-", ".", "/",
"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
"Â¡", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
"P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "AÌˆ", "OÌˆ", "NÌƒ", "UÌˆ", "Â§",
"Â¿", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
"p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "aÌˆ", "oÌˆ", "nÌƒ", "uÌˆ", "a",

);
my @xlat2= (
" ", " ", " ", " ", " ", " ", " ", " ", " ", " ", "\x03", " ", " ", " ", " ", " ",
" ", " ", " ", " ", "^", " ", " ", " ", " ", " ", " ", "\x1b", " ", " ", " ", " ",
" ", " ", " ", " ", " ", " ", " ", " ", "{", "}", " ", " ", " ", " ", " ", "\\",
" ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", "[", "~", "]", " ",
"|", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ",
" ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ",
" ", " ", " ", " ", " ", "â‚¬", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ",
" ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ",
);

my $esc;
#    printf("xx-%s\n", unpack("H*", $_[0]));
    my $bits= unpack("b*", $_[0]);
#    if (length($bits)%7) { $bits=substr($bits, 0, -(length($bits)%7)); }
    return join "", map { if ($esc) { $esc--; $xlat2[ord($_)] } elsif ($_ eq "\x1b") { $esc++ } else { $xlat[ord($_)] } } map { pack("b*", $_) } split /(\d{7})/, $bits;
}
sub decodenumber {
    my ($numdata, $type)= @_;
    if ($type==5) {
        my $str= sms7to8bit($numdata);
        $str =~ s/\x00$//;
        return $str;
    }
    else {
        (my $nr= unpack 'H*', $numdata) =~ s/(\w)(\w)/$2$1/g;
        return $nr;
    }
}
