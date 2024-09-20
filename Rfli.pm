package Omni::Rfli;
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

sub validate_rfli_pnum 
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $redis = $self->{script}->redis("local");
    my $dbh = $self->{script}->getdb("health");

    if ( $received_answer =~ /^\d\d{12}$/ ) {
        my $sql = qq{SELECT `nbc_members`.* ,`nbc_cell`.`cell`
                    FROM `nbc_members`
                    LEFT JOIN `nbc_cell`
                    ON `nbc_members`.`nbc_eeno` = `nbc_cell`.`nbc_eeno`
                    WHERE `nbc_members`.`idno`="$received_answer"
                    AND CONV(LEFT(RIGHT(`phex`,((YEAR(DATE_FORMAT(CURDATE(), '%Y-%m-01'))-2014)*4)+11),3),16,10) & POW(2,MONTH(DATE_FORMAT(CURDATE(), '%Y-%m-01'))-1)
	    };
        print $sql. "\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || die();
        if ( $rep->rows > 0 ) {
            #$api_data->{info}->{policy} = $rep->fetchrow_hashref();
            my $policy_data = $rep->fetchrow_hashref(); 
            $api_data->{info}->{policy} = {
                firstname => $policy_data->{initials},
                surname   => $policy_data->{surname},
                zaid      => $policy_data->{idno},
                policy_no => $policy_data->{nbc_eeno},
                cellno    => $policy_data->{cell},
                company   => "",
                src       => "rfli",
                pdckey    => "",
            };
        }
        $rep->finish();

        if(defined($api_data->{info}->{policy}) || $api_data->{info}->{policy} ne "") {
            my $sql = qq{select * from nbc_dependents where main_member_id="$api_data->{info}->{policy}->{zaid}"};
            print STDERR $sql."\n";
            my $rep = $dbh->prepare($sql);
            $rep->execute || die();
            if ( $rep->rows > 0 ) {
                $api_data->{info}->{policy}->{deps} = [];
                while (my $row = $rep->fetchrow_hashref()) {
                    push @{$api_data->{info}->{policy}->{deps}}, $row;
                }
            }
            $rep->finish();
            return { valid => 1 };
        }else{
            return { valid => 0 };
        }
    }else{
        return { valid => 0 };
    }
}

sub validate_rfli_initials 
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $str1 = lc($received_answer);
    my $str2 = lc($api_data->{info}->{policy}->{firstname});

    print "$str1 and $str2\n";

   # Split both strings into individual words
    my @words1 = split(/\s+/, $str1);
    my @words2 = split(/\s+/, $str2);

    my $max_similarity = 0;

    # Compare each word in the first string with each word in the second string
    for my $word1 (@words1) {
        for my $word2 (@words2) {
            # Calculate Levenshtein distance between the two words
            my $distance = distance($word1, $word2);

            # Normalize distance to get similarity score
            my $max_length = length($word1) > length($word2) ? length($word1) : length($word2);
            my $similarity = 1 - ($distance / $max_length);

            # Update max_similarity if the current similarity is greater
            $max_similarity = $similarity if $similarity > $max_similarity;
        }
    }

    return $max_similarity > 0.75 ? { valid => 1 } : { valid => 0 }; # Return true if max_similarity is greater than 0.75, otherwise return false
}

sub validate_rfli_surname 
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $str1 = lc($received_answer);
    my $str2 = lc($api_data->{info}->{policy}->{surname});

    print "$str1 and $str2\n";

    # Split both strings into individual words
    my @words1 = split(/\s+/, $str1);
    my @words2 = split(/\s+/, $str2);

    my $max_similarity = 0;

    # Compare each word in the first string with each word in the second string
    for my $word1 (@words1) {
        for my $word2 (@words2) {
            # Calculate Levenshtein distance between the two words
            my $distance = distance($word1, $word2);

            # Normalize distance to get similarity score
            my $max_length = length($word1) > length($word2) ? length($word1) : length($word2);
            my $similarity = 1 - ($distance / $max_length);

            # Update max_similarity if the current similarity is greater
            $max_similarity = $similarity if $similarity > $max_similarity;
        }
    }

    if($max_similarity > 0.75){
        $api_data->{authenticated} = '1';
        $api_data->{stream}->{current} = "rfli_dc_menu";
        return { valid => 1 };
    }else{
        return { valid => 0 };
    }
}

sub validate_rfli_company 
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;
    
    my $str1 = lc($received_answer);
    my $str2 = lc($api_data->{info}->{policy}->{company});

    print "$str1 and $str2\n";

   # Split both strings into individual words
    my @words1 = split(/\s+/, $str1);
    my @words2 = split(/\s+/, $str2);

    my $max_similarity = 0;

    # Compare each word in the first string with each word in the second string
    for my $word1 (@words1) {
        for my $word2 (@words2) {
            # Calculate Levenshtein distance between the two words
            my $distance = distance($word1, $word2);

            # Normalize distance to get similarity score
            my $max_length = length($word1) > length($word2) ? length($word1) : length($word2);
            my $similarity = 1 - ($distance / $max_length);

            # Update max_similarity if the current similarity is greater
            $max_similarity = $similarity if $similarity > $max_similarity;
        }
    }

    if($max_similarity > 0.75){
        $api_data->{authenticated} = '1';
        $api_data->{stream}->{current} = "dc_menu";
        return { valid => 1 };
    }else{
        return { valid => 0 };
    }

}

1;
