package Omni::Apache;
use Apache::DBI;
use Apache::Common;
use Apache2::Const -compile => ':common';
use Affinity::AD;
use JSON::XS;
use Carp qw(croak);
use Data::Dumper;
use Omni::API;
use Omni::Stream;

sub handler
{
    my $r = shift;

    eval {
        die "R is not defined " unless defined $r;
	my $request = Apache::Common->new($r);
	$request->log("Begin new Request");
		
        my $module = $request->module();
	    my $function = $request->function();
        my $method = $request->method();
        my $public_folders = $request->value("DIR_PUBLIC");
        my @public_folders = split(",",$public_folders);
        my $private_folders = $request->value("DIR_PRIVATE");
        my @private_folders = split(",",$private_folders);

        if(!$module){
            $request->send("/index.html");
        }elsif($module eq "index.html"){
            $request->send("/index.html");
        }elsif(grep /$module/,@public_folders){
            $request->sendfile();
        }else{
            
        my $dbh = $request->getdb("omni");
		my $redis = $request->redis("local");
		my $ad = Affinity::AD->new();
        my $omni = Omni::API->new();
        my $session_data ;
		$request->{stream} = Omni::Stream->new($request->value("stream_server"),$request->value("stream_port"),$request->value("stream_password"));


            if($function eq "authenticate"){

                croak("No Username provided.") unless defined $request->param('user');
                croak("No Password provided.") unless defined $request->param('pass');

                my $session_data = $ad->session_create({ username => $request->param('user'), password => $request->param('pass') });
                
                my $session_key = $session->{session_key};
                my $sid = $session->{sid};

                if(defined($session->{error})){
                    croak($session->{error});
                }

                $request->publish($session_data);
                
            #}elsif ( ($module eq "inbound") or ($module eq "admin") or ($module eq "outbound")) {
            }elsif ( ($module eq "inbound")  or ($module eq "outbound")) {
		print STDERR "here\n\n";
                $request->publish($omni->$module->$function($request));
            }
            else{
                my $session_key = $request->cookie('session_key');
                die "ERROR: Session not found [dispatch_request.php]" unless $session_key;
                
                my $session_data = $ad->session_get({session_key => $session_key});
                die "Session Expired Please Login Again" unless $session_data;         

                if(grep /$module/,@private_folders){
                    $request->sendfile();
                }else{
                    $request->publish($omni->$module->$function($request));                
                }
            }
        }
    };
	# Handle any errors
    if($@){
	    my $coder = JSON::XS->new->utf8->allow_nonref->allow_blessed->convert_blessed;
	    my $time = localtime();
	    my $err = $@;
	    print STDERR $time." [".$$."] ERROR: ".$@."\n";
     
        if($err =~ /^Can't locate object method/){
            return Apache2::Const::NOT_FOUND;
        }elsif($err =~ /No such file or directory/){
            return Apache2::Const::NOT_FOUND;
        }else{
	        ($err,undef) = split(" at /",$err) unless($ENV{'DEBUG_Affinity::Common'});
	        $r->content_type('application/json');
	        $r->print($coder->encode({
		        time => $time,
		        status => "error",
		        data => {error => $err}
    	        }));
            }	
    }
    return Apache2::Const::OK;
}
1;
