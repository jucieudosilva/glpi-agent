package FusionInventory::Agent::Tools::Unix;

use strict;
use warnings;
use base 'Exporter';

use English qw(-no_match_vars);
use File::stat;
use File::Which;
use Memoize;
use Time::Local;

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Network;

our @EXPORT = qw(
    getDeviceCapacity
    getIpDhcp
    getFilesystemsFromDf
    getFilesystemsTypesFromMount
    getProcessesFromPs
    getRoutingTable
);

memoize('getProcessesFromPs');

sub getDeviceCapacity {
    my (%params) = @_;

    return unless $params{device};

    # GNU version requires -p flag
    my $command = getFirstLine(command => '/sbin/fdisk -v') =~ '^GNU' ?
        "/sbin/fdisk -p -s $params{device}" :
        "/sbin/fdisk -s $params{device}"    ;

    my $capacity = getFirstLine(
        command => $command,
        logger  => $params{logger},
    );

    $capacity = int($capacity / 1000) if $capacity;

    return $capacity;
}

sub getIpDhcp {
    my ($logger, $if) = @_;

    my $dhcpLeaseFile = _findDhcpLeaseFile($if);

    return unless $dhcpLeaseFile;

    _parseDhcpLeaseFile($logger, $if, $dhcpLeaseFile);
}

sub _findDhcpLeaseFile {
    my ($if) = @_;

    my @directories = qw(
        /var/db
        /var/lib/dhcp3
        /var/lib/dhcp
        /var/lib/dhclient
    );
    my @patterns = ("*$if*.lease", "*.lease");
    my @files;

    foreach my $directory (@directories) {
        next unless -d $directory;
        foreach my $pattern (@patterns) {

            push @files,
                grep { -s $_ }
                glob("$directory/$pattern");
        }
    }

    return unless @files;

    # sort by creation time
    @files =
        map { $_->[0] }
        sort { $a->[1]->ctime() <=> $b->[1]->ctime() }
        map { [ $_, stat($_) ] }
        @files;

    # take the last one
    return $files[-1];
}

sub _parseDhcpLeaseFile {
    my ($logger, $if, $lease_file) = @_;


    my $handle = getFileHandle(file => $lease_file, logger => $logger);
    return unless $handle;

    my ($lease, $dhcp, $server_ip, $expiration_time);

    # find the last lease for the interface with its expire date
    while (my $line = <$handle>) {
        if ($line=~ /^lease/i) {
            $lease = 1;
            next;
        }
        if ($line=~ /^}/) {
            $lease = 0;
            next;
        }

        next unless $lease;

        # inside a lease section
        if ($line =~ /interface\s+"([^"]+)"/){
            $dhcp = ($1 eq $if);
            next;
        }

        next unless $dhcp;

        if (
            $line =~
            /option \s+ dhcp-server-identifier \s+ (\d{1,3}(?:\.\d{1,3}){3})/x
        ) {
            # server IP
            $server_ip = $1;
        } elsif (
            $line =~
            /expire \s+ \d \s+ (\d+)\/(\d+)\/(\d+) \s+ (\d+):(\d+):(\d+)/x
        ) {
            my ($year, $mon, $day, $hour, $min, $sec)
                = ($1, $2, $3, $4, $5, $6);
            # warning, expected ranges is 0-11, not 1-12
            $mon = $mon - 1;
            $expiration_time = timelocal($sec, $min, $hour, $day, $mon, $year);
        }
    }
    close $handle;

    return unless $expiration_time;

    my $current_time = time();

    return $current_time <= $expiration_time ? $server_ip : undef;
}

sub getFilesystemsFromDf {
    my (%params) = @_;
    my $handle = getFileHandle(%params);

    my @filesystems;

    # get headers line first
    my $line = <$handle>;
    return unless $line;

    chomp $line;
    my @headers = split(/\s+/, $line);

    while (my $line = <$handle>) {
        chomp $line;
        my @infos = split(/\s+/, $line);

        # depending on the df implementation, and how it is called
        # the filesystem type may appear as second colum, or be missing
        # in the second case, it has to be given by caller
        my ($filesystem, $total, $free, $type);
        if ($headers[1] eq 'Type') {
            $filesystem = $infos[1];
            $total      = $infos[2];
            $free       = $infos[4];
            $type       = $infos[6];
        } else {
            $filesystem = $params{type};
            $total      = $infos[1];
            $free       = $infos[3];
            $type       = $infos[5];
        }

        # skip some virtual filesystems
        next if $total !~ /^\d+$/ || $total == 0;
        next if $free  !~ /^\d+$/ || $free  == 0;

        push @filesystems, {
            VOLUMN     => $infos[0],
            FILESYSTEM => $filesystem,
            TOTAL      => int($total / 1024),
            FREE       => int($free / 1024),
            TYPE       => $type
        };
    }

    close $handle;

    return @filesystems;
}

sub getFilesystemsTypesFromMount {
    my (%params) = (
        command => 'mount',
        @_
    );

    my $handle = getFileHandle(%params);
    return unless $handle;

    my @types;
    while (my $line = <$handle>) {
        # BSD-style:
        # /dev/mirror/gm0s1d on / (ufs, local, soft-updates)
        if ($line =~ /^\S+ on \S+ \((\w+)/) {
            push @types, $1;
            next;
        }
        # Linux style:
        # /dev/sda2 on / type ext4 (rw,noatime,errors=remount-ro)
        if ($line =~ /^\S+ on \S+ type (\w+)/) {
            push @types, $1;
            next;
        }
    }
    close $handle;

    ### raw result: @types

    return
        uniq
        @types;
}

sub getProcessesFromPs {
    my $ps = which('ps');
    return -l $ps && readlink($ps) eq 'busybox' ? _getProcessesBusybox(@_) :
                                                  _getProcessesOther(@_)   ;
}

sub _getProcessesBusybox {
    my (%params) = (
        command => 'ps',
        @_
    );

    my $handle = getFileHandle(%params);

    # skip headers
    my $line = <$handle>;

    my @processes;

    while ($line = <$handle>) {
        next unless $line =~
            /^
            \s* (\S+)
            \s+ (\S+)
            \s+ (\S+)
            \s+ ...
            \s+ (\S.+)
            /x;
        my $pid   = $1;
        my $user  = $2;
        my $vsz   = $3;
        my $cmd   = $4;

        push @processes, {
            USER          => $user,
            PID           => $pid,
            VIRTUALMEMORY => $vsz,
            CMD           => $cmd
        };
    }

    close $handle;

    return @processes;
}

sub _getProcessesOther {
    my (%params) = (
        command =>
            'ps -A -o user,pid,pcpu,pmem,vsz,tty,stime,time,' .
            ($OSNAME eq 'solaris' ? 'comm' : 'command'),
        @_
    );

    my $handle = getFileHandle(%params);

    # skip headers
    my $line = <$handle>;

    my (undef, undef, undef, $day, $month, $year) = localtime(time());
    $year = $year + 1900;
    $month = $month + 1;

    my @processes;

    while ($line = <$handle>) {
        next unless $line =~
            /^
            (\S+) \s+
            (\S+) \s+
            (\S+) \s+
            (\S+) \s+
            (\S+) \s+
            (\S+) \s+
            (\S+) \s+
             \S+ \s+
            (.*\S)
            /x;
        my $user  = $1;
        my $pid   = $2;
        my $cpu   = $3;
        my $mem   = $4;
        my $vsz   = $5;
        my $tty   = $6;
        my $start = $7;
        my $cmd   = $8;

        push @processes, {
            USER          => $user,
            PID           => $pid,
            CPUUSAGE      => $cpu,
            MEM           => $mem,
            VIRTUALMEMORY => $vsz,
            TTY           => $tty,
            STARTED       => _getProcessStartTime($start, $day, $month, $year, $pid),
            CMD           => $cmd
        };
    }

    close $handle;

    return @processes;
}

my %month = (
    Jan => '01',
    Feb => '02',
    Mar => '03',
    Apr => '04',
    May => '05',
    Jun => '06',
    Jul => '07',
    Aug => '08',
    Sep => '09',
    Oct => '10',
    Nov => '11',
    Dec => '12',
);
my %day = (
    Mon => '01',
    Tue => '02',
    Wed => '03',
    Thu => '04',
    Fry => '05',
    Sat => '06',
    Sun => '07',
);
my $monthPattern = join ('|', keys %month);

# consistant time format
sub _getProcessStartTime {
    my ($start, $day, $month, $year, $pid) = @_;

    if ($start =~ /^(\d{1,2}):(\d{2})/) {
        # 10:00PM
        return sprintf("%04d-%02d-%02d %s", $year, $month, $day, $start);
    }

    if ($start =~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)(\d{2})[AP]M/) {
        # Sat03PM
        my $start_day = $2;
        return sprintf("%04d-%02d-%02d", $year, $month, $start_day);
    }

    if ($start =~ /^($monthPattern)(\d{2})/) {
        # Apr03
        my $start_month = $month{$1};
        my $start_day = $2;
        return sprintf("%04d-%02d-%02d", $year, $start_month, $start_day);
    }

    if ($start =~ /^(\d{1,2})($monthPattern)\d{1,2}/) {
        # 5Oct10
        my $start_day = $1;
        my $start_month = $month{$2};
        return sprintf("%04d-%02d-%02d", $year, $start_month, $start_day);
    }

    if (-f "/proc/$pid") {
        # this will work only on OS with /proc/$pid like Linux and FreeBSD
        my $stat = stat("/proc/$pid");
        my ($sec, $min, $hour, $day, $month, $year) = localtime($stat->ctime());
        $year = $year + 1900;
        $month = $month + 1;
        return sprintf("%04d-%02d-%02d %s:%s", $year, $month, $day, $hour, $min);
    }
}

sub getRoutingTable {
    my (%params) = (
        command => 'netstat -nr -f inet',
        @_
    );

    my $handle = getFileHandle(%params);
    return unless $handle;

    my $routes;

    # first, skip all header lines
    while (my $line = <$handle>) {
        last if $line =~ /^Destination/;
    }

    # second, collect routes
    while (my $line = <$handle>) {
        next unless $line =~ /^
            (
                $ip_address_pattern
                |
                $network_pattern
                |
                default
            )
            \s+
            (
                $ip_address_pattern
                |
                $mac_address_pattern
                |
                link\#\d+
            )
            /x;
        $routes->{$1} = $2;
    }
    close $handle;

    return $routes;
}

1;
__END__

=head1 NAME

FusionInventory::Agent::Tools::Unix - Unix-specific generic functions

=head1 DESCRIPTION

This module provides some Unix-specific generic functions.

=head1 FUNCTIONS

=head2 getDeviceCapacity(%params)

Returns storage capacity of given device, using fdisk.

Availables parameters:

=over

=item logger a logger object

=item device the device to use

=back

=head2 getIpDhcp

Returns an hashref of information for current DHCP lease.

=head2 getFilesystemsFromDf(%params)

Returns a list of filesystems as a list of hashref, by parsing given df command
output.

=over

=item logger a logger object

=item command the exact command to use

=item file the file to use, as an alternative to the command

=back

=head2 getFilesystemsTypesFromMount(%params)

Returns a list of used filesystems types, by parsing given mount command
output.

=over

=item logger a logger object

=item command the exact command to use

=item file the file to use, as an alternative to the command

=back

=head2 getProcessesFromPs(%params)

Returns a list of processes as a list of hashref, by parsing given ps command
output.

=over

=item logger a logger object

=item command the exact command to use

=item file the file to use, as an alternative to the command

=back

=head2 getRoutingTable

Returns the routing table as an hashref, by parsing netstat command output.

=over

=item logger a logger object

=item command the exact command to use (default: netstat -nr -f inet)

=item file the file to use, as an alternative to the command

=back
