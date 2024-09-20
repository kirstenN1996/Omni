package Omni::Irdsa;
use strict;
use Data::Dumper;
use Carp qw(croak);
use Text::Levenshtein qw(distance);

sub new 
{
    my $class = shift;
    my $self->{script} = shift;
    bless $self, $class;
    return $self;
}

sub validate_irdsa_menu 
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    if ( $received_answer == 1 ) {
        print "continue with items\n";
        return { valid => 1 };
    } elsif ( $received_answer == 2 ) {
        ###cant go to agent direct yet as needs to be assigned to agent with valid sid
        print "move to agent_direct stream\n";
        return { valid => 1 };
    }else{
        return { valid => 0 };
    }
}

sub validate_irdsa_fname
{
    return { valid => 1 };
}

sub validate_irdsa_sname
{
    return { valid => 1 };
}
sub validate_irdsa_spouse
{
    return { valid => 1 };
}
sub validate_irdsa_deps
{
    return { valid => 1 };
}
sub validate_irdsa_deps
{
    return { valid => 1 };
}
sub validate_irdsa_budget
{
    return { valid => 1 };
}
sub validate_irdsa_income
{
    return { valid => 1 };
}


1;
