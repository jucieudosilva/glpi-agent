package FusionInventory::Agent::SOAP::WsMan::MessageID;

use strict;
use warnings;

use FusionInventory::Agent::SOAP::WsMan::Node;

package
    MessageID;

use parent 'Node';

use English qw(-no_match_vars);
use UNIVERSAL::require;

use Data::UUID;

use constant    xmlns   => 'a';

sub new {
    my ($class, %params) = @_;

    return $class->SUPER::new(%params) if %params;

    my $uuid_gen = Data::UUID->new();
    my $uuid = $uuid_gen->create_str();

    my $self = $class->SUPER::new('#text' => "uuid:$uuid");

    $self->{_uuid} = $uuid;

    bless $self, $class;
    return $self;
}

sub uuid {
    my ($self) = @_;

    return $self->{_uuid} if $self->{_uuid};
}

sub reset_uuid {
    my ($self) = @_;
    my $uuid_gen = Data::UUID->new();
    my $uuid = $uuid_gen->create_str();

    $self->{_uuid} = $uuid;

    return $self->string("uuid:$uuid");
}

1;