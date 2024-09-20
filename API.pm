package Omni::API;
use strict;
use Omni::Inbound;
use Omni::Outbound;
use Omni::Admin;

sub new
{
        my $class = shift;
        my $self = {};
        bless $self,$class;
        return $self;
}

sub inbound
{
	my $self = shift;
	bless return Omni::Inbound->new(@_);
}

sub outbound
{
	my $self = shift;
	bless return Omni::Outbound->new(@_);
}

sub admin
{
	my $self = shift;
	bless return Omni::Admin->new(@_);
}
1;
