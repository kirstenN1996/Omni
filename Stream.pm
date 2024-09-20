package Omni::Stream;
use strict;
use Redis;
use JSON::XS;
use Data::Dumper;


sub new {
    my $class = shift;
    my ($stream_server, $stream_port,$stream_pass) = @_;
       
    my $redis = Redis->new(server => "$stream_server:$stream_port");
	$redis->auth($stream_pass);	
    my $self = {
        stream_server => $stream_server,
        stream_port   => $stream_port,
		coder => JSON::XS->new->utf8->allow_nonref->allow_blessed->convert_blessed->pretty,
		redis => $redis
	};

    bless $self, $class;
    return $self;
}

sub add
{
	my $self = shift;
	my $stream_name = shift;
	my $data = shift;
	my $json = $self->{coder}->encode($data);
	my $stream = $stream_name;
	$self->{redis}->select(0);
	my $id = $self->{redis}->xadd( $stream, "*", "data", $json );
	return $id;
}

sub get
{
	my $self = shift;
	my $stream = shift;

	###use db3 to get last processed
	$self->{redis}->select(3);
	my $last_processed = $self->{redis}->get($stream) || '0-0';

	##switch back to db0 for streams
	$self->{redis}->select(0);


    my @response = $self->{redis}->xread('COUNT', 2, 'STREAMS', $stream, $last_processed);
    return \@response;
}

1;
