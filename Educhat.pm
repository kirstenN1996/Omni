package Omni::Educhat;
use strict;
use Data::Dumper;
use Carp qw(croak);

sub new 
{
    my $class = shift;
    my $self->{script} = shift;
    bless $self, $class;
    return $self;
}

sub insurance_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if(($received_answer eq "yes")){
        $r->{text} = qq{
Awesome! Insurance helps cover costs, like accidents, health emergencies, or funeral expenses. You pay a monthly fee, and we've got you covered.
        };
    }elsif(($received_answer eq "no")){
         $r->{text} = qq{
        Knowledge is power, right?  Insurance helps cover costs, like accidents, health emergencies, or funeral expenses. You pay a monthly fee, and we've got you covered.
        };
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r;
}

sub policy_check
{
    my $self            = shift;
    my $api_data        = shift;
    print STDERR "here\n";
    my $received_answer = shift;

    my $r;

    if($received_answer eq "Get PDF"){
        $r->{file} = "https://omni.affinityhealth.co.za/educhat/Affinity-Funeral-UW-Brochure-A4-2024-LION09.05.2024-11h39.pdf";
    }elsif($received_answer eq "Maybe next time"){
        $r->{text} = "Not a problem, you can get it next time.";
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r;
}

sub pdf_continue
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "yes"){
        $r->{text} = qq{Next up is our product training session.};
    }elsif($received_answer eq "no"){
        $r->{text} = qq{Maybe next time then? We always have more opportunities for you to join our team.};
        $r->{end} = 1;
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r;
}

sub attending_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "yes"){
        $r->{text} = qq{Fantastic! Can't wait to see you there! 
        
Training Week's agenda? 
Day 1 - Kick-off training. 
Day 2 - Product exploration. 
Day 3 - Assessments and contracts.
Day 4 - Sales training. 
Day 5 - Field sales with pros.};
    }elsif($received_answer eq "no"){
        $r->{text} = qq{Maybe next time then? We always have more opportunities for you to join our team.};
        $r->{end} = 1;
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r;
}

sub week_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "yes"){
        $r->{text}  = qq{Day 1 - We kick off our training!
Day 2 - Dive into our products and learn how they drive our business
Day 3 -  Time for some knowledge checks and contract signing. You're almost part of the team!
Day 4 - Sales training day! We're set to unlock your potential.
Day 5 - Field sales training with the pros to get you into the action.};
    }elsif($received_answer eq "no"){
        $r->{text} = qq{Maybe next time... we have many more opportunities for you to join our team later.};
        $r->{end} = 1;
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r;
}

sub continue_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "yes"){
        $r->{text} = qq{We're super excited to have you join us! Let's keep going!

Let's start with a quick intro to our Funeral Product, the Affinity Funeral product, also known as Umsizi Wemizi. This policy helps our clients cover funeral costs without breaking the bank.

Check out these cool benefits: 
- Low premiums 
- Simple rules 
- Quick and easy claims process 
- Peace of mind knowing your family is well-covered

Here's how the Umsizi Wemizi Funeral Insurance Policy works: 
Funerals can be pricey (airtime, food, transport, tombstones). 
We save our clients from the financial stress of paying for a funeral. Clients pay monthly premiums to us. If a covered member passes away, we cover their funeral costs.
};
    }elsif($received_answer eq "no"){
        $r->{text} = qq{We're sorry to see you go, maybe next time - you're always welcome to join us when you're ready!};
        $r->{end} = 1;
        ####end
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r;
}

sub fun_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    # if($received_answer eq "yes"){
    # }else{
    # }

    $r->{text} = qq{
Here's how the Umsizi Wemizi Funeral Insurance Policy works: 
Funerals can be pricey (airtime, food, transport, tombstones). 
We save our clients from the financial stress of paying for a funeral. Clients pay monthly premiums to us. If a covered member passes away, we cover their funeral costs.
    };

    return $r;
}

sub stands_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "Not different at all"){
        $r->{text} = qq{Hmm, that's not quite right. Here's how it's different...};
    }elsif($received_answer eq "Simpler to explain & use"){
        $r->{text} = qq{You're spot on. Let's dig into that a bit more...};
    }elsif($received_answer eq "Easier to make a claim"){
        $r->{text} = qq{Correct! Here's more on that...;};
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    $r->{text} .= qq{
Umsizi Wemizi stands out for two reasons: 
(i) Simplicity: Easy to explain with fewer terms and conditions. 
(ii) Easy Claiming: Simple process with clearly outlined steps. 
These differences help us shine, especially when you need things smooth and simple.
    };

    if(defined($r->{error})){
        $r->{text} = "";
    }

    return $r;
}

sub last_continue
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "yes"){
        $r->{text} = qq{Great, let's move on! 

Product Training Assessment; 
Here's what to expect after your Funeral Product Training: 
Once you've completed this section, you'll take an assessment to measure what you've learned. The assessment lasts 35 minutes, and you need to score at least 80% to pass.

Assessment Structure after Funeral Product Training: 
Scenario Questions: 
Use what you've learned in real-life situations. True or False: 10 statements about the Funeral Product, each with 3 possible answers. Choose the correct one and make sure you're ready!
};
    }elsif($received_answer eq "no"){
        $r->{text} = qq{No worries! Maybe next time. We always have more opportunities for you to join our team.};
        $r->{end} = 1;
        ####end
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }
    print STDERR $r;

    return $r;
}

sub continue_selling
{
        print STDERR "here\n\n";
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer =~ /Awesome/){
        $r->{text} = qq{
Explore the keys to successful selling: 
Build relationships, understand customer needs, and offer solutions. 
Learn about your product and tailor your pitch to fit customer goals.

Build trust with honesty and transparency. Master handling objections and confidently guide customers through closing deals for a smooth sales process

Happy Selling!
        
};
    }elsif($received_answer =~ /Maybe/){
        $r->{text} = qq{We always have more opportunities for you to join our team.};
        $r->{end} = 1;
        ####end
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }
    print STDERR Dumper($r);

    return $r; 
}

sub none{
        print STDERR "here\n\n";
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    $r->{text} = "ok";
    print STDERR Dumper($r);

    return $r; 
}

sub first_check
{
    my $self            = shift;
    my $api_data        = shift;
    my $received_answer = shift;

    my $r;

    if($received_answer eq "yes"){
        $r->{text} = qq{Yes sure, let's chat some more!
        
We're glad you're interested! Let's start with some of the basics of what we do.};
    }elsif($received_answer eq "no"){
        $r->{text} = qq{Maybe next time then? We always have more opportunities for you to join our team.};
        $r->{end} = 1;
        ####end
    }else{
        $r->{error} = 1;
        $r->{text} = qq{
Please select from drop down.        };
    }

    return $r; 
}



1;
