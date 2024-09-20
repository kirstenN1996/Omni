package Omni::Admin;
use strict;
use Data::Dumper;
use Omni::Stream;
use Carp qw(croak);

sub new
{
    my $class = shift;
    my $self = {};
    bless $self,$class;
    return $self;

}

sub get_key
{
    my $self = shift;
    my $request = shift;
    my $pol = $request->param("p");
    my $dbh = $request->getdb("omni");

    my $sql = qq{select api_session from tickets where policy_no="$pol" and status="3" order by id desc limit 1;};
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get api session for policy";
    my($key) = $rep->fetchrow_array();
    $rep->finish();
    
    return {k=>$key};
}

sub get_tickets
{
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");
    my $queue = $request->param("q");
    my $bucket = $request->param("b");

    croak("Invalid queue provided") unless $queue;
    croak("Invalid bucket provided") unless $bucket;

    my $sql = qq{SELECT * FROM tickets where status = "1" and queue_id="$queue" and bucket_id="$bucket"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get tickets";
    my($Data) = $rep->fetchall_hashref("id");
    $rep->finish();
    
    return $Data;
}

sub get_ticket
{
    my $self = shift;
    my $request = shift;
	print STDERR "************************************************\n";
	print STDERR Dumper($request);
	print STDERR "************************************************\n";

    my $key = $request->param("key");
    my $redis = $request->redis("local");
    $redis->select("2");
    croak "Whatsapp session expired." unless $redis->exists($key);

    my $api_data = $request->decode( $redis->get($key) );
    my $Data = $api_data->{chats};

    return $Data;
}

sub take_ticket
{
    my $self = shift;
    my $request = shift;

    my $sid = $request->param("user");
    my $ticket = $request->param("ticket");
    my $key = $request->param("key");

    croak("No User provided") unless ($sid);
    croak("No ticket provided") unless ($ticket);
    croak("No API key provided") unless ($key);

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");

    my $sql = qq{SELECT * FROM tickets where id="$ticket" and agent_sid is null};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "could not check for duplicate tickets\n";
    my $Data = $rep->fetchrow_hashref();
        
    if ( $rep->rows > 0 ) {
        my $sql = qq{UPDATE `tickets` SET `status` = "3", agent_sid="$sid", date_assigned=NOW() where id="$ticket"};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not update ticket");
        $rep->finish;

        my $sql = qq{select `from` from chat_messages where api_session="$Data->{api_session}" and from_src="client" order by id asc limit 1;};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not get tel for ticket");
        $Data->{tn} = $rep->fetchrow_array();
        $rep->finish;

        $redis->select(2);
        croak "Whatsapp session expired." unless $redis->exists($key);

        my $api_data = $request->decode( $redis->get($key) );

        $api_data->{stream}->{current} = "agent_direct";
        $api_data->{ticket}->{agent} = $sid;
        $request->{stream}->add($api_data->{stream}->{current},$api_data);

        $redis->set( $key, $request->encode($api_data) );
        # $redis->persist($key);
        $redis->expire($key,"86400");
    }else{
        return{error=>"Relax - someone else has this"};
    }

    $rep->finish;

    return $Data;
}

sub close_ticket
{
    my $self = shift;
    my $request = shift;
    my $stream 	= Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));

    my $sid = $request->param("sid");
    my $ticket = $request->param("ticket");
    my $key = $request->param("key");

    print STDERR Dumper($request->{param});

    croak("No User provided") unless ($sid);
    croak("No ticket provided") unless ($ticket);
    croak("No API key provided") unless ($key);

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");
    $redis->select("2");

    my $api_data = $request->decode( $redis->get($key) );

    my $sql = qq{UPDATE `tickets` SET `status` = "2",`date_closed` = NOW() WHERE `id` = "$ticket"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak("Could not update ticket status");
    $rep->finish;


    $stream->add("close_ticket",$api_data);

    return $request->{param};
}

sub close_telecare_ticket
{
    my $self = shift;
    my $request = shift;
    my $stream 	= Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));

    my $key = $request->param("key");

    croak("No Session key provided") unless ($key);

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");
    $redis->select("2");

    my $api_data = $request->decode( $redis->get($key) );
    my $ticket = $api_data->{ticket}->{id};
    if($ticket){
        my $sql = qq{UPDATE `tickets` SET `status` = "2",`date_closed` = NOW() WHERE `id` = "$ticket"};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not update ticket status");
        $rep->finish;

        $stream->add("close_ticket",$api_data);
    }else{
        croak("no whatsapp ticket found");
    }

    return $request->{param};
}

sub get_queues
{ 
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");
    my @Data;

    my $sql = qq{select `buckets`.*,queues.queue
        from `buckets`
        left join `queues` 
        on buckets.queue_id = queues.id
        where queues.active="1"
    };
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get queues";
    while(my $row = $rep->fetchrow_hashref()){
        push(@Data,$row);
    }
    #my($Data) = $rep->fetchall_hashref("id");
    $rep->finish();
    
    return \@Data;
}

sub tmc_queues
{
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");

    my $sql = qq{select `buckets`.*,queues.queue
        from `buckets`
        left join `queues` 
        on buckets.queue_id = queues.id
        where queues.active="1" and buckets.id in("1","5")};
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get queues";
    my($Data) = $rep->fetchall_hashref("id");
    $rep->finish();
    
    return $Data;
}

sub transfer_ticket
{
    ###this stream needs to be updated and provessor should do the rest
    ####need to add lifeline here 
    my $self = shift;
    my $request = shift;
    my $stream 	= Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));

    my $key = $request->param("k");
    my $bucket = $request->param("b");
    my $sid = $request->param("s");
    #my $ticket = $request->param("ticket");

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");

    my $sql = qq{SELECT `stream`,`queue_id` FROM `buckets` WHERE `id`="$bucket"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get queue details";
    my($stream_name, $queue) = $rep->fetchrow_array();
    $rep->finish();

    $redis->select(2);
    my $api_data = $request->decode( $redis->get($key) );
    $api_data->{stream}->{current} = $stream_name;

    my $ticket = $api_data->{ticket}->{id};

    $api_data->{ticket}->{bucket} = $bucket;
    # $api_data->{ticket}->{id} = $ticket;
    $api_data->{ticket}->{status} = "1";
    $api_data->{ticket}->{queue} = $queue;
    
    my $sql = qq{UPDATE `tickets` SET `queue_id`="$queue", `bucket_id`="$bucket", `status` = "1",`date_modified` = NOW(),agent_sid=NULL WHERE `id` = "$ticket"};
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak("Could not transfer ticket");
    $rep->finish;

    $redis->set( $key, $request->encode($api_data) );
    $redis->expire($key,"86400");
    $stream->add($api_data->{stream}->{current},$api_data);

    return $request->{param};
}

sub chat_history
{
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");
    my $pol = $request->param("p");

    croak("Invalid policy number provided.") unless $pol;

    my $sql = qq{SELECT tickets.*,src_states.state
        FROM tickets 
        left join src_states on src_states.id = tickets.status
        where tickets.policy_no = "$pol"
        order by date_closed desc
    };
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get chat history";
    my($Data) = $rep->fetchall_hashref("id");
    $rep->finish();
    
    return $Data;
}

sub get_chat
{
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");
    my $key = $request->param("k");

    croak("Invalid API key provided.") unless $key;

    my $sql = qq{SELECT * FROM chat_messages where api_session="$key" order by id asc;};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get chat history";
    my($Data) = $rep->fetchall_hashref("id");
    $rep->finish();
    
    return $Data;
}

sub wa_avail
{
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");
    my $phone = $request->param("phone");

    croak("Invalid phone number provided.") unless $phone;

    my $sql = qq{SELECT number FROM opt_in where number="$phone" and whatsapp=1};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get chat history";
    my($opt) = $rep->fetchrow_array();
    $rep->finish();

    my $Data;

    if($opt){
        my $sql = qq{select `api_session` from chat_messages where `from`="$phone" order by id desc limit 1};
        my $rep = $dbh->prepare($sql);
        $rep->execute || die "Could not get chat history";
        my($key) = $rep->fetchrow_array();
        $rep->finish();

        $redis->select("2");

        my $active = '0';
        if ($redis->exists($key)) {
            $active = '1';
        }

        $Data = {
            api_session => $key,
            active => $active
        };

        # my $sql = qq{SELECT tickets.* ,chat_messages.*
        #     from tickets
        #     left join chat_messages
        #     on chat_messages.api_session = tickets.api_session
        #     WHERE tickets.status IN ("1","3") AND tickets.api_session="$key" ORDER BY tickets.date_created
        # };
        # print STDERR $sql."\n";
        # my $rep = $dbh->prepare($sql);
        # $rep->execute();
        # my @messages;
        # while (my $row = $rep->fetchrow_hashref) {
        #     push @messages, $row;
        # }
        # $rep->finish;

        # $Data->{chats} = \@messages;
    }
        
    return $Data;
}

sub prosales_assign
{
    my $self    = shift;
    my $request = shift;

    my $sid = $request->param("user");
    my $key = $request->param("key");

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");

    my $sql = qq{SELECT * FROM tickets where api_session="$key"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "could not check for existing ticket\n";
    my $Data = $rep->fetchrow_hashref();
    $rep->finish;
        
    my $sql = qq{UPDATE `tickets` SET `status` = "3", agent_sid="$sid", date_assigned=NOW(), date_modified=NOW() where id="$Data->{id}"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak("Could not update ticket");
    $rep->finish;

    # my $sql = qq{select `from` from chat_messages where api_session="$Data->{api_session}" and from_src="client" order by id asc limit 1;};
    # print STDERR $sql."\n";
    # my $rep = $dbh->prepare($sql);
    # $rep->execute || croak("Could not get tel for ticket");
    # $Data->{tn} = $rep->fetchrow_array();
    # $rep->finish;

    $redis->select(2);
    if($redis->exists($key)){
        my $api_data = $request->decode( $redis->get($key) );

        $api_data->{stream}->{current} = "agent_direct";
        $api_data->{ticket}->{agent} = $sid;
        $request->{stream}->add($api_data->{stream}->{current},$api_data);

        $redis->set( $key, $request->encode($api_data) );
        # $redis->persist($key);
        $redis->expire($key,"86400");
    }

    return $Data;
}

# sub get_assigned 
# {
#     my $self = shift;
#     my $request = shift;

#     my $dbh = $request->getdb("omni");
#     my $redis = $request->redis("local");
#     my $sid = $request->param("user");
#     croak("Invalid sid supplied.") unless $sid;

#     # Fetch all chat messages
#     my $sql = qq{SELECT * FROM chat_messages};
#     my $rep = $dbh->prepare($sql);
#     $rep->execute || die "could not get chat messages";
#     my @messages;
#     while (my $row = $rep->fetchrow_hashref) {
#         push @messages, $row;
#     }
#     $rep->finish;

#     # Fetch all tickets
#     my $sql = qq{SELECT * FROM tickets where status in("1","3") and agent_sid="$sid" order by date_created};
#     print STDERR $sql."\n";
#     my $rep = $dbh->prepare($sql);
#     $rep->execute();
#     my @tickets;
#     while (my $row = $rep->fetchrow_hashref) {
#         push @tickets, $row;
#     }
#     $rep->finish;

#     # Sort tickets by date_created in descending order
#     @tickets = sort { $b->{date_created} cmp $a->{date_created} } @tickets;

#     my $Data;

#     $redis->select("2");

#     foreach my $ticket (@tickets) {
#         my $api_session = $ticket->{api_session};
#         my $active = '0';
#         if ($redis->exists($api_session)) {
#             $active = '1';
#         }
#         $ticket->{active} = $active;
#         $ticket->{tel} = "";
#         $Data->{$api_session} = {
#             ticket => $ticket,
#             chats => [],
#             #active => $active,
#             #tel => ""
#         };
#     }

#     foreach my $chat (@messages) {
#         my $api_session = $chat->{api_session};
#         if (exists $Data->{$api_session}) {
#             if($chat->{from_src} eq "client"){
#                 $Data->{$api_session}->{ticket}->{tel} = $chat->{from};
#             }
#             push @{$Data->{$api_session}->{chats}}, $chat;
#         }
#         # if (exists $Data->{$api_session}) {
#         #     push @{$Data->{$api_session}->{chats}}, $chat;
#         # }
#     }

#     return $Data;
# }

sub get_assigned_list
{
    my $self = shift;
    my $request = shift;

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");
    my $sid = $request->param("user");

    croak("Invalid sid supplied.") unless $sid;
    # Fetch all tickets
    my $sql = qq{SELECT * FROM tickets WHERE status IN ("1","3") AND agent_sid="$sid" ORDER BY date_created};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute();
    my($Data) = $rep->fetchall_hashref("api_session");
    $rep->finish;

    $redis->select("2");

    foreach my $key(keys %$Data){
        my $active = '0';
        if ($redis->exists($key)) {
            $active = '1';
        }
        $Data->{$key}->{active} = $active;

        my $sql = qq{select `from` from chat_messages where api_session="$key" order by id asc limit 1};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute();
        $Data->{$key}->{tel} = $rep->fetchrow_array();
        $rep->finish;
    }

    return $Data;
}

sub get_chat_history 
{
    my $self = shift;
    my $request = shift;
    print STDERR Dumper($request);

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");
    # my $key = $request->param("key");
    my $tel = $request->param("tel");

    croak("Invalid whatsapp number supplied.") unless $tel;

    # Fetch chat messages for the given API session
    #my $sql = qq{SELECT * FROM chat_messages WHERE api_session = "$key"};
    # my $sql = qq{
    #     select * from chat_messages 
    #     left join tickets on tickets.api_session = chat_messages.api_session
    #     where `from`= "$tel" or channel = "$tel"
    #     order by chat_messages.id desc limit 50
    # };
    my $sql = qq{
    select * from chat_messages 
        where `from`= "$tel" or channel = "$tel"
        order by id desc limit 50
    };
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute() || die "could not get chat messages";
    my @messages;
    while (my $row = $rep->fetchrow_hashref) {
        push @messages, $row;
    }
    $rep->finish;
	
    #$tel = /^0/27/;
	my $sql = qq {update chat_messages set date_seen = NOW() where from_src = "client" and `from` = "$tel" and date_seen is null};
	print STDERR "SQL: $sql\n";
	my $rep = $dbh->prepare($sql);
	$rep->execute || croak("Could not update Date Seen");
	$rep->finish;


    return \@messages;
}

sub get_all
{
    my $self = shift;
    my $request = shift;

    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");

    # Fetch all chat messages
    my $sql = qq{SELECT * FROM chat_messages};
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "could not get chat messages";
    my @messages;
    while (my $row = $rep->fetchrow_hashref) {
        push @messages, $row;
    }
    $rep->finish;

    # Fetch all tickets
    my $sql = qq{SELECT * FROM `tickets` where `status` IN("1","3") and bucket_id in("7") and queue_id="1"};
	print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute();
    my @tickets;
    while (my $row = $rep->fetchrow_hashref) {
        push @tickets, $row;
    }
    $rep->finish;

    # Sort tickets by date_created in descending order
    @tickets = sort { $b->{date_created} cmp $a->{date_created} } @tickets;

    my $Data;

    $redis->select("2");

    foreach my $ticket (@tickets) {
        my $api_session = $ticket->{api_session};
        my $active = '0';
        if ($redis->exists($api_session)) {
            $active = '1';
        }
        $Data->{$api_session} = {
            ticket => $ticket,
            chats => [],
            active => $active,
            tel => ""
        };
    }

    # foreach my $chat (@messages) {
    #     my $api_session = $chat->{api_session};
    #     if($chat->{from_src} eq "client"){
    #         $Data->{$api_session}->{tel} = $chat->{from};
    #     }
    #     if (exists $Data->{$api_session}) {
    #         push @{$Data->{$api_session}->{chats}}, $chat;
    #     }
    # }
    foreach my $chat (@messages) {
        my $api_session = $chat->{api_session};
        if (exists $Data->{$api_session}) {
            if ($chat->{from_src} eq "client") {
                $Data->{$api_session}->{tel} = $chat->{from};
            }
            push @{$Data->{$api_session}->{chats}}, $chat;
        }
    }

    # Print the hash reference
    return $Data;
}

sub get_phone_chat
{
    my $self = shift;
    my $request = shift;
    my $dbh = $request->getdb("omni");
    my $redis = $request->redis("local");
    my $phone = $request->param("phone");
    my $Data;

    croak("Invalid phone number provided.") unless $phone;

    my $sql = qq{select `api_session` from chat_messages where `from`="$phone" and from_src="client" order by id desc limit 1};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get queue details";
    my($key) = $rep->fetchrow_array();
    $rep->finish();

    my $sql = qq{
        select * from chat_messages 
        left join tickets on tickets.api_session = chat_messages.api_session
        where `from`= "$phone" or channel = "$phone"
        order by chat_messages.id desc limit 200
    };
    my $rep = $dbh->prepare($sql);
    $rep->execute() || die "could not get chat messages";
    my @messages;
    while (my $row = $rep->fetchrow_hashref) {
        push @messages, $row;
    }
    $rep->finish;

    $redis->select("2");

    my $active = '0';
    if ($redis->exists($key)) {
        $active = '1';
    }
    $Data->{active} = $active;

    # my $sql = qq{SELECT * FROM chat_messages WHERE api_session = "$key"};
    # my $rep = $dbh->prepare($sql);
    # $rep->execute() || die "could not get chat messages";
    # my @messages;
    # while (my $row = $rep->fetchrow_hashref) {
    #     push(@messages, $row);
    # }
    # $rep->finish;
    # my @messages;
    # while (my $row = $rep->fetchrow_hashref) {
    #     push @messages, $row;
    # }
    # $rep->finish;
    $Data->{chats} = \@messages;

    return $Data;
}

1;
