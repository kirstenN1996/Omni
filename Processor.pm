package Omni::Processor;
use strict;
use Data::Dumper;
use Omni::Stream;
use Omni::Pss;
use Omni::Rfli;
use Omni::Irdsa;
use Omni::Ticket;
use Omni::Leads;
use Omni::Educhat;
use Affinity::Validate;
use LWP::UserAgent;
use HTTP::Cookies;
use HTTP::Request::Common;
use Carp qw(croak);
use Encode qw(encode_utf8);
use Scalar::Util 'looks_like_number';
use Scalar::Util::Numeric qw(isint);
use URI::Escape::XS;


sub new 
{
    my $class  = shift;
    my $script = shift;


    my $self = {
        script => $script,
        ua     => LWP::UserAgent->new,
        stream => Omni::Stream->new($script->variable("stream_server"),$script->variable("stream_port"),$script->variable("stream_password")),
    };

    bless $self, $class;
    return $self;

}

########################## Basic Functions ############################
sub log_message
{
    my $self = shift;
	print STDERR Dumper($self);
    my $from = shift;
    my $from_src = shift;
    my $from_sid = shift;
    my $medium = shift;
    my $channel = shift;
    my $remote_session = shift;
    my $api_session = shift;
	my $content_type = shift;
    my $content = shift;
    my $content_caption = shift;
    my $content_remote_url = shift;
    my $content_local_url = shift;
    my $content_local_file = shift;
    my $stream_name = shift;
    my $stream_id = shift;

    my $dbh = $self->{script}->getdb("omni");

    my $sql = qq{
        INSERT INTO chat_messages(
            `from`, `from_src`, `from_sid`, `medium`, `channel`, `remote_session`, `api_session`,
            `content_type`, `content_text`, `content_caption`, `content_remote_url`, `content_local_url`, `content_local_file`,
            `date_arrived`, `stream_name`, `stream_id`
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), ?, ?)
    };

	print STDERR $sql."\n";

    my $rep = $dbh->prepare($sql);
    $rep->execute($from, $from_src, $from_sid, $medium, $channel, $remote_session, $api_session, 
                  $content_type, $content, $content_caption, $content_remote_url, $content_local_url, 
                  $content_local_file, $stream_name, $stream_id) 
        or croak("Could not Add Bot Response to Chats Table");
    $rep->finish;
}

sub get_last_chatid
{
    my $api_data = shift;

    my $latest_chat_id;
    my $latest_timestamp = 0;
    foreach my $key ( keys %{ $api_data->{chats} } ) {
        next if($api_data->{chats}->{$key}->{from_src} eq "bot" || $api_data->{chats}->{$key}->{from_src} eq "agent");
        my $timestamp = $api_data->{chats}->{$key}->{date_arrived};
        if ( $timestamp && $timestamp > $latest_timestamp ) {
            $latest_chat_id   = $key;
            $latest_timestamp = $timestamp;
        }
    }

    return $latest_chat_id;
}

sub add_chat_to_session
{
    my $api_data = shift;
	my $from = shift;
	my $from_src = shift;
	my $from_sid = shift;
	my $medium = shift;
	my $channel = shift;
	my $remote_session = shift;
	my $api_session = shift;
	my $content_type = shift;
	my $content = shift;
	my $content_remote_url = shift;
	my $content_caption = shift;
	my $content_local_url = shift;
	my $content_local_file = shift;
	my $date_seen = shift;
	my $seen_by = shift;
	my $replied = shift;
    my $ts = time();

    $api_data->{chats}->{$ts} = {
	    from => $from,
	    from_src => $from_src,
	    from_sid => $from_sid,
	    medium => $medium,
	    channel => $channel,
	    remote_session => $remote_session,
	    api_session => $api_session,
	    content_type => $content_type,
	    content_text => $content,
	    content_remote_url => $content_remote_url,
	    content_caption => $content_caption,
	    content_local_url => $content_local_url,
	    content_local_file => $content_local_file,
	    date_arrived => $ts,
	    date_seen => $date_seen,
	    seen_by => $seen_by,
	    replied => $replied
	};

}

########################## Bot Functions ############################
##############PSS###################################################
sub bot_pss 
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $pss     = Omni::Pss->new( $self->{script} );

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;

    ###0 no auth
    ###1 auth
    ###2 max attempts
    if ( $api_data->{authenticated} eq '0' ) {
        ##get questions
        my $sql = qq{select * from bot_items where bot in (SELECT id FROM bots where queue="$api_data->{stream}->{current}" and active="1") and `check`=1 order by item_id asc};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak "could not get bot items\n";
        my ($Items) = $rep->fetchall_hashref("item_id");
        $rep->finish;

        my $i         = $api_data->{current_item} || 1;
        my $max_items = scalar keys %$Items;             # Total number of items

        if ( $i <= $max_items ) {
            my $field    = $Items->{$i}->{field};
            $question = $Items->{$i}->{text};
            print "$i is for $question and ans $api_data->{chats}->{$latest_chat_id}->{content_text}\n";

            my $vsub              = $Items->{$i}->{validation};
            my $validation_result = $pss->$vsub( $api_data, $api_data->{chats}->{$latest_chat_id}->{content_text} );

            if ( $api_data->{init} ) {
      			# If it's the first message, set init to false and proceed with validation
                $api_data->{init} = 0;
                if ( $validation_result->{valid} == 1 ) {
                    $api_data->{current_item} = $i + 1;
                    $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                    $api_data->{attempts} = "";
                    if ( $i < $max_items ) {
                        $question = $Items->{ $i + 1 }->{text};
                    }
                }
            } else {
                # If it's not the first message, proceed as usual
                if ( $validation_result->{valid} == 1 ) {
                    $api_data->{attempts} = "";

                    # Check if we have reached the maximum items
                    if ( $i <= $max_items ) {
                        $i++;
                        $api_data->{current_item} = $i;
                        $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                        $question = $Items->{$i}->{text};
                        if ( $i > $max_items ) {
                            print "passed auth\n";
                            $api_data->{authenticated} = "1";
                            $api_data->{stream}->{current} = "dc_menu";
                            if(defined($api_data->{info}->{policy}->{deps})){
                                $api_data->{stream}->{current} = "dc_menu";
                            }else{
                                $api_data->{stream_data}->{dc_menu}->{dc} = $api_data->{info}->{policy}->{firstname}." ".$api_data->{info}->{policy}->{surname}."-00";;
                                $api_data->{stream}->{current} = "pss_menu";
                            }
                            ###check if there are deps, go to dcmenu else select 00 and go to menu
                            $self->{stream}->add($api_data->{stream}->{current},$api_data);
                        }
                    }

                }
                else {
                    if($i != 1){
                        $api_data->{attempts}++;
                    }
                        $question = $Items->{$i}->{error_message};
                }
            }
        }
    }

    if($api_data->{attempts} > 3){
        $api_data->{authenticated} = '2';
        my $next_stream = "nbc_pss";
        #$question = "Please wait for the next available Agent.";
        $api_data->{stream}->{current} = $next_stream;
        $self->{stream}->add($api_data->{stream}->{current},$api_data);
    }

    if(defined($question)){

        # Send the question
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question        
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        #my $ts = time();
        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub dc_menu
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();


    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $Dmenu;
    my $dc_count = 1;
    $Dmenu->{$dc_count} = $api_data->{info}->{policy}->{firstname}."-00";

    my $latest_chat_id = &get_last_chatid($api_data);

    foreach my $dep (@{$api_data->{info}->{policy}->{deps}}) {
        $dc_count++;
        $Dmenu->{$dc_count} = $dep->{firstnames}."-".$dep->{dc};
    }

    if ( $api_data->{dc_init} ) {
        # If it's the first message, set init to false and proceed with validation
        $api_data->{dc_init} = 0;

        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Dmenu,
            'Who would like assistance?'
        );

        my $jsonMenu = $self->{script}->encode($Dmenu);

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");
    }else{
        if(!defined($api_data->{stream_data}->{$stream_name}->{dc})){
            if (grep { lc($_) eq lc($api_data->{chats}->{$latest_chat_id}->{content_text}) } values %{$Dmenu}) {
                ###check if $api_data->{chats}->{$latest_chat_id}->{content_text} is found in $Dmenu
                ###need error handling here
                $api_data->{stream_data}->{$stream_name}->{dc} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                $api_data->{stream}->{current} = "pss_menu";
                $self->{stream}->add($api_data->{stream}->{current},$api_data);
            }else{
                print "wrong answer\n";
                $api_data->{dc_init} = "1";
                #$api_data->{stream}->{current} = "dc_menu";
            }
        }
    }
    
    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub pss_menu 
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $heading = "What would you like assistance with?";
    my $Menu    = {
        1 => "Speak to a Nurse",
        2 => "Policy queries"
    };

    my $latest_chat_id = &get_last_chatid($api_data);

    my $jsonMenu = $self->{script}->encode($Menu);

    if ( $api_data->{menu_init} ) {
        # If it's the first message, set init to false and proceed with validation
        $api_data->{menu_init} = 0;
        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Menu,
            $heading
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");

    }else{
        my $next_stream;
        my $msg;
        if($api_data->{chats}->{$latest_chat_id}->{content_text} eq "Speak to a Nurse"){
            $next_stream = "pss_medical_questions";
            $api_data->{current_item} = "";
            #$msg = "A Nurse will be in contact with you shortly, allow up to 1 hour for assistance.";
        }elsif($api_data->{chats}->{$latest_chat_id}->{content_text} eq "Policy queries"){
            $next_stream = "nbc_pss";
            $msg = "Your query has been received, allow up to 30 minutes for assistance.";
        }else{
            $api_data->{menu_init} = "1";
        }
        if(defined($next_stream)){
            $api_data->{stream_data}->{$stream_name}->{reply} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            $api_data->{stream}->{current} = $next_stream;
            $self->{stream}->add($api_data->{stream}->{current},$api_data);

            # Send the question
            &send_apex(
                $self,
                $api_data->{chats}->{$latest_chat_id}->{remote_session},
                $api_data->{chats}->{$latest_chat_id}->{channel},
                $api_data->{chats}->{$latest_chat_id}->{from},
                $msg
            );

            &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
            $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

            &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
            "", "", "","", "", "", "");
        }
    }   
    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub pss_medical_questions
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT * FROM `bot_items` WHERE `bot` IN (SELECT `id` FROM `bots` WHERE `queue`="bot_pss" AND `active`="1") AND `check`=0 AND `enabled`="1" ORDER BY `item_id` ASC};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get bot items\n";
    my ($Items) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;

    print "first msg c item is $api_data->{current_item}\n";

    #my $i = $api_data->{current_item} // (sort keys %$Items)[0];
    my $i = $api_data->{current_item} || 1;

    my  $max_items = scalar keys %$Items;

    print "max items is $max_items and i is $i\n";

    if($api_data->{medical_questions_init}){
        $api_data->{medical_questions_init} = 0;
        $question = $Items->{$i}->{text};
        $api_data->{current_item} = $i + 1;
    }else{
        $i = ($i-1);
        if ( $i <= $max_items ) {
            my $field   = $Items->{$i}->{field};
            $i = ($i +1);
            my $type    = $Items->{$i}->{type};
            my $id       = $Items->{$i}->{id};
            $question = $Items->{$i}->{text};
            $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            print STDERR "field is $field and ans is $api_data->{chats}->{$latest_chat_id}->{content_text}";
            $api_data->{current_item} = $i + 1;
            if ( $i > $max_items ) {
                $question = "A Nurse will be in contact with you shortly, allow up to 1 hour for assistance.";
                $api_data->{stream}->{current} = "telehealth_gp";
                $self->{stream}->add($api_data->{stream}->{current},$api_data);
            }
        }else{
            $question = "A Nurse will be in contact with you shortly, allow up to 1 hour for assistance.";
            $api_data->{stream}->{current} = "telehealth_gp";
            $self->{stream}->add($api_data->{stream}->{current},$api_data);
        }
    }

    if(defined($question)){
        # Send the question
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question,
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    $redis->expire($api_key,"86400");
}

sub irdsa_tmc
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `queue`="$stream_name"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    $api_data->{token} = $token;

    my $latest_chat_id = &get_last_chatid($api_data);

    ####get last sid here if lead exists 
    ##check for existing lead
    my $sql = qq{SELECT  chat_messages.api_session, tickets.id, tickets.lead_id,tickets.agent_sid FROM chat_messages  
    left join tickets on chat_messages.api_session = tickets.api_session
    where (`from` = "$api_data->{chats}->{$latest_chat_id}->{from}" or channel = "$api_data->{chats}->{$latest_chat_id}->{from}")
    and tickets.status in(1,3)
    and tickets.date_created > date_sub(now(), interval 30 day)
    order by tickets.id desc limit 1
    };

    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not check for duplicates\n";
    my($check,$ticket, $lead, $agent) = $rep->fetchrow_array();
    $rep->finish;

    if(!defined($check)){

        my $sql = qq{select * from bot_items where bot in (SELECT id FROM bots where queue="$stream_name" and active="1") order by item_id asc};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak "could not get bot items\n";
        my ($Items) = $rep->fetchall_hashref("item_id");
        $rep->finish;

        my $sql = qq{select * from list_items where active="1"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak "could not get bot items\n";
        my ($List) = $rep->fetchall_hashref("item_id");
        $rep->finish;

        my $question;
        my $Menu;

        my $i         = $api_data->{current_item} || 1;
        my $max_items = scalar keys %$Items;  

        if($api_data->{init}){
            $api_data->{init} = 0;
            $question = $Items->{$i}->{text};
            $api_data->{current_item} = $i + 1;
        }else{
            my $g;
            if($Items->{$i - 1}->{field} eq "agent_bot"){
                if($api_data->{chats}->{$latest_chat_id}->{content_text} == 1){
                    print "create lead\n\n";
                    #$question = "An Agent will be in contact with you shortly.";
                    #&send_apex(
                    #    $self,
                    #    $api_data->{chats}->{$latest_chat_id}->{remote_session},
                    #    $api_data->{chats}->{$latest_chat_id}->{channel},
                    #    $api_data->{chats}->{$latest_chat_id}->{from},
                    #    $question,
                    #    $token
                    #);
                    $api_data->{stream}->{current} = "prosales_queue";
                    $self->{stream}->add($api_data->{stream}->{current},$api_data);
                    return;
                    #$i = $max_items +2;
                }elsif($api_data->{chats}->{$latest_chat_id}->{content_text} == 2){
                    print "continue with items\n";
                    #$i = ($i - 1);
                }else{
                    print "restart \n";
                    $i = 1;
                    $api_data->{init} = "";
                }
            }

            $i = ($i-1);
            print STDERR "i is $i and max is $max_items\n";
            if ( $i <= $max_items ) {
                my $field   = $Items->{$i}->{field};
                $i = ($i +1);
                my $type    = $Items->{$i}->{type};
                my $id       = $Items->{$i}->{id};
                if($type eq "TEXT"){
                    $question = $Items->{$i}->{text};
                }elsif($type eq "LIST"){
                    my @l = split(',', $List->{$id}->{items});

                    my $c=0;
                    foreach(@l){
                        $Menu->{$c} = $_;
                        $c++;
                    }
                }
                $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                print STDERR "field is $field and ans is $api_data->{chats}->{$latest_chat_id}->{content_text}";
                $api_data->{current_item} = $i + 1;
                if ( $i > $max_items ) {
                    #$question = "Thank you. Please expect a call from our brokerage partner, Independent Risk Distribution South Africa (IRDSA). One of their representatives will contact you shortly. Please note our working hours are from 08:00 to 17:00, Monday to Friday.";
                    $api_data->{stream}->{current} = "prosales_queue";
                    $self->{stream}->add($api_data->{stream}->{current},$api_data);
                }
            }else{
                $question = "Thank you. Please expect a call from our brokerage partner, Independent Risk Distribution South Africa (IRDSA). One of their representatives will contact you shortly. Please note our working hours are from 08:00 to 17:00, Monday to Friday.";
                $api_data->{stream}->{current} = "prosales_queue";
                $self->{stream}->add($api_data->{stream}->{current},$api_data);
            }
        }

        if(defined($question)){
                # Send the question
            &send_apex(
                $self,
                $api_data->{chats}->{$latest_chat_id}->{remote_session},
                $api_data->{chats}->{$latest_chat_id}->{channel},
                $api_data->{chats}->{$latest_chat_id}->{from},
                $question,
                $token
            );

            &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
            $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

            my $ts = time();
            &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
            "", "", "","", "", "", "");

        }

        if(defined($Menu)){
            my $jsonMenu = $self->{script}->encode($Menu);

            &apex_list(
                $self,
                $api_data->{chats}->{$latest_chat_id}->{remote_session},
                $api_data->{chats}->{$latest_chat_id}->{channel},
                $api_data->{chats}->{$latest_chat_id}->{from},
                $Menu,
                $Items->{$i}->{text},
                $token
            );

            &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
            $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $Items->{$i}->{text}." ".$jsonMenu, "", "", "", "" ,$stream_name, "");

            my $ts = time();
            &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $Items->{$i}->{text}." ".$jsonMenu,
            "", "", "","", "", "", "");
        }
    } else {
        print STDERR "we have a ticket so we should have lead_id as well";
        my $sql = qq{UPDATE `tickets` SET `status` = "2",`date_closed` = NOW() WHERE `id` = "$ticket"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not update ticket status");
        $rep->finish;

        $api_data->{info}->{lead} = $lead;
        $api_data->{stream}->{current} = "ps_assign";
        $self->{stream}->add($api_data->{stream}->{current},$api_data);
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    $redis->expire($api_key,"86400");
}

sub irdsa_ps
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    #my $ben     = $self->{script}->getdb("benoni");
    #my $flor    = $self->{script}->getdb("flora");
    #my $ps	= $self->{script}->redis("prosales"); 	
    my $ps = Redis->new(server => '10.0.101.61:6379');

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `queue`="$stream_name"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    $api_data->{token} = $token;


    my $question;

    my $latest_chat_id = &get_last_chatid($api_data);

    ##check for existing lead
    my $sql = qq{SELECT  chat_messages.api_session, tickets.id, tickets.lead_id,tickets.agent_sid FROM chat_messages  
    left join tickets on chat_messages.api_session = tickets.api_session
    where (`from` = "$api_data->{chats}->{$latest_chat_id}->{from}" or channel = "$api_data->{chats}->{$latest_chat_id}->{from}")
    and tickets.status in(1,3)
    and tickets.date_created > date_sub(now(), interval 30 day)
    order by tickets.id desc limit 1
    };

    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not check for duplicates\n";
    my($check,$ticket, $lead, $agent) = $rep->fetchrow_array();
    $rep->finish;

    my $bucket = "2";
    my $queue = "1";
    my $status = "1";

    if(!$check){

	# get the last known vendor_lead_code
	my $vendor_lead_code;
	$ps->select(2);
	my $profile = $ps->get($api_data->{chats}->{$latest_chat_id}->{from});
	print STDERR Dumper($profile);
	if($profile){
		$profile = $self->{script}->decode($profile);
		$vendor_lead_code = $profile->{vendor_lead_code};
	}


        ##no ticket create new one
        print STDERR "create new ticket ";

        $api_data->{info}->{lead} = $vendor_lead_code;
       	#$api_data->{info}->{lead} = "0";
	    $api_data->{stream}->{current} = "ps_assign";
        $self->{stream}->add($api_data->{stream}->{current},$api_data);

    }else{
        ###close old tickt. 
        ##create new ticket
        ###set sid
        ##send to agent_direct
        print STDERR "we have a ticket so we should have lead_id as well";
        my $sql = qq{UPDATE `tickets` SET `status` = "2",`date_closed` = NOW() WHERE `id` = "$ticket"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not update ticket status");
        $rep->finish;

        $api_data->{info}->{lead} = $lead;
        $api_data->{stream}->{current} = "ps_assign";
        $self->{stream}->add($api_data->{stream}->{current},$api_data);
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    $redis->expire($api_key,"86400");

}

sub ps_assign
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ps      = $self->{script}->getdb("prosales");
    my $ts      = time();
    #my $token   = "2eiqt2sq5ddvm9gudvpif3xwmuyqshtfw1yz";
    my $sid;

    print STDERR"create ticket for sess $api_key\n";

    $redis->select(2);
	my $api_data = $redis->get($api_key);
	if($api_data){
    	$api_data    = $self->{script}->decode( $api_data );
        print STDERR Dumper($api_data);
	    my $stream_name = $api_data->{stream}->{current};
        #my $lead = $api_data->{info}->{lead} eq '' ? undef : $api_data->{info}->{lead};
	    my $lead = (!defined($api_data->{info}->{lead}) || $api_data->{info}->{lead} eq '') ? 0 : $api_data->{info}->{lead};
	    if(!isint($lead)){
	    	$lead = 0;
	    }
	    my $token = $api_data->{token};

        my $bucket = "7"; #change to 7
        my $queue = "1";

        my $latest_chat_id = &get_last_chatid($api_data);

        my $sql = qq{SELECT `last_sid` FROM opt_in where number="$api_data->{chats}->{$latest_chat_id}->{from}" and sms=1};
        my $rep = $dbh->prepare($sql);
        $rep->execute || die "could not check for last_sid";
        $sid = $rep->fetchrow_array();
        $rep->finish;

        if(!defined($sid)){
            $sid = &get_last_assigned($ps, $dbh);
        }

        #my $sid = "S-1-5-21-1473177135-318938408-1854198611-4691";

        my $sql = qq{INSERT INTO `tickets` (`api_session`, `queue_id`, `bucket_id`, `status`, `date_created`, agent_sid, `date_assigned`, `date_modified`, `lead_id`) 
            VALUES ("$api_key", "$queue", "$bucket", "3", NOW(), "$sid", NOW(), NOW(), "$lead" ) };
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not create ticket");
        my $t_id = $rep->{mysql_insertid};
        $rep->finish;

        $api_data->{ticket}->{bucket} = $bucket;
        $api_data->{ticket}->{id} = $t_id;
        $api_data->{ticket}->{status} = "3";
        $api_data->{ticket}->{agent} = $sid;
        $api_data->{ticket}->{queue} = $queue;

        $api_data->{stream}->{current} = "agent_direct";
        $self->{stream}->add($api_data->{stream}->{current},$api_data);

        my ($sec, $min, $hour, $day, $month, $year, $wday) = localtime();

        my $run = 0;  # 
        my $msg;

        if ($wday == 6) {  # 6 represents Saturday
            if ($hour >= 8 && $hour < 13) {
                $run = 1;
            }
        } elsif ($wday >= 1 && $wday <= 5) {  # Monday to Friday
            # Send SMS only between 08:00 and 17:00 on weekdays
            if ($hour >= 8 && $hour <= 17) {
                print STDERR "should send";
                $run = 1;
            }
        }

        if ($run) {
            $msg = "Your query has been received, an agent will be with you shortly.";
        } else {
            $msg = "Hello from IRDSA, We received your message whilst out of office. Our operating hours are from 8:00 to 17:00, Monday to Friday (Excluding Public Holidays). One of our representatives will be in contact with you during office hours.";
        }
        
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $msg,
            $token
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
        "", "", "","", "", "", "");

        $redis->set( $api_key, $self->{script}->encode($api_data) );
        #$redis->persist($api_key);
        $redis->expire($api_key,"86400");
	}
}

sub get_last_assigned
{
    my $ps  = shift;
    my $dbh = shift;

    my $sql = qq {select sid from user_accounts where whatsapp_device = "1"};
    my $rep = $ps->prepare($sql);
    $rep->execute || die;
    my($SID) = $rep->fetchall_hashref("sid");
    $rep->finish;

    foreach my $sid(keys %{$SID}){
        my $sql = qq {Select id from chat_assigned where `group` = "prosales_agents" and `date` = DATE(NOW()) and sid = "$sid"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || die;
        my($check) = $rep->fetchrow_array();
        $rep->finish;

        if(!$check){
            my $sql = qq {insert into chat_assigned(`group`,`date`, `sid`,`count`) values("prosales_agents", DATE(NOW()), "$sid",0)};
            my $rep = $dbh->prepare($sql);
            $rep->execute || die;
            $rep->finish;
        }
    }

    my $users = '"'.join('","', keys %{$SID}).'"';

    my $sql = qq {select sid,count from chat_assigned where sid in($users) and `date` = DATE(NOW()) ORDER by count ASC limit 1};
    my $rep = $dbh->prepare($sql);
    $rep->execute || die;
    my($sid,$count) = $rep->fetchrow_array();
    $rep->finish;

    $count++;
    my $sql = qq {update chat_assigned set `count` = $count where `group` = "prosales_agents" and sid = "$sid" and `date` = DATE(NOW())};
    my $rep = $dbh->prepare($sql);
    $rep->execute || die;
    $rep->finish;

    return $sid;
}

sub prosales_queue
{
    ##what if lead exists?
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $vsd     = $self->{script}->getdb("prosales");
    my $ts      = time();
    my $leads   = Omni::Leads->new( $self->{script} );


	print STDERR "key is $api_key\n";
    $redis->select(2);
	my $api_data = $redis->get($api_key);
	if($api_data){
		$api_data    = $self->{script}->decode( $api_data );
	
    	#my $api_data    = $self->{script}->decode( $redis->get($api_key) );
   		 my $stream_name = $api_data->{stream}->{current};

    	my $latest_chat_id = &get_last_chatid($api_data);

		# Ensure $income and $budget are integers, defaulting to 2000 if not set
		my $income  = int($api_data->{stream_data}->{irdsa_tmc}->{income}) || 25000;
		my $budget  = int($api_data->{stream_data}->{irdsa_tmc}->{budget}) || 3000;

		# Ensure $child and $adult are between 0 and 6, defaulting to 0 if not within range
		my $child = $api_data->{stream_data}->{irdsa_tmc}->{children} // 0;
		$child = ($child > 0 && $child <= 6) ? $child : 0;
	
		my $adult = $api_data->{stream_data}->{irdsa_tmc}->{adults} // 0;
		$adult = ($adult > 0 && $adult <= 6) ? $adult : 0;

		my $spouse     = $api_data->{stream_data}->{irdsa_tmc}->{spouse};

    	my $marital;

    	if($spouse eq "yes"){
        	$marital = "married";
    	}else{
        	$marital = "single";
    	}

        my @family = ("premium_principal");
	    if($marital =~ /married/){
	    	push(@family, "premium_spouse");
	    }

        if($child){
	        for(1..6){
	        	if($_ <= $child){
	        		push(@family,"premium_child_".$_);
	        	}
	        }
	    }

        my $family = join(" + ",@family);
	    if($adult > 0){
	    	$family = $family." + (premium_adult * $adult) ";
	    }

        my $sql = qq{
            SELECT *, ($family) AS total_premium
            FROM scheme_plan
            WHERE  ($family) <= (
            	SELECT 0.25 * (SELECT end FROM scheme_income_bands WHERE "$income" BETWEEN start AND end limit 1)
            )
             AND id IN(
              SELECT plan FROM scheme_package WHERE  plan IN(SELECT plan FROM sales_team_plans WHERE enabled = "1") AND scheme = 2
            )
            ORDER BY ABS(total_premium - '$budget')
            LIMIT 1
        };
        print STDERR $sql."\n";
        my $rep = $vsd->prepare($sql);
	    $rep->execute || croak("Query Failed to Calculate main plan");
	    my ($P) = $rep->fetchrow_hashref();
	    $rep->finish;

        my $sql = qq{SELECT * FROM plan_campaign};
        my $rep = $dbh->prepare($sql);
	    $rep->execute || croak("Could not get plan campaign");
	    my ($PC) = $rep->fetchall_hashref("plan");
	    $rep->finish;

        #my $plan = $P->{id};
	    my $plan = defined $P->{id} ? $P->{id} : '2';

        my $campaign = $PC->{$plan}->{campaign};

        my $login = $leads->login();

        my $Profile = $leads->get_profile($api_data->{chats}->{$latest_chat_id}->{from});
        my $Update = $leads->update_prosales($Profile, $api_data->{stream_data}->{irdsa_tmc});

        #print STDERR Dumper($Update);

        $leads->save_profile($api_data->{chats}->{$latest_chat_id}->{from},$Update);

        # if($api_data->{info}->{lead} > 0){
        #     print "we have a lead\n";
        # }else{
        my $url = "http://api.affinityhealth.co.za/api/leads/add";
        my $comments = "Married: $marital, Children $child, Adults: $adult, Budget $budget, Income: $income";

        my %data = (
            campaign_id => $campaign,
            firstname => $api_data->{stream_data}->{irdsa_tmc}->{firstname},
            surname => $api_data->{stream_data}->{irdsa_tmc}->{surname},
            cell => $api_data->{chats}->{$latest_chat_id}->{from},
            comments => $comments
        );

        my $tmc_url = 'https://leads.themediacrowd.co.za/api/leads/whatsapp-create-lead?';
        foreach my $k(keys %data){
             my $value = encodeURIComponent($data{$k});
             $tmc_url = $tmc_url."\&".$k."=".$value;
        }

        my $tmc_response = $self->{ua}->get($tmc_url);

        my $request = POST $url, \%data;
        my $response = $self->{ua}->request($request);

        if($response->is_success){
            print "Data posted successfully.\n";
            my $content = $response->content;
            my $response_data = $self->{script}->decode($content);
            if($response_data->{status} eq "success"){
                my $lead_id = $response_data->{data}->{lead_id};
                $api_data->{info}->{lead} = $lead_id;
                $api_data->{stream}->{current} = "prosales_direct";
                $self->{stream}->add($api_data->{stream}->{current},$api_data);
            }else{
                print STDERR $response_data->{data}->{error}."\n";
            }
            print Dumper($response_data);
        }else{
            print "Error posting data: ", $response->status_line, "\n";
        }
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    $redis->expire($api_key,"86400");
}

sub prosales_direct
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();
    #my $token   = "e81jiee727moxowyjthjjciuxdwxx5eagkgv";


    print "create ticket for sess $api_key\n";

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $lead = $api_data->{info}->{lead};
    my $token = $api_data->{token};

    my $bucket = "2";
    my $queue = "1";
    my $status = "1";

    my $check;
    my $check2;

    if(defined($lead)){
        my $sql = qq{SELECT lead_id FROM tickets WHERE lead_id="$lead" AND status="1"};
        print $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute() || croak "Could not execute SQL query: $DBI::errstr\n";
        $check = $rep->fetchrow_array();
        $rep->finish;
    }

    my $sql2 = qq{SELECT api_session FROM tickets WHERE api_session="$api_key" AND status="1"};
    print $sql2."\n";
    my $rep2 = $dbh->prepare($sql2);
    $rep2->execute() || croak "Could not execute SQL query: $DBI::errstr\n";
    $check2 = $rep2->fetchrow_array();
    $rep2->finish;

    my $latest_chat_id = &get_last_chatid($api_data);
	my $msg;	

    if ( (defined($check)) || (defined($check2)) ) {

       	$msg = "Please expect a call from our brokerage partner, Independent Risk Distribution South Africa (IRDSA). One of their representatives will contact you shortly. Please note our working hours are from 08:00 to 17:00, Monday to Friday.";
        #&send_apex(
        #    $self,
        #    $api_data->{chats}->{$latest_chat_id}->{remote_session},
        #    $api_data->{chats}->{$latest_chat_id}->{channel},
        #    $api_data->{chats}->{$latest_chat_id}->{from},
        #    $msg,
        #    $token
        #);

        #&log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        #$api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

        #&add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
        #"", "", "","", "", "", "");

    }else{
	$msg = "Thank you. Please expect a call from our brokerage partner, Independent Risk Distribution South Africa (IRDSA). One of their representatives will contact you shortly. Please note our working hours are from 08:00 to 17:00, Monday to Friday.";
        my $sql = qq{INSERT INTO `tickets` (`api_session`, `queue_id`, `bucket_id`, `status`, `date_created`, `lead_id`) 
            VALUES ("$api_key", "$queue", "$bucket", "$status", NOW(), "$lead" ) };
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not create ticket");
        my $t_id = $rep->{mysql_insertid};
        $rep->finish;

        $api_data->{ticket}->{bucket} = $bucket;
        $api_data->{ticket}->{id} = $t_id;
        $api_data->{ticket}->{status} = $status;
        $api_data->{ticket}->{queue} = $queue;
        
    }

	if(defined($msg)){
		&send_apex(
            		$self,
            		$api_data->{chats}->{$latest_chat_id}->{remote_session},
            		$api_data->{chats}->{$latest_chat_id}->{channel},
            		$api_data->{chats}->{$latest_chat_id}->{from},
            		$msg,
            		$token
        	);

        	&log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        	$api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

        	&add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
        	"", "", "","", "", "", "");

	}


    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub agent_direct
{
    print STDERR "in agent direct\n";
}

# sub unseen_chats
# {

# }

##############PSS###################################################

##############RFLI###################################################
sub bot_rfli
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $rfli     = Omni::Rfli->new( $self->{script} );

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `queue`="$stream_name"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    $api_data->{token} = $token;

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;

    ###0 no auth
    ###1 auth
    ###2 max attempts
    if ( $api_data->{authenticated} eq '0' ) {
        ##get questions
        my $sql = qq{select * from bot_items where bot in (SELECT id FROM bots where queue="$api_data->{stream}->{current}" and active="1") and `check`=1 order by item_id asc};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak "could not get bot items\n";
        my ($Items) = $rep->fetchall_hashref("item_id");
        $rep->finish;

        my $i         = $api_data->{current_item} || 1;
        my $max_items = scalar keys %$Items;             # Total number of items

        if ( $i <= $max_items ) {
            my $field    = $Items->{$i}->{field};
            $question = $Items->{$i}->{text};

            my $vsub              = $Items->{$i}->{validation};
            my $validation_result = $rfli->$vsub( $api_data, $api_data->{chats}->{$latest_chat_id}->{content_text} );

            if ( $api_data->{init} ) {
      			# If it's the first message, set init to false and proceed with validation
                $api_data->{init} = 0;
                if ( $validation_result->{valid} == 1 ) {
                    $api_data->{current_item} = $i + 1;
                    $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                    $api_data->{attempts} = "";
                    if ( $i < $max_items ) {
                        $question = $Items->{ $i + 1 }->{text};
                    }
                }
            } else {
                # If it's not the first message, proceed as usual
                if ( $validation_result->{valid} == 1 ) {
                    $api_data->{attempts} = "";

                    # Check if we have reached the maximum items
                    if ( $i <= $max_items ) {
                        $i++;
                        $api_data->{current_item} = $i;
                        $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                        $question = $Items->{$i}->{text};
                        if ( $i > $max_items ) {
                            print "passed auth\n";
                            $api_data->{authenticated} = "1";
                            $api_data->{stream}->{current} = "rfli_dc_menu";
                            if(defined($api_data->{info}->{policy}->{deps})){
                                $api_data->{stream}->{current} = "rfli_dc_menu";
                            }else{
                                $api_data->{stream_data}->{rfli_dc_menu}->{dc} = $api_data->{info}->{policy}->{firstname}." ".$api_data->{info}->{policy}->{surname}."-00";;
                                $api_data->{stream}->{current} = "rfli_menu";
                            }
                            ###check if there are deps, go to dcmenu else select 00 and go to menu
                            $self->{stream}->add($api_data->{stream}->{current},$api_data);
                        }
                    }

                }
                else {
                    if($i != 1){
                        $api_data->{attempts}++;
                    }
                    $question = $Items->{$i}->{error_message};
                }
            }
        }
    }

    if($api_data->{attempts} > 3){
        $api_data->{authenticated} = '2';
        my $next_stream = "nbc_rfli";
        #$question = "Please wait for the next available Agent.";
        $api_data->{stream}->{current} = $next_stream;
        $self->{stream}->add($api_data->{stream}->{current},$api_data);
    }

    if(defined($question)){

        # Send the question
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question,
            $token
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        #my $ts = time();
        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub rfli_dc_menu
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();


    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $token = $api_data->{token};

    my $Dmenu;
    my $dc_count = 1;
    $Dmenu->{$dc_count} = $api_data->{info}->{policy}->{firstname}." ".$api_data->{info}->{policy}->{surname}."-00";

    my $latest_chat_id = &get_last_chatid($api_data);

    foreach my $dep (@{$api_data->{info}->{policy}->{deps}}) {
        $dc_count++;
        $Dmenu->{$dc_count} = $dep->{initials}." ".$dep->{surname}."-".$dep->{dependent_code};
    }

    if ( $api_data->{dc_init} ) {
        # If it's the first message, set init to false and proceed with validation
        $api_data->{dc_init} = 0;

        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Dmenu,
            'Who would like assistance?',
            $token
        );

        my $jsonMenu = $self->{script}->encode($Dmenu);

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");
    }else{
        # if(!defined($api_data->{stream_data}->{$stream_name}->{dc})){
        #     ###check if $api_data->{chats}->{$latest_chat_id}->{content_text} is found in $Dmenu
        #     $api_data->{stream_data}->{$stream_name}->{dc} = $api_data->{chats}->{$latest_chat_id}->{content_text};
        #     $api_data->{stream}->{current} = "rfli_menu";
        #     $self->{stream}->add($api_data->{stream}->{current},$api_data);
        # }
        if (grep { lc($_) eq lc($api_data->{chats}->{$latest_chat_id}->{content_text}) } values %{$Dmenu}) {
            ###check if $api_data->{chats}->{$latest_chat_id}->{content_text} is found in $Dmenu
            ###need error handling here
            $api_data->{stream_data}->{$stream_name}->{dc} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            $api_data->{stream}->{current} = "rfli_menu";
            $self->{stream}->add($api_data->{stream}->{current},$api_data);
        }else{
            print "wrong answer\n";
            $api_data->{dc_init} = "1";
                #$api_data->{stream}->{current} = "dc_menu";
        }
    }
    
    $redis->set( $api_key, $self->{script}->encode($api_data) );
    $redis->expire($api_key,"86400");
}

sub rfli_menu
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $token = $api_data->{token};

    my $heading = "What would you like assistance with?";
    my $Menu    = {
        1 => "Speak to a Nurse",
        2 => "Policy queries"
    };

    my $latest_chat_id = &get_last_chatid($api_data);

    my $jsonMenu = $self->{script}->encode($Menu);

    if ( $api_data->{menu_init} ) {
        # If it's the first message, set init to false and proceed with validation
        $api_data->{menu_init} = 0;
        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Menu,
            $heading,
            $token
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");

    }else{
        my $next_stream;
        my $msg;
        if($api_data->{chats}->{$latest_chat_id}->{content_text} eq "Speak to a Nurse"){
            #$next_stream = "telehealth_gp";
            $next_stream = "rfli_medical_questions";
            $api_data->{current_item} = "";
            #$msg = "Please answer the medical questions.";
        }elsif($api_data->{chats}->{$latest_chat_id}->{content_text} eq "Policy queries"){
            $next_stream = "nbc_rfli";
            $msg = "Your query has been received, allow up to 30 minutes for assistance.";
        }else{
            $api_data->{menu_init} = "1";
        }
        if(defined($next_stream)){
            $api_data->{stream_data}->{$stream_name}->{reply} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            $api_data->{stream}->{current} = $next_stream;
            $self->{stream}->add($api_data->{stream}->{current},$api_data);

            if(defined($msg)){

                # Send the question
                &send_apex(
                    $self,
                    $api_data->{chats}->{$latest_chat_id}->{remote_session},
                    $api_data->{chats}->{$latest_chat_id}->{channel},
                    $api_data->{chats}->{$latest_chat_id}->{from},
                    $msg,
                    $token
                );

                &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
                $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

                &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
                "", "", "","", "", "", "");
            }
        }
    }   
    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

##############RFLI###################################################
#######################EDUCHAT######################################


sub bot_educhat_old
{
	print STDERR "IN EDU\n\n";
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $edu     = Omni::Educhat->new( $self->{script} );

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `queue`="$stream_name"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    $sql = qq{select * from bot_items where bot in (SELECT id FROM bots where queue="$stream_name" and active="1") and `enabled`="1" order by item_id asc};
    print STDERR $sql."\n";
    $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get bot items\n";
    my ($Items) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    $sql = qq{select * from list_items where active="1"};
    $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get list items\n";
    my ($List) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;
    my $Menu;
    my $end;

    my $i = $api_data->{current_item} || 1;
    my $max_items = scalar keys %$Items;

    print STDERR "i is $i";

    if ( $i <= $max_items ) {
        my $field = $Items->{$i}->{field};
        my $type  = $Items->{$i}->{type};
        my $id    = $Items->{$i}->{id};
        my $error = $Items->{$i}->{error_message};

        if ($api_data->{init}) {
            $question = $Items->{$i}->{text};
            $i = $i + 1;
            $api_data->{init} = 0;
            $api_data->{current_item} = $i;
            
            $field = $Items->{$i}->{field};
            $type  = $Items->{$i}->{type};
            $id    = $Items->{$i}->{id};
            $error = $Items->{$i}->{error_message};
            if ($type eq "TEXT") {
                #$question = $Items->{$i}->{text};
            } elsif ($type eq "LIST") {
                my @l = split(',', $List->{$id}->{items});
                my $c=0;
                foreach (@l) {
                    $Menu->{$c} = $_;
                    $c++;
                }
            }
        } else {
            my $vsub = $Items->{$i}->{validation};
            my $vr = $edu->$vsub( $api_data, $api_data->{chats}->{$latest_chat_id}->{content_text} );

            if ($i == 3) {
                print "here i is 3\n";
                &send_apex_file(
                    $self,
                    $api_data->{chats}->{$latest_chat_id}->{remote_session},
                    $api_data->{chats}->{$latest_chat_id}->{channel},
                    $api_data->{chats}->{$latest_chat_id}->{from},
                    $vr->{file},
                    $token
                );
                &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
                $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "file", $question." ".$vr->{file}, "", "", "", "" ,$stream_name, "");

                my $ts = time();
                &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "file", $question." ".$vr->{file},
                "", "", "","", "", "", "");
                sleep(5);
            }
            
            if (!defined($vr->{error})) {
                $question = $vr->{text};
                $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                $i++;
                $id    = $Items->{$i}->{id};
                $api_data->{current_item} = $i;
            } else {
                $question = $error;
            }

            
            if ($i > $max_items) {
                $end = 1;
            }

            if (defined($vr->{end})) {
                $end = $vr->{end};
                $question = $vr->{text};
            } elsif ($type eq "TEXT") {
                $question = $Items->{$i}->{text};
            } elsif ($type eq "LIST") {
                my @l = split(',', $List->{$id}->{items});
                my $c = 0;
                foreach (@l) {
                    $Menu->{$c} = $_;
                    $c++;
                }
            }
        }
    }
    
    if (defined($question)) {
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question,
            $token
        );

        &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        my $ts = time();
        &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

    if (defined($Menu)) {
        print "we have a list\n";

        my $jsonMenu = $self->{script}->encode($Menu);

        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Menu,
            $Items->{$i}->{text},
            $token
        );

        &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $Items->{$i}->{text}." ".$jsonMenu, "", "", "", "" ,$stream_name, "");

        my $ts = time();
        &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");
    }

    if ($end) {
        print "deleting $api_key\n";
        $redis->del($api_key);
        return;
    }

    $redis->set($api_key, $self->{script}->encode($api_data));
    $redis->expire($api_key, "86400");
}


sub bot_educhat 
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $edu     = Omni::Educhat->new( $self->{script} );

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `queue`="$stream_name"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    my $sql = qq{select * from bot_items where bot in (SELECT id FROM bots where queue="$stream_name" and active="1") and `enabled`="1" order by item_id asc};
	print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get bot items\n";
    my ($Items) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $sql = qq{select * from list_items where active="1"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get list items\n";
    my ($List) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;
    my $Menu;
    my $end;

    my $i = $api_data->{current_item} || 1;
    my $max_items = scalar keys %$Items;

    if ( $i <= $max_items ) {
        my $field = $Items->{$i}->{field};
        my $type  = $Items->{$i}->{type};
        print STDERR "type is $type\n";
        my $id    = $Items->{$i}->{id};
        my $error = $Items->{$i}->{error_message};

        if ($api_data->{init}) {
            $question = $Items->{$i}->{text};
            $i = $i + 1;
            $api_data->{init} = 0;
            $api_data->{current_item} = $i;
            
            $field = $Items->{$i}->{field};
            $type  = $Items->{$i}->{type};
            $id    = $Items->{$i}->{id};
            $error = $Items->{$i}->{error_message};
            if ($type eq "TEXT") {
                #$question = $Items->{$i}->{text};
            } elsif ($type eq "LIST") {
                my @l = split(',', $List->{$id}->{items});
                my $c=0;
                foreach (@l) {
                    $Menu->{$c} = $_;
                    $c++;
                }
            }
        } else {
            #$i++;
            $field = $Items->{$i}->{field};
            $type  = $Items->{$i+1}->{type};
            $id    = $Items->{$i}->{id};
            $error = $Items->{$i}->{error_message};
            print STDERR "i is $i and val is $Items->{$i}->{validation}, type is $Items->{$i}->{type}\n";
            print STDERR $Items->{$i}->{text}."\n";
            my $vsub = $Items->{$i}->{validation};
            my $vr = $edu->$vsub( $api_data, $api_data->{chats}->{$latest_chat_id}->{content_text} );
            #$question = $Items->{$i}->{text};


            if ($i == 4) {
                if(defined($vr->{file})){
                    print "here i is 4\n";
                    &send_apex_file(
                        $self,
                        $api_data->{chats}->{$latest_chat_id}->{remote_session},
                        $api_data->{chats}->{$latest_chat_id}->{channel},
                        $api_data->{chats}->{$latest_chat_id}->{from},
                        $vr->{file},
                        $token
                    );
                    &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
                    $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "file", $question." ".$vr->{file}, "", "", "", "" ,$stream_name, "");

                    my $ts = time();
                    &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "file", $question." ".$vr->{file},
                    "", "", "","", "", "", "");
                    sleep(5);
                }
            }

            if (!defined($vr->{error})) {
                $question = $vr->{text};
                print STDERR "res is $question\n";
                $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                $i++;
                $id    = $Items->{$i}->{id};
                $api_data->{current_item} = $i;
            } else {
                $question = $error;
            }

            
            if ($i > $max_items) {
                $end = 1;
            }

            if (defined($vr->{end})) {
                $end = $vr->{end};
                $question = $vr->{text};
            } elsif ($type eq "TEXT") {
                $question = $Items->{$i}->{text};
            } elsif ($type eq "LIST") {
                my @l = split(',', $List->{$id}->{items});
                my $c = 0;
                foreach (@l) {
                    $Menu->{$c} = $_;
                    $c++;
                }
            }
            $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            
            $api_data->{current_item} = $i;
        }
    }

    if (defined($question)) {
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question,
            $token
        );

        &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        my $ts = time();
        &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

     if (defined($Menu)) {
        print "we have a list\n";

        my $jsonMenu = $self->{script}->encode($Menu);

        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Menu,
            $Items->{$i}->{text},
            $token
        );

        &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $Items->{$i}->{text}." ".$jsonMenu, "", "", "", "" ,$stream_name, "");

        my $ts = time();
        &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");
    }

    if ($end) {
        print "deleting $api_key\n";
        $redis->del($api_key);
        return;
    }

    $redis->set($api_key, $self->{script}->encode($api_data));
    $redis->expire($api_key, "86400");
}

sub bot_educhat_old31
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $edu     = Omni::Educhat->new( $self->{script} );

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `queue`="$stream_name"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    my $sql = qq{select * from bot_items where bot in (SELECT id FROM bots where queue="$stream_name" and active="1") and `enabled`="1" order by item_id asc};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get bot items\n";
    my ($Items) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $sql = qq{select * from list_items where active="1"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get list items\n";
    my ($List) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;
    my $Menu;
    my $end;

    my $i = $api_data->{current_item} || 1;
    my $max_items = scalar keys %$Items;

    if ( $i <= $max_items ) {
        my $field = $Items->{$i}->{field};
        my $type  = $Items->{$i}->{type};
        print STDERR "type is $type\n";
        my $id    = $Items->{$i}->{id};
        my $error = $Items->{$i}->{error_message};

        if ($api_data->{init}) {
            $question = $Items->{$i}->{text};
            $i = $i + 1;
            $api_data->{init} = 0;
            $api_data->{current_item} = $i;
            
            $field = $Items->{$i}->{field};
            $type  = $Items->{$i}->{type};
            $id    = $Items->{$i}->{id};
            $error = $Items->{$i}->{error_message};
            if ($type eq "TEXT") {
                #$question = $Items->{$i}->{text};
            } elsif ($type eq "LIST") {
                my @l = split(',', $List->{$id}->{items});
                my $c=0;
                foreach (@l) {
                    $Menu->{$c} = $_;
                    $c++;
                }
            }
        } else {
            #$i++;
            $field = $Items->{$i}->{field};
            $type  = $Items->{$i+1}->{type};
            $id    = $Items->{$i}->{id};
            $error = $Items->{$i}->{error_message};
            print STDERR "i is $i and val is $Items->{$i}->{validation}, type is $Items->{$i}->{type}\n";
            print STDERR $Items->{$i}->{text}."\n";
            my $vsub = $Items->{$i}->{validation};
            my $vr = $edu->$vsub( $api_data, $api_data->{chats}->{$latest_chat_id}->{content_text} );
            #$question = $Items->{$i}->{text};


            if ($i == 4) {
                if(defined($vr->{file})){
                    print "here i is 4\n";
                    &send_apex_file(
                        $self,
                        $api_data->{chats}->{$latest_chat_id}->{remote_session},
                        $api_data->{chats}->{$latest_chat_id}->{channel},
                        $api_data->{chats}->{$latest_chat_id}->{from},
                        $vr->{file},
                        $token
                    );
                    &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
                    $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "file", $question." ".$vr->{file}, "", "", "", "" ,$stream_name, "");

                    my $ts = time();
                    &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "file", $question." ".$vr->{file},
                    "", "", "","", "", "", "");
                    sleep(5);
                }
            }

            if (!defined($vr->{error})) {
                $question = $vr->{text};
                print STDERR "res is $question\n";
                $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
                $i++;
                $id    = $Items->{$i}->{id};
                $api_data->{current_item} = $i;
            } else {
                $question = $error;
            }

            
            if ($i > $max_items) {
                $end = 1;
            }

            if (defined($vr->{end})) {
                $end = $vr->{end};
                $question = $vr->{text};
            } elsif ($type eq "TEXT") {
                $question = $Items->{$i}->{text};
            } elsif ($type eq "LIST") {
                my @l = split(',', $List->{$id}->{items});
                my $c = 0;
                foreach (@l) {
                    $Menu->{$c} = $_;
                    $c++;
                }
            }
            $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            
            $api_data->{current_item} = $i;
        }
    }

    if (defined($question)) {
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question,
            $token
        );

        &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        my $ts = time();
        &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

     if (defined($Menu)) {
        print "we have a list\n";

        my $jsonMenu = $self->{script}->encode($Menu);

        &apex_list(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $Menu,
            $Items->{$i}->{text},
            $token
        );

        &log_message($self, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $Items->{$i}->{text}." ".$jsonMenu, "", "", "", "" ,$stream_name, "");

        my $ts = time();
        &add_chat_to_session($api_data, $api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "list", $jsonMenu,
        "", "", "","", "", "", "");
    }

    if ($end) {
        print "deleting $api_key\n";
        $redis->del($api_key);
        return;
    }

    $redis->set($api_key, $self->{script}->encode($api_data));
    $redis->expire($api_key, "86400");
}
#######################EDUCHAT######################################


########################## Agent Direct Chats ############################

sub rfli_medical_questions
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $token = $api_data->{token};

    my $sql = qq{SELECT * FROM `bot_items` WHERE `bot` IN (SELECT `id` FROM `bots` WHERE `queue`="bot_rfli" AND `active`="1") AND `check`=0 AND `enabled`="1" ORDER BY `item_id` ASC};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get bot items\n";
    my ($Items) = $rep->fetchall_hashref("item_id");
    $rep->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    my $question;

    print "first msg c item is $api_data->{current_item}\n";

    #my $i = $api_data->{current_item} // (sort keys %$Items)[0];
    my $i = $api_data->{current_item} || 1;

    my  $max_items = scalar keys %$Items;

    print "max items is $max_items and i is $i\n";

    if($api_data->{medical_questions_init}){
        $api_data->{medical_questions_init} = 0;
        $question = $Items->{$i}->{text};
        $api_data->{current_item} = $i + 1;
    }else{
        $i = ($i-1);
        if ( $i <= $max_items ) {
            my $field   = $Items->{$i}->{field};
            $i = ($i +1);
            my $type    = $Items->{$i}->{type};
            my $id       = $Items->{$i}->{id};
            $question = $Items->{$i}->{text};
            $api_data->{stream_data}->{$stream_name}->{$field} = $api_data->{chats}->{$latest_chat_id}->{content_text};
            print STDERR "field is $field and ans is $api_data->{chats}->{$latest_chat_id}->{content_text}";
            $api_data->{current_item} = $i + 1;
            if ( $i > $max_items ) {
                $question = "A Nurse will be in contact with you shortly, allow up to 1 hour for assistance.";
                $api_data->{stream}->{current} = "telehealth_gp";
                $self->{stream}->add($api_data->{stream}->{current},$api_data);
            }
        }else{
            $question = "A Nurse will be in contact with you shortly, allow up to 1 hour for assistance.";
            $api_data->{stream}->{current} = "telehealth_gp";
            $self->{stream}->add($api_data->{stream}->{current},$api_data);
        }
    }

    if(defined($question)){
        # Send the question
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $question,
		$token
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $question,
        "", "", "","", "", "", "");
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    $redis->expire($api_key,"86400");
}

sub telehealth_gp
{
    print STDERR "in tele sub\n";
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $pol = $api_data->{info}->{policy}->{policy_no};
    my $dc;
    if ($api_data->{info}->{policy}->{src} eq "rfli") {
        (undef, $dc) = split /-/, $api_data->{stream_data}->{rfli_dc_menu}->{dc};
        $api_data->{info}->{policy}->{pdckey} = 'NBCEE' . substr('00000000' . $pol, -8).":".$dc;
        $api_data->{info}->{policy}->{policy_no} = 'NBCEE' . substr('00000000' . $pol, -8);
    }else{
        (undef, $dc) = split /-/, $api_data->{stream_data}->{dc_menu}->{dc};
        $api_data->{info}->{policy}->{pdckey} = $pol.":".$dc;
    }

    my $bucket = "1";
    my $queue = "2";
    my $status = "1";

    my $sql = qq{SELECT policy_no FROM tickets where policy_no="$pol" and status="1"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not check for duplicate tickets\n";
    my($check) = $rep->fetchrow_array();
    $rep->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    if (!$check) {
        my $sql = qq{INSERT INTO `tickets` (`api_session`, `policy_no`, `dc`, `queue_id`, `bucket_id`, `status`, `date_created`, `pdckey`) 
            VALUES ("$api_key", "$api_data->{info}->{policy}->{policy_no}", "$dc", "$queue", "$bucket", "$status", NOW(), "$api_data->{info}->{policy}->{pdckey}" ) };
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could create ticket");
        my $t_id = $rep->{mysql_insertid};
        $rep->finish;

        $api_data->{ticket}->{bucket} = $bucket;
        $api_data->{ticket}->{id} = $t_id;
        $api_data->{ticket}->{status} = $status;
        $api_data->{ticket}->{queue} = $queue;

    }else{
        my  $msg = "A Nurse will be in contact with you shortly, allow up to 1 hour for assistance.";
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $msg
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
        "", "", "","", "", "", "");
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub nbc_pss
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    print "create ticket for sess $api_key\n";

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $pol = $api_data->{info}->{policy}->{policy_no};
    my $dc;
    if ($api_data->{info}->{policy}->{src} eq "rfli") {
        (undef, $dc) = split /-/, $api_data->{stream_data}->{rfli_dc_menu}->{dc};
        $api_data->{info}->{policy}->{pdckey} = 'NBCEE' . substr('00000000' . $pol, -8).":".$dc;
        $api_data->{info}->{policy}->{policy_no} = 'NBCEE' . substr('00000000' . $pol, -8);
    }else{
        (undef, $dc) = split /-/, $api_data->{stream_data}->{dc_menu}->{dc};
        $api_data->{info}->{policy}->{pdckey} = $pol.":".$dc;
    }
    # my $pol = $api_data->{info}->{policy}->{prono};
    # my (undef, $dc) = split /-/, $api_data->{stream_data}->{dc_menu}->{dc};
    my $bucket = "6";
    my $queue = "5";
    my $status = "1";

    my $check;
    my $check2;

    if(defined($pol)){
        my $sql = qq{SELECT policy_no FROM tickets WHERE policy_no="$pol" AND status="1"};
        print $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute() || croak "Could not execute SQL query: $DBI::errstr\n";
        $check = $rep->fetchrow_array();
        $rep->finish;
    }

    my $sql2 = qq{SELECT api_session FROM tickets WHERE api_session="$api_key" AND status="1"};
    print $sql2."\n";
    my $rep2 = $dbh->prepare($sql2);
    $rep2->execute() || croak "Could not execute SQL query: $DBI::errstr\n";
    $check2 = $rep2->fetchrow_array();
    $rep2->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    if ( (defined($check)) || (defined($check2)) ) {

        my $msg = "Your query has been received, allow up to 30 minutes for assistance.";
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $msg
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
        "", "", "","", "", "", "");

    }else{
        my $sql = qq{INSERT INTO `tickets` (`api_session`, `policy_no`, `dc`, `queue_id`, `bucket_id`, `status`, `date_created`, `pdckey`) 
            VALUES ("$api_key", "$api_data->{info}->{policy}->{policy_no}", "$dc", "$queue", "$bucket", "$status", NOW(), "$api_data->{info}->{policy}->{pdckey}" ) };
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could create ticket");
        my $t_id = $rep->{mysql_insertid};
        $rep->finish;

        $api_data->{ticket}->{bucket} = $bucket;
        $api_data->{ticket}->{id} = $t_id;
        $api_data->{ticket}->{status} = $status;
        $api_data->{ticket}->{queue} = $queue;
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub nbc_rfli
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();

    print "create ticket for sess $api_key\n";

    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $pol = $api_data->{info}->{policy}->{policy_no};
    my $token = $api_data->{token};
    my $dc;
    if ($api_data->{info}->{policy}->{src} eq "rfli") {
        (undef, $dc) = split /-/, $api_data->{stream_data}->{rfli_dc_menu}->{dc};
        $api_data->{info}->{policy}->{pdckey} = 'NBCEE' . substr('00000000' . $pol, -8).":".$dc;
        $api_data->{info}->{policy}->{policy_no} = 'NBCEE' . substr('00000000' . $pol, -8);
    }else{
        (undef, $dc) = split /-/, $api_data->{stream_data}->{dc_menu}->{dc};
        $api_data->{info}->{policy}->{pdckey} = $pol.":".$dc;
    }
    # my $pol = $api_data->{info}->{policy}->{prono};
    # my (undef, $dc) = split /-/, $api_data->{stream_data}->{dc_menu}->{dc};
    my $bucket = "5";
    my $queue = "5";
    my $status = "1";

    my $check;
    my $check2;

    if(defined($pol)){
        my $sql = qq{SELECT policy_no FROM tickets WHERE policy_no="$pol" AND status="1"};
        print $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute() || croak "Could not execute SQL query: $DBI::errstr\n";
        $check = $rep->fetchrow_array();
        $rep->finish;
    }

    my $sql2 = qq{SELECT api_session FROM tickets WHERE api_session="$api_key" AND status="1"};
    print $sql2."\n";
    my $rep2 = $dbh->prepare($sql2);
    $rep2->execute() || croak "Could not execute SQL query: $DBI::errstr\n";
    $check2 = $rep2->fetchrow_array();
    $rep2->finish;

    my $latest_chat_id = &get_last_chatid($api_data);

    if ( (defined($check)) || (defined($check2)) ) {

        my $msg = "Your query has been received, allow up to 30 minutes for assistance.";
        &send_apex(
            $self,
            $api_data->{chats}->{$latest_chat_id}->{remote_session},
            $api_data->{chats}->{$latest_chat_id}->{channel},
            $api_data->{chats}->{$latest_chat_id}->{from},
            $msg,
            $token
        );

        &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
        $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

        &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
        "", "", "","", "", "", "");

    }else{
        my $sql = qq{INSERT INTO `tickets` (`api_session`, `policy_no`, `dc`, `queue_id`, `bucket_id`, `status`, `date_created`, `pdckey`) 
            VALUES ("$api_key", "$api_data->{info}->{policy}->{policy_no}", "$dc", "$queue", "$bucket", "$status", NOW(), "$api_data->{info}->{policy}->{pdckey}" ) };
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could create ticket");
        my $t_id = $rep->{mysql_insertid};
        $rep->finish;

        $api_data->{ticket}->{bucket} = $bucket;
        $api_data->{ticket}->{id} = $t_id;
        $api_data->{ticket}->{status} = $status;
        $api_data->{ticket}->{queue} = $queue;
    }

    $redis->set( $api_key, $self->{script}->encode($api_data) );
    #$redis->persist($api_key);
    $redis->expire($api_key,"86400");
}

sub close_ticket
{
    my $self    = shift;
    my $api_key = shift;
    my $redis   = $self->{script}->redis("local");
    my $dbh     = $self->{script}->getdb("omni");
    my $ts      = time();


    $redis->select(2);
    my $api_data    = $self->{script}->decode( $redis->get($api_key) );
    my $stream_name = $api_data->{stream}->{current};
    my $token = $api_data->{token};

    my $latest_chat_id = &get_last_chatid($api_data);
    my $msg = "Your ticket has been closed.";
    
    &send_apex(
        $self,
        $api_data->{chats}->{$latest_chat_id}->{remote_session},
        $api_data->{chats}->{$latest_chat_id}->{channel},
        $api_data->{chats}->{$latest_chat_id}->{from},
        $msg,
        $token
    );

    &log_message($self,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", $api_data->{chats}->{$latest_chat_id}->{medium}, $api_data->{chats}->{$latest_chat_id}->{from}, 
    $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg, "", "", "", "" ,$stream_name, "");

    &add_chat_to_session($api_data,$api_data->{chats}->{$latest_chat_id}->{channel}, "bot", "", "whatsapp", $api_data->{chats}->{$latest_chat_id}->{channel}, $api_data->{chats}->{$latest_chat_id}->{remote_session}, $api_key, "text", $msg,
    "", "", "","", "", "", "");
        
    $redis->del($api_key);
}

########################## Apex Functions ################################
sub send_apex 
{
    my $self           = shift;
    my $remote_session = shift;
    my $channel        = shift;
    my $client         = shift;
    my $msg            = shift;
    my $token          = shift;
    $msg =~ s/U\+1F44B/👋/g;

    my $ua    = $self->{ua};
    my $url   = $self->{script}->variable("apexurl");
    #my $token = $self->{script}->variable("apexkey");

    my $data = {
        message => {
            channelType => "whatsapp",
            to          => $client,
            from        => $channel,
            type        => "text",
            content     => {
                #text => $msg
                text => encode_utf8($msg)
            }
        }
    };

    my $req = POST(
        $url,
        Authorization => "Bearer $token",
        Content       => $self->{script}->encode($data),
        Content_Type  => 'application/json',  # Specify the content type as JSON
    );

    my $response = $self->{ua}->request($req);
    print STDERR Dumper($response);
	return $response;
}

sub apex_list 
{
    my $self           = shift;
    my $remote_session = shift;
    my $channel        = shift;
    my $client         = shift;
    my $Menu           = shift;
    my $heading        = shift;
    my $token          = shift;

    my $ua    = $self->{ua};
    my $url   = $self->{script}->variable("apexurl");
    #my $token = $self->{script}->variable("apexkey");

    my $sections = [];
    foreach my $key ( sort keys %$Menu ) {
        my $title = $Menu->{$key};
        push @$sections, {
            id    => $key,
            title => $title,
            # description => "Description for $title",
        };
    }

    my $data = {
        message => {
            channelType => "whatsapp",
            to          => $client,
            from        => $channel,
            type        => "list",
            content     => {
                header => {
                    type  => "text",
                    value => "Choose option",
                },
                body     => $heading,
                footer   => "Choose an option",
                sections => [
                    {
                        title => "Select Option",
                        items => $sections,
                    }
                ]
            }
        }
    };

    my $req = POST(
        $url,
        Authorization => "Bearer $token",
        Content       => $self->{script}->encode($data),
        Content_Type  => 'application/json',  # Specify the content type as JSON
    );

    my $response = $self->{ua}->request($req);
    return $response;
}

sub send_apex_file
{
    my $self           = shift;
    my $remote_session = shift;
    my $channel        = shift;
    my $client         = shift;
    my $file            = shift;
    my $token          = shift;

    my $ua    = $self->{ua};
    my $url   = $self->{script}->variable("apexurl");
    #my $token = $self->{script}->variable("apexkey");

    my $data = {
        message => {
            channelType => "whatsapp",
            to          => $client,
            from        => $channel,
            type        => "file",
            content     => {
                url => $file
            }
        }
    };

    print STDERR Dumper($data);

    my $req = POST(
        $url,
        Authorization => "Bearer $token",
        Content       => $self->{script}->encode($data),
        Content_Type  => 'application/json',  # Specify the content type as JSON
    );

    my $response = $self->{ua}->request($req);
    print STDERR Dumper($response);
    return $response;
}

############################################################################


1;
