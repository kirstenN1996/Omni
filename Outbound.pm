package Omni::Outbound;
use strict;
use LWP::UserAgent;
use HTTP::Request::Common;
use Carp qw(croak);
use Omni::Stream;
use Data::Dumper;
use CGI;
use CGI::Upload;
use CGI::Carp qw(fatalsToBrowser);
use File::Basename;
use POSIX qw(strftime);
use File::Path qw(make_path);
use Affinity::Validate;
use LWP::Simple;
use URI::Escape::XS;
use Date::Manip;

sub new
{
	my $class = shift;
	my $self = {
		ua => LWP::UserAgent->new
	};
	bless $self,$class;
	return $self;
}

sub wa
{
	# maybe like this i dont know
}

sub apex_reply
{
	my $self 	= shift;
	my $request = shift;
	my $stream 	= Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));
	my $sid		= $request->param("sid");
	my $name	= $request->param("name");
	my $key		= $request->param("key");
	#my $msg		= '*'.$name.':* \n'.$request->param("message");
	my $msg		= $request->param("message");

	my $redis 	= $request->redis("local");
	my $dbh	 	= $request->getdb("omni");

	$redis->select(2);
	croak "Whatsapp session expired." unless $redis->exists($key);
    my $api_data  = $request->decode( $redis->get($key) );

	###check if lst msg is bot/agent to as the agent cannot send msg to self
	my $latest_chat_id;
    my $latest_timestamp = 0;
    foreach my $k ( keys %{ $api_data->{chats} } ) {
		next if($api_data->{chats}->{$k}->{from_src} eq "bot" || $api_data->{chats}->{$k}->{from_src} eq "agent");
        my $timestamp = $api_data->{chats}->{$k}->{date_arrived};
        if ( $timestamp && $timestamp > $latest_timestamp ) {
            $latest_chat_id   = $k;
            $latest_timestamp = $timestamp;
        }
    }

    my $channel = $api_data->{chats}->{$latest_chat_id}->{channel};
    my $client  = $api_data->{chats}->{$latest_chat_id}->{from};
	my $stream_name = $api_data->{stream}->{current};
    my $token = $api_data->{token};



    my $ua    = $self->{ua};
    my $url   = $request->value("apexurl");
    #my $token = $request->value("apexkey");

    my $data = {
        message => {
            channelType => "whatsapp",
            to          => $client,
            from        => $channel,
            type        => "text",
            content     => {
                text => $msg
            }
        }
    };

    my $req = POST(
        $url,
        Authorization => "Bearer $token",
        Content       => $request->encode($data),
        Content_Type  => 'application/json',  # Specify the content type as JSON
    );

    my $response = $self->{ua}->request($req);
	print STDERR Dumper($response);
	my $ts = time();

    $api_data->{chats}->{$ts} = {
	    from => $api_data->{chats}->{$latest_chat_id}->{channel},
	    from_src => "agent",
	    from_sid => $sid,
	    medium => "whatsapp",
	    channel => $api_data->{chats}->{$latest_chat_id}->{channel},
	    remote_session => $api_data->{chats}->{$latest_chat_id}->{remote_session},
	    api_session => $key,
	    content_type => "text",
	    content_text => $msg,
	    content_remote_url => "",
	    content_caption => "",
	    content_local_url => "",
	    content_local_file => "",
	    date_arrived => $ts,
	    date_seen => "",
	    seen_by => "",
	    replied => ""
	};

    $redis->set( $key, $request->encode($api_data) );
    # $redis->persist($key);
	$redis->expire($key,"86400");
	my $stream_id = $stream->add($stream_name,$api_data);

	my $sql = qq {insert into chat_messages(`from`,`from_src`,`from_sid`,`medium`,`channel`,`remote_session`,`api_session`,
	    `content_type`,`content_text`,`content_caption`,`content_remote_url`,`content_local_url`,`content_local_file`,
	    `date_arrived`,`stream_name`,`stream_id`) 
	    values("$channel", "agent", "$sid", "$api_data->{chats}->{$latest_chat_id}->{medium}" , "$client", "$api_data->{chats}->{$latest_chat_id}->{remote_session}", 
	    "$key", "text", "$msg", "", "", "", "" , NOW() , "$stream_name", "$stream_id") };
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak("Could not Add Agent Response to Chats Table");
    $rep->finish;

	return $redis->get($key);
}

sub apex_file
{
    print STDERR "made it here\n";
	##upload file to server...
	my $self 		= shift;
	my $request 	= shift;
	print STDERR Dumper($request);
	my $stream 		= Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));
    my $root        = "/var/www/omni/files";
    my $date        = $self->{date};
    $date           = ParseDate("now");
    my $year        = &UnixDate($date,"%Y");
    my $month       = &UnixDate($date,"%m");
    my $day         = &UnixDate($date,"%d");

	my $sid			= $request->param("sid");
	my $key			= $request->param("key");
	my $file		= $request->param("file");
	my $type 		= $request->param("type");

    print STDERR Dumper($request->{param});

    croak("No sid provided.") unless $sid;
    croak("No api key provided.") unless $key;
    croak("No file provided.") unless $file;
    croak("No file type provided.") unless $type;

    my $utype;
    if ($type =~ /\bimage\b/) {
        $utype = "image";
    }else{
        $utype = "file";
    }

	my $redis 		= $request->redis("local");
	my $dbh	 		= $request->getdb("omni");

	$redis->select(2);
	croak "Whatsapp session expired." unless $redis->exists($key);
    my $api_data  = $request->decode( $redis->get($key) );

    my $token = $api_data->{token};


	my $new_path    = $root."/".$year."/".$month."/".$day;
    if(!-d $new_path){
    	make_path($new_path) || die "Could not create folder $new_path";
    }

	$CGI::POST_MAX = 1024 * 5000;
    my $safe_filename_characters = "a-zA-Z0-9_.-";
    my $upload_dir  = $new_path;
    my $query       = new CGI;
    my $filename    = $file;
    my $new_file    = $new_path."/".$filename;

	if ( !$filename ){
    	croak ($query->header());
		croak ("Upload failed. There was a problem uploading your file");
	}

    # split up file name and extension to avoid thwart
    my ( $name, $path, $extension ) = fileparse ( $filename, '..*' );
    $filename = $name . $extension;

    # substitute spaces with underscores
    $filename       =~ tr/ /_/;
    $filename       =~ s/[^$safe_filename_characters]//g;

    # check if the format matches and is safe for use
    if ( $filename =~ /^([$safe_filename_characters]+)$/ )
    {
        $filename = $1;
    }
    else
    {
    	die "Filename contains invalid characters";
    }

    my $upload_filehandle = $query->upload("file");

    #  We’ll use the uploaded file’s filename
    # —— now fully sanitised ——
    # as the name of our new file:

    open ( UPLOADFILE, ">>$upload_dir/$filename" ) or die "$!";
    binmode UPLOADFILE;

    while ( <$upload_filehandle> )
    {
    print UPLOADFILE;
    }

    close UPLOADFILE;

	my $new_name = $upload_dir."/".$filename;
    my $local_name = $upload_dir."/".$filename;
    $local_name =~ s|/var/www/omni|https://omni.affinityhealth.co.za|;
	$new_name =~ s|/var/www/omni|https://omni.affinityhealth.co.za|;

	###check if lst msg is bot/agent to as the agent cannot send msg to self
	my $latest_chat_id;
    my $latest_timestamp = 0;
    foreach my $k ( keys %{ $api_data->{chats} } ) {
		next if($api_data->{chats}->{$k}->{from_src} eq "bot" || $api_data->{chats}->{$k}->{from_src} eq "agent");
        my $timestamp = $api_data->{chats}->{$k}->{date_arrived};
        if ( $timestamp && $timestamp > $latest_timestamp ) {
            $latest_chat_id   = $k;
            $latest_timestamp = $timestamp;
        }
    }

    my $channel = $api_data->{chats}->{$latest_chat_id}->{channel};
    my $client  = $api_data->{chats}->{$latest_chat_id}->{from};
	my $stream_name = $api_data->{stream}->{current};

    my $ua    = $self->{ua};
    my $url   = $request->value("apexurl");
    #my $token = $request->value("apexkey");

    my $data = {
        message => {
            channelType => "whatsapp",
            to          => $client,
            from        => $channel,
            type        => $utype,
            content     => 
			{
                url 	=> $new_name
            }
        }
    };

    my $req = POST(
        $url,
        Authorization => "Bearer $token",
        Content       => $request->encode($data),
        Content_Type  => 'application/json',  # Specify the content type as JSON
    );

    my $response = $self->{ua}->request($req);
    print STDERR Dumper($response);
	my $ts = time();

    $api_data->{chats}->{$ts} = {
	    from => $api_data->{chats}->{$latest_chat_id}->{channel},
	    from_src => "agent",
	    from_sid => $sid,
	    medium => "whatsapp",
	    channel => $api_data->{chats}->{$latest_chat_id}->{channel},
	    remote_session => $api_data->{chats}->{$latest_chat_id}->{remote_session},
	    api_session => $key,
	    content_type => $utype,
	    content_text => "",
	    content_remote_url => "",
	    content_caption => "",
	    content_local_url => $local_name,
	    content_local_file => $filename,
	    date_arrived => $ts,
	    date_seen => "",
	    seen_by => "",
	    replied => ""
	};

    $redis->set( $key, $request->encode($api_data) );
    # $redis->persist($key);
	$redis->expire($key,"86400");
	my $stream_id = $stream->add($stream_name,$api_data);

	my $sql = qq {insert into chat_messages(`from`,`from_src`,`from_sid`,`medium`,`channel`,`remote_session`,`api_session`,
	    `content_type`,`content_text`,`content_caption`,`content_remote_url`,`content_local_url`,`content_local_file`,
	    `date_arrived`,`stream_name`,`stream_id`) 
	    values("$channel", "agent", "$sid", "$api_data->{chats}->{$latest_chat_id}->{medium}" , "$client", "$api_data->{chats}->{$latest_chat_id}->{remote_session}", 
	    "$key", "$utype", "", "", "", "$local_name","$filename", NOW() , "$stream_name", "$stream_id") };
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak("Could not Add Agent Response to Chats Table");
    $rep->finish;

	return $redis->get($key);
}

sub apex_template
{
	my $self 	= shift;
	my $request = shift;
	my $stream 	= Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));
    my $url     = $request->value("apexturl");
    #my $token   = $request->value("apexkey");
    my $client  = $request->param("client");
    my $bot     = $request->param("bot");
    my $key		= $request->param("key");
	my $sid		= $request->param("sid");
	my $tmp     = $request->param("tmp");

    my $redis 	= $request->redis("local");
	my $dbh	 	= $request->getdb("omni");

    my $sql = qq{SELECT `token` FROM `queues_wa` WHERE `number` = "$bot"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak "could not get token\n";
    my ($token) = $rep->fetchrow_array();
    $rep->finish;

    #my $sql = qq{SELECT `template`,`template_text` FROM `queues_wa` WHERE `number` = "$bot"};
    #my $rep = $dbh->prepare($sql);
    #$rep->execute || die "Could not get template";
    #my($tmp,$tmp_text) = $rep->fetchrow_array();
    #$rep->finish;

    my $sql = qq{SELECT `message` FROM `wa_templates` WHERE `template_name` = "$tmp"};
    print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || die "Could not get template";
    my($tmp_text) = $rep->fetchrow_array();
    $rep->finish;
    
    my $data = {
        to          => $client,
        from        => $bot,
        type        => "template",
        templateName => $tmp,
        category => "MARKETING",
        language => "en"
    };

    my $ua    = $self->{ua};

    my $req = POST(
        $url,
        Authorization => "Bearer $token",
        Content       => $request->encode($data),
        Content_Type  => 'application/json',  # Specify the content type as JSON
    );

    my $response = $self->{ua}->request($req);
    print STDERR Dumper($response);
    my $sql = qq {insert into chat_messages(`from`,`from_src`,`from_sid`,`medium`,`channel`,`remote_session`,`api_session`,
	    `content_type`,`content_text`,`content_caption`,`content_remote_url`,`content_local_url`,`content_local_file`,
	    `date_arrived`,`stream_name`,`stream_id`) 
	    values("$bot", "agent", "$sid", "whatsapp" , "$client", "",
	    "$key", "text", "$tmp_text", "", "", "","", NOW() , "", "") };
        print STDERR $sql."\n";
    my $rep = $dbh->prepare($sql);
    $rep->execute || croak("Could not Add Agent Response to Chats Table");
    $rep->finish;

    my $R = {
        message => $tmp_text,
        from_src => "agent",
        sid => $sid,
        ts => time()
    };

    return $R;

    #return $request->{param};

}

sub send_sms
{
        my $self = shift;
        my $request = shift;
        print STDERR Dumper($request);
        my $dbh = $request->getdb("omni");
        my $redis = $request->redis("local");
        my $tel = $request->param("to");
        my $sid = $request->param("sid");
        my $account = $request->param("account");
        my $template = $request->param("template");

        croak("SMS Failed. No Account Profided") unless $account;
        croak("SMS Failed. No Telephone Number Provided") unless $tel;
        croak("SMS Failed. No Template ID Provided") unless $template;

        my $validate = Affinity::Validate->new();
        $tel = $validate->phone_number($tel);
        croak("SMS Failed. Invalid Telephone Number Provided") unless $tel;

        my $sql = qq {select id from chat_messages where date_arrived > date_sub(now(), interval 24 hour) AND channel = "$tel"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("SMS Failed Could not Query SMS History");
        my($check) = $rep->fetchrow_array();
        $rep->finish;

        croak("SMS Failed. An sms was already sent to this person within the last 24 hours") unless(!$check);

        my $sql = qq {select * from sms_accounts where account_name = "$account" and active = "1"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("SMS Failed Could not fetch Account Details");
        my($A) = $rep->fetchrow_hashref();
        $rep->finish;

        my $sql = qq {select * from sms_templates where template_name = "prosales_wa_invite"};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("SMS Failed. Could not Retrieve SMS Template");
        my ($T) = $rep->fetchrow_hashref();
        $rep->finish;


        croak("SMS Failed. Template Contained no Message Data") unless defined $T->{message};
        croak("SMS Failed. Account not found") unless defined $A->{account_name};

        my $url = "http://sms.connet-systems.com/submit/single?";
        my %Data;
        $Data{username} = $A->{user};
        $Data{account} = $A->{account_name};
        $Data{password} = $A->{pass};
        $Data{da} = $tel;
        $Data{ud} = $T->{message};
        $Data{id} = '1111';

        foreach my $key(keys %Data){
                my $value = encodeURIComponent($Data{$key});
                $url = $url."\&".$key."=".$value;
        }
        my $response = get($url);
	print STDERR Dumper($response);


	
        my $sql = qq{
            INSERT INTO `opt_in` (`number`, `sms`, `last_update`, `last_sid`)
            VALUES ($tel, "1", NOW(), "$sid")
            ON DUPLICATE KEY UPDATE
            sms = VALUES(sms),
            last_update = NOW(),
            last_sid = VALUES(last_sid)
        };
	my $a = $sql;
	$a =~ s/\n/ /;
	print STDERR "SQL: $a\n";
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not write to opt_in table");
        $rep->finish;

        ###ps bug fix
        my $sql = qq{SELECT `api_session` FROM chat_messages where `from`="$tel" and from_src="client" order by id desc limit 1};
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not check for active api session");
        my($api_key) = $rep->fetchrow_array;
        $rep->finish;

        if(defined($api_key)){
            $redis->select("2");
            if($redis->exists($api_key)){
                print STDERR "updaing stream for sms sent\n";
                my $api_data    = $request->decode( $redis->get($api_key) );
                $api_data->{stream}->{current} = "irdsa_ps";
                #$request->{stream}->add($api_data->{stream}->{current},$api_data);

                $redis->set( $api_key, $request->encode($api_data) );
                # $redis->persist($key);
                $redis->expire($api_key,"86400");
            }
        }


        my $sql = qq {insert into chat_messages(from_src,from_sid,medium,channel,content_type, content_text,date_arrived,remote_session,api_session) values("agent",'$sid',"SMS",'$tel',"text",'$T->{message}',NOW(),"connet","none")};
        print STDERR $sql."\n";
        my $rep = $dbh->prepare($sql);
        $rep->execute || croak("Could not write to chat table");
        my $id = $dbh->{mysql_insertid};
        $rep->finish;

        my $sql = qq {update chat_messages set remote_session = '$response' where id = "$id"};
     	my $rep = $dbh->prepare($sql);
	    $rep->execute;
	    $rep->finish;


        return {response => $response};
}


sub agent_direct
{
    
}
1;
