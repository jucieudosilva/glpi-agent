package FusionInventory::Agent::Task::Inventory::Generic::Databases::MSSQL;

use English qw(-no_match_vars);

use strict;
use warnings;

use parent 'FusionInventory::Agent::Task::Inventory::Generic::Databases';

use FusionInventory::Agent::Tools;
use GLPI::Agent::Inventory::DatabaseService;

sub isEnabled {
    return canRun('sqlcmd');
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};

    my $dbservices = _getDatabaseService(%params);

    foreach my $dbs (@{$dbservices}) {
        $inventory->addEntry(
            section => 'DATABASES_SERVICES',
            entry   => $dbs->entry(),
        );
    }
}

sub _getDatabaseService {
    my (%params) = @_;

    # Try to retrieve credentials
    my $credentials = FusionInventory::Agent::Task::Inventory::Generic::Databases::_credentials(\%params, "mssql");

    return [] unless $credentials && ref($credentials) eq 'ARRAY';

    my @dbs = ();

    foreach my $credential (@{$credentials}) {
        $params{options} = _mssqlOptions($credential) // "";

        my $productversion = _runSql(
            sql     => "SELECT SERVERPROPERTY('productversion')",
            %params
        )
            or next;

        my $version =_runSql(
            sql     => "SELECT \@\@version",
            %params
        )
            or next;
        my ($manufacturer, $name) = $version =~ /^
            (Microsoft) \s+
            (SQL \s+ Server \s+ \d+)
        /xi
            or next;

        my $dbs_size = 0;
        my $starttime = _runSql(
            sql => "SELECT sqlserver_start_time FROM sys.dm_os_sys_info",
            %params
        );
        $starttime =~ s/\..*$//;

        my $dbs = GLPI::Agent::Inventory::DatabaseService->new(
            type            => "mssql",
            name            => $name,
            version         => $productversion,
            manufacturer    => $manufacturer,
            port            => $credential->{port} // "1433",
            is_active       => 1,
            last_boot_date  => $starttime,
        );

        foreach my $db (_runSql(
            sql => "SELECT name,create_date,state FROM sys.databases",
            %params
        )) {
            my ($db_name, $db_create, $state) = $db =~ /^(\S+);([^.]*)\.\d+;(\d+)$/
                or next;

            my ($size) = _runSql(
                sql => "USE $db_name ; EXEC sp_spaceused",
                %params
            ) =~ /^$db_name;([0-9.]+\s*\S+);/;
            if ($size) {
                $size = getCanonicalSize($size, 1024);
                $dbs_size += $size;
            } else {
                undef $size;
            }

            # Find update date
            my ($updated) = _runSql(
                sql => "USE $db_name ; SELECT TOP(1) modify_date FROM sys.objects ORDER BY modify_date DESC",
                %params
            ) =~ /^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/;

            $dbs->addDatabase(
                name            => $db_name,
                size            => int($size),
                is_active       => int($state) == 0 ? 1 : 0,
                creation_date   => $db_create,
                update_date     => $updated,
            );
        }

        $dbs->size(int($dbs_size));

        push @dbs, $dbs;
    }

    return \@dbs;
}

sub _runSql {
    my (%params) = @_;

    my $sql = delete $params{sql}
        or return;

    my $command = "sqlcmd";
    $command .= $params{options} if defined($params{options});
    $command .= " -X1 -l 30 -t 30 -K ReadOnly -r1 -W -h -1 -s \";\" -Q \"$sql\"";

    # Only to support unittests
    if ($params{file}) {
        $sql =~ s/\s+/-/g;
        $sql =~ s/[^-_0-9A-Za-z]//g;
        $sql =~ s/[-][-]+/-/g;
        $params{file} .= "-" . lc($sql);
        unless (-e $params{file}) {
            print STDERR "Generating $params{file} for new MSSQL test case...\n";
            system("$command >$params{file}");
        }
    } else {
        $params{command} = $command;
    }

    if (wantarray) {
        return map { chomp; s/\r$//; $_ } getAllLines(%params);
    } else {
        my $result = getFirstLine(%params);
        chomp($result);
        $result =~ s/\r$//;
        return $result;
    }
}

sub _mssqlOptions {
    my ($credential) = @_;

    return unless $credential->{type};

    my $options = "";
    if ($credential->{type} eq "login_password") {
        $options .= " -S $credential->{host}" if $credential->{host};
        $options .= ",$credential->{port}" if $credential->{host} && $credential->{port};
        $options .= " -U $credential->{login}" if $credential->{login};
        $options .= " -S $credential->{socket}" if ! $credential->{host} && $credential->{socket};
        $options .= " -P $credential->{password}" if $credential->{password};
    }

    return $options;
}

1;
