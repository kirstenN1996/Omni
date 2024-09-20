package Omni::Config;
use strict;
use DBI;
use Redis;

sub new
{
	my $class = shift;
	my $self = {
		database => {
			omni => DBI->connect("dbi:mysql:omni:127.0.0.1","omni",'@idbcmf117#'),
			# rfli => DBI->connect("dbi:mysql:chfportal:crm.affinityhealth.co.za","apiCalls",']|:nt3435'),
			# health => DBI->connect("dbi:mysql:affinity:crm.affinityhealth.co.za","apiCalls",']|:nt3435')
		},
		redis =>
		{
			omni => Redis->new(server   => "127.0.0.1:6379", password => 'yL?V3DP+!}B85K)A')
		}	
	};

	bless $self,$class;
	return $self;
}

sub getdb
{
	my $self = shift;
	my $db = shift;
	return $self->{database}->{$db};
}


sub redis
{
	my $self = shift;
	my $redis = shift;
	return $self->{redis}->{$redis};
}
1;
