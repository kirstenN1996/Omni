package Omni::Leads;
use strict;
use Data::Dumper;
use Carp qw(croak);
use LWP::UserAgent;
use HTTP::Cookies;
use URI::Escape::XS;
use Affinity::Validate;
use Redis::Client;

our $domain  = "http://prosales.affinityhealth.co.za";

sub new 
{
        my $class = shift;
        my $script = shift;

        my $self = {
                script => $script,
                ua     => LWP::UserAgent->new,
                cookie_jar => HTTP::Cookies->new( file     => "prosales_cookies.txt", autosave => 1),
        };
    
        $self->{ua}->cookie_jar($self->{cookie_jar});
        bless $self, $class;
        return $self;
}

sub login
{
    print STDERR "Login to Prosales\n";
    my $self    = shift;
    my $url = $domain."/session/authenticate?user=prosales&pass=e4D9V2JNw5jA";
    my $response = $self->{ua}->get($url);
    if($response->is_success){
            my $data =  $self->{script}->decode($response->decoded_content());
            if($data->{status} eq "success"){
                    my $session = $data->{data}->{session_key};
                    $self->{cookie_jar}->set_cookie(0,'session_key',$session, '/', 'prosales.affinityhealth.co.za');
            }else{
                    die "Login returned $data->{data}->{error}\n";
            }
    }else{
            die "Login Failed to connect, $response->status_line\n";
    }
}

sub get_profile
{
    my $self = shift;
    my $num = shift;
    my $url = $domain."/profile/get?tel=$num";

    print "Get Prosales Profiule for $num\n";
    my $response = $self->{ua}->get($url);

    if($response->is_success){
            my $p = $self->{script}->decode($response->decoded_content());
            if($p->{status} eq "success"){
                    return $p->{data};
            }else{
                    croak "ERROR Fetching Profile $p->{data}->{error}\n";
            }
    }else{
            croak "Login Failed to connect, $response->status_line\n";
    }

}

sub update_prosales
{
        my $self = shift;
        my $P = shift;
        my $api_data = shift;
        my $vsd  = $self->{script}->getdb("prosales");

        my $sql = qq{SELECT CONCAT(start, ' - ',end) AS band FROM scheme_income_bands WHERE "$api_data->{income}" BETWEEN start AND end};
        my $rep = $vsd->prepare($sql);
        $rep->execute || croak "could not check for income band\n";
        my($band) = $rep->fetchrow_array();
        $rep->finish;

        my $marital;
        if($api_data->{spouse} eq "yes"){
                $marital = "Married";
        }else{
                $marital = "Single";
        }

        print STDERR "band is $band\n";

        $P->{first_name} = $api_data->{firstname} unless(!$api_data->{firstname});
        $P->{surname} = $api_data->{surname} unless(!$api_data->{surname});
        $P->{marital} = $marital unless(!$marital);
        $P->{record_of_advice}->{budget} = $api_data->{budget} unless(!$api_data->{budget});
        $P->{record_of_advice}->{children} = $api_data->{children} unless(!$api_data->{children});
        $P->{record_of_advice}->{adults} = $api_data->{adults} unless(!$api_data->{adults});
        $P->{record_of_advice}->{income_band} = $band unless(!$band);
        $P->{whatsapp_available} = 1;
        $P->{profile_modified} = time();

        return $P;
}

sub save_profile
{
        my $self = shift;
        my $num = shift;
        my $data = shift;
        my $redis = Redis::Client->new(host => "10.0.101.61");
        my $validate = Affinity::Validate->new();
        my $key = $validate->phone_number($num);


        if($key){
                my $json = $self->{script}->encode($data);
                $redis->select(2);
                $redis->set($key,$json);
                $redis->persist($key);
        }
}


1;