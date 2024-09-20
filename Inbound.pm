package Omni::Inbound;
use strict;
use UUID 'uuid';
use Data::Dumper;
use Omni::Stream;
use Affinity::Validate;
use JSON::XS;
use Carp qw(croak);

sub new
{
	my $class = shift;
	my $self = {validate => Affinity::Validate->new()};
	bless $self,$class;
	return $self;
}

sub app
{
	my $self 	= shift;
	my $request = shift;
	my $dbh 	= $request->getdb("omni");
	my $redis   = $request->redis("local");
	my $ts = time();

	croak("Invalid source provided.") unless $request->param("src");
    croak("Invalid policy number provided.") unless $request->param("policy");
    croak("Invalid stream provided.") unless $request->param("stream");
    croak("Invalid session provided.") unless $request->param("session");
	croak("Invalid cellphone number provided.") unless $request->param("cell");


	my ( $src, $policy, $stream, $remote_session,$content, $content_type, $cell, $media ) = (
        $request->param("src"),
        $request->param("policy"),
		$request->param("stream"),
        $request->param("session"),
		$request->param("content"),
		$request->param("content_type"),
		$request->param("cell"),
		$request->param("media"),
    );

	my $api_session = "";

	$redis->select(1);
	if($redis->exists($remote_session)){
		my $session = $request->decode($redis->get($remote_session));
    	$api_session = $session->{api_session};
	}else{
		$api_session = uuid;
		my $app_detail = {
			source => $src,
			cell => $cell,
			policy => $policy,
			api_session => $api_session,
			stream => $stream,
			timestamp => $ts
		};
		$redis->set($remote_session,$request->encode($app_detail));
		$redis->expire($remote_session,"86400");
	}

	# Check if we have an api session if not create one
	$redis->select(2);
	my $api_data;

	if($redis->exists($api_session)){
		$api_data = $request->decode($redis->get($api_session));

		$api_data->{chats}->{$ts} = {
			from => $cell,
			policy => $policy,
			from_src => "client",
			from_sid => "",
			medium => "wellness_app",
			channel => $stream,
			remote_session => $remote_session,
			api_session => $api_session,
			content_type => $content_type,
			content_text => $content,
			content_remote_url => "",
			content_caption => "",
			content_local_url => "",
			content_local_file => "",
			date_arrived => $ts,
			date_seen => "",
			seen_by => "",
			replied => ""
		};

		$redis->set($api_session,$request->encode($api_data));
		$redis->expire($api_session,"86400");
	}else{
		$api_data = {
			ticket => {
				id => "",
				status => "",
				queue => "",
				bucket => "",
				agent => "",
			},
			chats => {
				$ts => {
					from => $cell,
					policy => $policy,
					from_src => "client",
					from_sid => "",
					medium => "wellness_app",
					channel => $stream,
					remote_session => $remote_session,
					api_session => $api_session,
					content_type => $content_type,
					content_text => $content,
					content_remote_url => "",
					content_caption => "",
					content_local_url => "",
					content_local_file => "",
					date_arrived => $ts,
					date_seen => "",
					seen_by => "",
					replied => ""
				}
			},
			stream_data => {},
			info => {
				policy => {},
				lead => {},
			},
			stream => {
				current => $stream,
				next => ""
			},
			authenticated => "0",
			init => "1",
			dc_init => "1",
			menu_init => "1",
			medical_questions_init => "1",
			current_item => "",
			attempts => "",
			token => "",
		};

		$redis->set($api_session,$request->encode($api_data));
		$redis->expire($api_session,"86400");
	}

	my $stream_id = $request->{stream}->add($stream,$api_data);

	# Write the Entry to the database
	my $sql = qq {insert into chat_messages(`from`,`from_src`,`from_sid`,`medium`,`channel`,`remote_session`,`api_session`,
	`content_type`,`content_text`,`content_caption`,`content_remote_url`,`content_local_url`,`content_local_file`,
	`date_arrived`,`stream_name`,`stream_id`) 
	values("$cell", "client", "", "app" , "$stream", "$remote_session", 
	"$api_session", "$content_type", "$content", "", "", "", "" , NOW() , "$stream", "$stream_id") };
	print STDERR $sql."\n";
	my $rep = $dbh->prepare($sql);
	$rep->execute || croak("Could not Add Inbound Whatsapp message to Chats Table");
	my $row_id = $dbh->{mysql_insertid};
	$rep->finish;


    return {"stream_id" => $stream_id};
}

sub pcm
{
	my $self = shift;
	my $request = shift;
}

sub apex
{
	my $self 	= shift;
	my $request = shift;
	print STDERR Dumper($request);
	my $dbh 	= $request->getdb("omni");
	my $redis   = $request->redis("local");
	my $validate = Affinity::Validate->new();	


	print STDERR "New Inbound Whatsapp Message\n";		
	my $data_in = $request->json();
	my $ts = time();
	$data_in->{timestamp} = $ts;
	
	my $wa_session = $data_in->{event}->{sessionUuid};
	my $api_session = "";

	# Get the Whatsapp session from redis
	$redis->select(1);
	#my $session = $request->decode($redis->get($wa_session));

	if($redis->exists($wa_session)){
		####get session info
		print STDERR "Session Found\n";	
		my $session = $request->decode($redis->get($wa_session));
    		$api_session = $session->{api_session};
		
		print STDERR "api sess is $api_session\n";
		#$redis->set($client_tel,$json);
	}else{
		####set new session 
		$api_session = uuid;
		my $wa_detail = {
			channelIdentifier => $data_in->{channelIdentifier},
			channelUuid => $data_in->{channelUuid},
			api_session => $api_session,
			from => $data_in->{event}->{from},
			to => $data_in->{event}->{to},
			timestamp => $ts
		};
		$redis->set($wa_session,$request->encode($wa_detail));
		$redis->expire($wa_session,"86400");
	}

	my $stream_name;

	# Check if we have an api session if not create one
	$redis->select(2);
	my $api_data;

	$api_data = $redis->get($api_session);

	#print STDERR "API DATRA";
	#print STDERR Dumper $api_data;
	my $content;
	my $content_type = $data_in->{event}->{type};
	if($content_type eq "text"){
		$content = $validate->sanitise( $data_in->{event}->{content}->{text} );
	}elsif($content_type eq "reply"){
		$content = $data_in->{event}->{content}->{title};
	}


	if($redis->exists($api_session)){
		####add chat with time to session
		#$api_data = $redis->get($request->decode($api_session));
		$api_data = $request->decode($redis->get($api_session));

		$api_data->{chats}->{$ts} = {
				from => $data_in->{event}->{from},
				from_src => "client",
				from_sid => "",
				medium => "whatsapp",
				channel => $data_in->{event}->{to},
				remote_session => $wa_session,
				api_session => $api_session,
				content_type => $data_in->{event}->{type},
				content_text => $content,
				content_remote_url => $data_in->{event}->{content}->{url},
				content_caption => $data_in->{event}->{content}->{caption},
				content_local_url => "",
				content_local_file => "",
				date_arrived => $ts,
				date_seen => "",
				seen_by => "",
				replied => ""
		};

		$stream_name = $api_data->{stream}->{current};

		$redis->set($api_session,$request->encode($api_data));
		# $redis->persist($api_session);
		$redis->expire($api_session,"86400");
	}else{
		###create chat obj
		# Get the Default Stream
		my $sql = qq {select queue from queues_wa where number = "$data_in->{event}->{to}"};
		print STDERR $sql."\n";
		my $rep = $dbh->prepare($sql);
		$rep->execute || croak("Could not get the Default Stream for WA Inbound");
		($stream_name) = $rep->fetchrow_array();
		$rep->finish;
		
		$stream_name = "wa_manual" unless $stream_name;

		$api_data = {
			ticket => {
				id => "",
				status => "",
				queue => "",
				bucket => "",
				agent => "",
			},
			chats => {
				$ts => {
					from => $data_in->{event}->{from},
					from_src => "client",
					from_sid => "",
					medium => "whatsapp",
					channel => $data_in->{event}->{to},
					remote_session => $wa_session,
					api_session => $api_session,
					content_type => $data_in->{event}->{type},
					content_text => $content,
					content_remote_url => $data_in->{event}->{content}->{url},
					content_caption => $data_in->{event}->{content}->{caption},
					content_local_url => "",
					content_local_file => "",
					date_arrived => $ts,
					date_seen => "",
					seen_by => "",
					replied => ""
				}
			},
			stream_data => {},
			info => {
				policy => {},
				lead => {},
			},
			stream => {
				current => $stream_name,
				next => ""
			},
			authenticated => "0",
			init => "1",
			dc_init => "1",
			menu_init => "1",
			medical_questions_init => "1",
			current_item => "",
			attempts => "",
			token => "",
		};

		$redis->set($api_session,$request->encode($api_data));
		# $redis->persist($api_session);
		$redis->expire($api_session,"86400");
	}

	my $stream_id = $request->{stream}->add($stream_name,$api_data);

	# Write the Entry to the database
	my $sql = qq {insert into chat_messages(`from`,`from_src`,`from_sid`,`medium`,`channel`,`remote_session`,`api_session`,
	`content_type`,`content_text`,`content_caption`,`content_remote_url`,`content_local_url`,`content_local_file`,
	`date_arrived`,`stream_name`,`stream_id`) 
	values("$data_in->{event}->{from}", "client", "", "$data_in->{channelType}" , "$data_in->{event}->{to}", "$wa_session", 
	"$api_session", "$data_in->{event}->{type}", "$content", "$data_in->{event}->{content}->{caption}", "$data_in->{event}->{content}->{url}", "", "" , NOW() , "$stream_name", "$stream_id") };
	print STDERR $sql."\n";
	my $rep = $dbh->prepare($sql);
	$rep->execute || croak("Could not Add Inbound Whatsapp message to Chats Table");
	my $row_id = $dbh->{mysql_insertid};
	$rep->finish;

	my $sql = qq {INSERT INTO `opt_in` (`number`, `whatsapp`) VALUES ('$data_in->{event}->{from}', '1') ON DUPLICATE KEY UPDATE whatsapp = VALUES(whatsapp) };
	my $rep = $dbh->prepare($sql);
 	$rep->execute || croak("Could not update opt_in table");
    $rep->finish;
}

sub wa_version_5000
{
	my $self 	= shift;
	my $request 	= shift;
	print STDERR Dumper $request;

	my $dbh 	= $request->getdb("omni");
	my $redis   	= $request->redis("local");
    	my $uuid    	= uuid();
    	my $coder 	= JSON::XS->new->utf8->allow_nonref->allow_blessed->convert_blessed->pretty;

	my $Resp;

	my ( $src, $from, $to, $message, $api_session, $media, $remote_session,$c_type ) = (
        	$request->param("src"),
        	$request->param("from"),
		$request->param("to"),
        	$request->param("message"),
        	$uuid,
        	$request->param("media"),
		$request->param("session"),
		$request->param("c_type"),
    	);

	croak("To cannot be null.") unless $to;
    	croak("From cannot be null.") unless $from;

	my $sql = qq{select queues.* ,companies.`name` as company_name, `buckets`.`bucket`, `buckets`.`id` as `bucket_id`
			from queues
			left join companies ON companies.id = queues.company
               		left join `buckets` on `buckets`.queue_id = queues.id
			where queues.id in(SELECT `queue_id` FROM `queues_wa` where `number`="$to" );
	};
	my $rep = $dbh->prepare($sql);
	$rep->execute || die "Could not get queue details";
	my($Q) = $rep->fetchrow_hashref();
	$rep->finish();

	croak("Invalid queue.") unless $Q->{id};

	my $sql = qq{INSERT INTO `chat_messages` (`from`, `from_src`, `medium`, `channel`, `remote_session`, `api_session`, `content_type`, `content`, `data`, `date_arrived`) VALUES ("$from", "1", "whatsapp", "", "$remote_session", "$uuid", "text", "", "", NOW() ) };
	my $rep = $dbh->prepare($sql);
    	$rep->execute || die "Could not insert message";
    	my $last = $rep->{mysql_insertid};
    	$rep->finish;


	my $message_data = {
            	"from"       => $from,
            	"message_id" => $last,
		"source" => $src, 
		"sent_to" => $to, 
		"message_data" => $message, 
		"api_session" => $api_session, 
		"media" => $media, 
		"remote_session" => $remote_session,
		"content_type" => $c_type
    	};

    	my $stream_name = $Q->{company_name}."::".$Q->{queue}."::".$Q->{bucket};
    	$Resp->{stream_id} = $request->{stream}->add($stream_name,$message_data);

	return $Resp;
	#return $request->{param};
}

sub telecare_sms
{
	print STDERR "*****************************************************************************************************\n";
        my $self        = shift;
        my $request 	= shift;
	print STDERR Dumper($request);
	my $dbh         = $request->getdb("telehealth");
	my $validate 	= Affinity::Validate->new();
	my $num 	= $request->param("oa");
	my $msg 	= $request->param("ud");
	my $arrived 	= $request->param("timestamp");
	$msg 		= $validate->sanitise($msg);
	my $cell 	= $validate->phone_number($num);

	my $sql = qq{INSERT INTO `sms_in` (`oaFROM`, `udREPLY`, `timestampSENT`) VALUES ("$cell", "$msg", "$arrived")};
	print STDERR $sql."\n";
	my $rep = $dbh->prepare($sql);
        $rep->execute || die "Could not insert telecare inbound sms";
	my $last = $rep->{mysql_insertid};
        $rep->finish;

	my $sql = qq{select `target`,`scope` from sms_out where recipient="$cell" order by id desc limit 1};
        print STDERR $sql."\n";
    	my $rep = $dbh->prepare($sql);
    	$rep->execute || die "could not get policy details";
    	my($target,$scope) = $rep->fetchrow_array();
    	$rep->finish;

	if(defined($target) && defined($scope)){
		my $sql = qq{update `sms_in` set `target`="$target", `scope`="$scope" where id="$last"};
		my $rep = $dbh->prepare($sql);
        	$rep->execute || die "Could not insert telecare inbound sms";
        	$rep->finish;
	}
	print STDERR "************************************************************************************************************\n";

	return {Status => "ok"};
}

sub www
{
	my $self 	= shift;
	my $request = shift;
	print STDERR Dumper($request);


	return{A=>"B"};
}

1;
