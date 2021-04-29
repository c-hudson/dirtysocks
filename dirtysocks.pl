#!/usr/bin/perl
#
# dirtysocks.pl 
#    This is a simple http/websocket server for browers to allow
#    people to connect to a Mu* server without a client. When combined
#    with a websocket client like GrapeNut's Websocket client
#    https://github.com/grapenut/websockclient, a user is able to
#    connect without the use of a mud client.
#
#  You May need install Net::WebSockets::Server via:
#
#     perl -MCPAN -e "install Net::WebSocket::Server"
#
use 5.014;
use utf8;
use strict;
use Carp;
use Encode;
use IO::Select;
use IO::Socket;
use IO::Socket::SSL;
use Net::WebSocket::Server;
use Errno qw(EINTR EIO :POSIX);
my ($listener,$websock,$http,%http_data,%sock,%conf,%mapping,%dos,$tmp,%telnet_ch, %state);

my @options = qw(
    BINARY ECHO RCP SGA NAMS STATUS TM RCTE NAOL NAOP NAOCRD NAOHTS NAOHTD
    NAOFFD NAOVTS NAOVTD NAOLFD XASCII LOGOUT BM DET SUPDUP SUPDUPOUTPUT SNDLOC
    TTYPE EOR TUID OUTMRK TTYLOC VT3270REGIME X3PAD NAWS TSPEED LFLOW LINEMODE
    XDISPLOC OLD_ENVIRON AUTHENTICATION ENCRYPT NEW_ENVIRON
);

#---[ http routines ]------------------------------------------------------#

#
# http_init
#    Turn on the listening on the http socket and tell the listener
#    to monitor it.
#
sub http_init
{
   if(@conf{secure}) {
      $http = IO::Socket::SSL->new( LocalPort     => @conf{port},
                                    Listen        => 1,
                                    Reuse         => 1,
                                    SSL_cert_file => "cert.pem",
                                    SSL_key_file  => "key.pem",
                                  )
      or die "https listener error on port " . (@conf{port} + 1) . 
          ": $! <-> $SSL_ERROR";
   } else {
      $http = IO::Socket::INET->new(LocalPort => @conf{port},
                                    Listen    =>1,
                                    Reuse     =>1
                                   )
      or die "http listener error on port " . @conf{port} . ": $!";
   }
   $listener->{select_readable}->add($http);
}

sub http_data_init
{
   my ($end,$pos);
   my ($fn,$src);

   for my $line (<main::DATA>) {
      $line =~ s/\r|\n//g;
      if($line =~ /^START: (.*)\s*$/) {
         ($pos,$end) = ($1,"__$2__");
      } elsif($pos ne undef) {
         s/^   //;
         @http_data{$pos} .= $line . "\n";
      }
   }
}



#
# http_accept
#    Someone is attempting to connect, lets accept it.
#
sub http_accept
{
   my $s = shift;

   my $new = $s->accept();

   $listener->{select_readable}->add($new);               # add to listener

   @sock{$new} = { type => "http",                   # keep track of socket
                   addr => get_hostname($new)
                 };
}

#
# http_io
#   Handle all input/output for http.
#
sub http_io
{
   my ($s,$buf,$page) = @_;

   @sock{$s}->{data} = {} if(!defined @sock{$s}->{data});
   my $data = @sock{$s}->{data};

   if($buf =~ /^GET \/(.*)[\\\/](.*) HTTP\/([\d\.]+)$/i) {       # bad request
      http_error($s,"Page not FOUND.");
   } elsif($buf =~ /^GET \/{0,1}(.*) HTTP\/([\d\.]+)$/i) {       # get request
      $$data{get} = $1;
   } elsif($buf =~ /^([\w\-]+): /) {                 # store request details
      $$data{"VAR_" . lc($1)} = $';
   } elsif($buf eq "") {                                     # end of config
      if(defined @conf{"remote.$$data{get}"}) {
         my $tmp = @http_data{"muddler_client.html"};
         my $port = @conf{port} + 1;
         $tmp =~ s/9001/$port/g;
         $tmp =~ s/WORLD_NAME/$$data{get}/g;
         http_reply($s,"200 Default Request","html",$tmp);
      } elsif(defined $$data{get} && $$data{get} =~ /\.([^\. ]+)$/) {
         http_reply($s,"200 Default Request",$1,@http_data{$$data{get}});
      }  else {
         http_error($s,"Page not found. - $$data{get}");   # file doesn't exist
      }
   } 
}

#
# http_reply
#    A simple reply in in http format.
#
sub http_reply
{
   my ($s,$header,$type,$content) = @_;

   out($s,"HTTP/1.1 200 Default Request");
   out($s,"Date: %s",scalar localtime());
   out($s,"Last-Modified: %s",scalar localtime());
   out($s,"Content-length: %d",length($content));
   out($s,"Connection: close");
   out($s,"Content-Type: text/%s; charset=ISO-8859-1",$type);
   out($s,"");
   out($s,"%s\n",$content);
   server_disconnect($s);
}

#
# http_error
#    Display a simple error message for a web page.
#
sub http_error
{
   my ($s,$fmt,@args) = @_;

   my $code = code("long");
   my $msg = sprintf($fmt,@args);

   http_reply($s,"404 Not Found","html",<<__CONTENT__);
<style>
.big {
   line-height: .7;
   margin-bottom: 0px;
   font-size: 100pt;
   color: hsl(0,100%,30%);
}
div.big2 {
   line-height: .2;
   display:inline-block;
   -webkit-transform:scale(2,1); /* Safari and Chrome */
   -moz-transform:scale(2,1); /* Firefox */
   -ms-transform:scale(2,1); /* IE 9 */
   -o-transform:scale(2,1); /* Opera */
   transform:scale(2,1); /* W3C */
}
</style>
<body>
<br>
<table width=100%>
   <tr>
      <td width=30px>
         <div class="big">404</div><br>
         <center>
            <div class="big2">Page not found</div>
         </center>
      </td>
      <td width=30px>
      </td>
      <td>
         <center><hr size=2>$msg<hr></center>
         <pre>$code</pre>
      </td>
      </td>
      <td width=30px>
      </td>
   </tr>
</table>
</body>
</html>
__CONTENT__
   server_disconnect($s);
}

#
# http_out
#     Send something out to an http socket if its still connected.
#
sub out
{
   my ($s,$fmt,@args) = @_;

   printf($s "$fmt\r\n", @args) if(defined @sock{$s});
}

sub out_noret
{
   my ($s,$fmt,@args) = @_;

   printf($s $fmt, @args);
}




#---[ websocket ]----------------------------------------------------------#

#
# websock_init
#    Start listening on the websocket port and create the listener.
#
sub websock_init
{

   if(@conf{secure}) {
      $websock = IO::Socket::SSL->new(Listen             => 5,
                                  LocalPort          => @conf{port} + 1,
                                  Proto              => 'tcp',
                                  SSL_startHandshake => 0,
                                  SSL_cert_file      => "cert.pem",
                                  SSL_key_file       => "key.pem",
      ) or die "failed to secure websocket listener: $!";
   } else {
      $websock = IO::Socket::INET->new( Listen    => 5,
                                        LocalPort => @conf{port} + 1,
                                        Proto     => 'tcp',
                                        Domain    => AF_INET,
                                        ReuseAddr => 1,
      ) or die "failed to websocket listener: $!";
   }

   $listener= Net::WebSocket::Server->new(          # start websocket server
      listen => $websock,
      tick_period => 1,
      on_connect => 
         sub { my( $serv, $conn ) = @_;
               $conn->on( ready      => sub {  },
                          utf8       => sub { websock_input(@_);     },
                          disconnect => sub { server_disconnect(@_); },
                        );
             },
   );
   $listener->{select_readable}->add($websock);      # listen for connects
   $listener->{conns} = {};
}

#
# websock_io
#    Handle connects and events coming from the web brower.
#
sub websock_io
{
   my $sock = shift;

   if( $sock == $listener->{listen} ) {
      my $sock = $listener->{listen}->accept;
      next unless $sock;

      if(@conf{secure}) {
         IO::Socket::SSL->start_SSL(
             $sock,
             SSL_server    => 1,
             SSL_cert_file => "cert.pem",
             SSL_key_file  =>  "key.pem",
         ) or die "failed to ssl handshake: $SSL_ERROR";
      }

#      printf("[%s] Connect: %s\n",ts(),get_hostname($sock));
      my $conn = new Net::WebSocket::Server::Connection(
                 socket => $sock, server => $listener );

      $listener->{conns}{$sock} = { conn     => $conn,
                                    lastrecv => time,
                                    ip       => get_hostname($sock)
                                  };
      $listener->{select_readable}->add( $sock );
      $listener->{on_connect}($listener, $conn );
      @sock{$conn} = { type => "websock", 
                      other => $sock,
                      host  => get_hostname($sock),
                      ip    => $sock->peerhost
                     };

#      @sock{$sock}  = { type => "websock" };
   } elsif( $listener->{watch_readable}{$sock} ) {
      $listener->{watch_readable}{$sock}{cb}( $listener , $sock );
   } elsif( $listener->{conns}{$sock} ) {
      my $connmeta = $listener->{conns}{$sock};
      $connmeta->{lastrecv} = time;
      $connmeta->{conn}->recv();
   } else {
      warn "filehandle $sock became readable, but no handler took " .
           "responsibility for it; removing it";
      $listener->{select_readable}->remove( $sock );
   }
}

#
# websock_input
#    The user has provided input via the websocket, now send it to the
#    remote server.
#
sub websock_input
{
   my ($conn, $msg, $ssl) = @_;

   $ssl = $ssl ? ",SSL" : "";

   $msg =~ s/\r|\n//g;
   if($msg =~ /^t\/(key_|web_size)/) {
      # ignore, muddler commands..
   } elsif($msg =~ /^t#\-# world ([^ ]+) #\-#$/) {
      telnet_open($conn,$1);
   } elsif($msg =~ /^t/) {       # grapenut messages should all start with 't'
      my $s = @sock{$conn}->{telnet};       # so send it to the telnet socket
      printf($s "%s\r\n",$');
   }

   if(!defined @sock{$conn}->{connected} &&      # log connects with username
      ($msg =~ /^t\s*connect "([^"]+)"/i ||
      $msg =~ /^t\s*connect ([^ ]+)/i)) {
      @sock{$conn}->{connected} = 1;
      
      printf("[%s] Connect %s from %s\n",ts(),
         single($1),@sock{$conn}->{host});
   }
}

#
# err
#    Display an error over the websocket connection since that is where
#    the user is. Any telnet connections can be shutdown.
#
sub err
{
   my (@ws,@s);

   # the sockets must come first
   while(ref($_[0]) eq "Net::WebSocket::Server::Connection" ||
         ref($_[0]) =~ /^IO::Socket::INET=GLOB/) {
      if(ref($_[0]) eq "Net::WebSocket::Server::Connection") {
         push(@ws,shift(@_));
      } else {
         push(@s,shift(@_));
      }
   }
   my ($fmt,@args) = @_;                       # the rest must be the error
   printf("ERR: '$fmt'\n",@args);

   # now that we have the message, we can send it out and disconnect
   for my $i (0 .. $#ws) {
      my $conn = $listener->{conns}{@ws[$i]};
      @ws[$i]->send('','t'.sprintf($fmt,@args));
      printf("%s -> '%s'\n",@ws[$i],sprintf($fmt,@args));
      server_disconnect(@ws[$i]);
  }

   # disconnect any regular sockets
   for my $i (0 .. $#s) {                  # disconnect any regular sockets
      server_disconnect(@s[$i]);
   }
}

#---[ telnet ]-------------------------------------------------------------#

#
# telnet_open
#    Open up a socket to the remote server on the remote port.
#
sub telnet_open
{
   my ($s,$world) = @_;
   my $new;

   if(is_DOS($s)) {                                        # check for DOS
      return err($s,"To many connections attempted by you or everyone");
   }

   if(!defined @sock{$s} ||
      !defined @conf{"remote.$world"}) {
      return err($s,"Previous http call required to specify remote server");
   }

   my $inst = @conf{"remote.$world"};


   if($$inst{type} eq "ssl") {
      $new = IO::Socket::SSL->new( PeerAddr => $$inst{host},
                                   PeerPort => $$inst{port},
                                   Proto => 'tcp',
                                   SSL_use_cert => 0,
                                   SSL_verify_mode => 0,
                                ) ||
         return err($s,"Could not open socket");
   } else {
      $new = IO::Socket::INET->new(Proto=>'tcp',            # create socket
                                      Type => SOCK_STREAM,
                                      blocking=>0,
                                      Timeout => 2) ||
         return err($s,"Could not open socket");

      my $addr = inet_aton($$inst{host}) ||
         return err($s,"Invalid hostname '%s' specified.",$$inst{host});
      my $sockaddr = sockaddr_in($$inst{port}, $addr) ||
         return err($s,"Could not find remote server.");

      connect($new,$sockaddr) or                        # start connect to host
        $! == EWOULDBLOCK or $! == EINPROGRESS or           # and check status
      return err($s,"Could not open connection. $!");
   }

   @sock{$new} = { type        => "telnet",                # hook up socket
                   websock     => $s,
                   pending     => 0,
                   decode      => $$inst{decode},
                   telnet_mode => "normal",
                 };
   @sock{$s}->{telnet} = $new;        # tell websock about telnet connection

#   () = IO::Select->new($new)->can_write(.2)  # see if new socket is pending
#       or @sock{$new}->{pending} = 1;

   if(!defined($new->blocking(1))) {
      return err($s,$new,"Could not open a nonblocking connection");
   }

   if(defined @conf{sconnect_cmd}) {     # send hostname via sconnect_cmd
      printf($new "%s %s\n",@conf{sconnect_cmd},@sock{$s}->{ip});
   }
   $listener->{select_readable}->add($new);
}


#---[ utilities ]---------------------------------------------------------#

#
# is_DOS
#    Determine if there is a DOS attempt going on or not.
#
sub is_DOS {
   my $s= shift;
   my ($all_hits,$user_hits);

   if(defined @conf{DOS_ALL_BANNED}) {           # everyone previous banned
      if(time() - @conf{DOS_ALL_BANNED} < @conf{dos_ban_time}) {
         return 1;                                           # still banned
      } else {
         delete @conf{DOS_ALL_BANNED};                            # expired
      }
   }

   if(defined @conf{DOS_USER_BANNED}) {            # user previously banned
      if(defined @{@conf{DOS_USER_BANNED}}->{@sock{$s}->{ip}}) {
         if(time() - @{@conf{DOS_USER_BANNED}}->{@sock{$s}->{ip}} < 
            @conf{dos_ban_time}) {
            return 1;                                        # still banned
         } else {
            delete @{@conf{DOS_USER_BANNED}}->{@sock{$s}->{ip}}; # expired
         }
      }
   }

   # record the current connection
   @dos{@sock{$s}->{ip}} = {} if not defined @dos{@sock{$s}->{ip}};
   my $hash = @dos{@sock{$s}};
   @$hash{time()} = 1;

   # check all previous connections
   for my $host (keys %dos) {                               # stored by host
      my $hash = @dos{$host};
      for my $tm (keys %{$$hash{$host}}) {                   # by connection
         if(time() - $$hash{$host}->{time} > @conf{DOS_TIME}) { # old, delete
            delete @$hash{$host};
         } else {                                       # new, keep, monitor
            $user_hits++ if($host eq @sock{$s}->{ip});
            $all_hits++;
         }
      }
   }

   if($all_hits > @conf{DOS_ALL_MAX}) {                       # all user ban
      @conf{DOS_ALL_BANNED} = time();
      return 1;
   }
   if($user_hits > @conf{DOS_USER_MAX}) {                  # single user ban
      @conf{DOS_USER_BANNED} = {} if !defined @conf{DOS_USER_BANNED};
      @conf{DOS_USER_BANNED}->{@sock{$s}->{ip}} = time();
      return 1;
   }

   return 0;                                                        # no ban
}


#
# read_config
#    read a config file containing a csv list in alias,host,port format.
#    Any line starting with a '#' will be treaed as a comment.
#
sub read_config
{
   my $fn = shift;
   my $file;

   delete @conf{grep {/remote./} keys %conf}; # delete previous conf entries
   for my $line (get_file($fn,"allow")) {
      if($line =~ /^\s*#/) {
         # comment, ignore
      } elsif($line =~ /^\s*([^ ]+)\s*:\s*/ && $1 ne "telnet" && $1 ne "ssl") {
         @conf{$1} = trim($');
      } elsif($line =~ /^\s*(telnet|ssl)\s*:\s*/) {
         my $type = $1;
         my (@data) = split(',',trim($'));
         @data[3] = "utf8" if(@data[3] ne "utf8" && @data[3] ne "fansi");
         @conf{"remote." . trim(lc(@data[0]))} = {
            type => $type,
            host => @data[1],
            port => @data[2],
            decode => @data[3]
         };
      } else {
         printf("Config Skipped: '%s'\n",$line);
      }
   }
}

#
# trim
#    Remove trailing/leading spaces and returns.
#
sub trim
{
   my $txt = shift;

   $txt =~ s/^\s+|\s+$//g;              # remove any trailing/leading spaces
   $txt =~ s/\r|\n//g;                  # remove any returns
   return $txt;
}

#
# single
#    Convert the input into a single line of text by removing any
#    returns.
#
sub single
{
   my $text = shift;
   $text =~ s/\r|\n//g;
   return $text;
}

#
# get_file
#    Return the requested file as an array of lines. Don't allow any \,/
#    characters to prevent escape out of the current directory.
#
sub get_file
{
   my ($fn,$flag) = @_;
   my (@data,$file);


   if(-e $fn &&
      ($flag eq "allow" ||                              # allow any valid file
       ($fn =~ /^([a-z0-9_\.\-]+)$/i &&            # limit fn valid characters 
        $fn =~ /\.(css|js|html)$/)                 # limit fn valid extensions
      )
     ) {
      open($file,$fn) || return undef;              # open acceptable file

      while(<$file>) {
         $_ =~ s/\r|\n//g;                          # remove extra returns
         push(@data,$_);
      }

      close($file);
      return @data;
   } else {
      return undef;
   }
}

#
# get_hostname 
#    lookup the hostname based upon the ip address
#
sub get_hostname 
{
   my $sock = shift;
   my $ip = $sock->peerhost;                           # contains ip address


   my $name = gethostbyaddr(inet_aton($ip),AF_INET);

   if($name eq undef || $name =~ /in-addr\.arpa$/) {
      return $ip;                            # last resort, return ip address
   } else {
      return $name;                                         # return hostname
   }
}

#
# code
#    Provide a shortened stack dump of the current state of the program.
#    Return only a csv list of line numbers unless 'long' is passed into
#    the code.
#
sub code
{
   my $type = shift;
   my @stack; 
   
   if(!$type || $type eq "short") {
      for my $line (split(/\n/,Carp::shortmess)) {
         if($line =~ / at ([^ ]+) line (\d+)/) { 
            push(@stack,$2);
         }  
      }  
      return join(',',@stack);
   } else {
      return Carp::shortmess;
   }  
}  

#
# print_var
#    print out the contents of a variable, presumably for debuging purposes
#
sub print_var
{
   my ($data,$depth) = @_;
   $depth = 0 if $depth eq undef;

   printf("---- [ start ]----\n") if $depth == 0;
   if(ref($data) eq "HASH") {
      printf("%sHASH {\n"," " x ($depth*3));
      for my $key (keys %$data) {
         if(ref($$data{$key}) =~ /^(ARRAY|HASH)$/) {
            print_var($$data{$key},$depth+1);
         } else {
            printf("%s%s -> '%s'\n"," " x (($depth+1) * 3),$key,$$data{$key});
         }
      }
      printf("%s}\n"," " x ($depth*3));
   } elsif(ref($data) eq "ARRAY") {
      printf("%sARRAY [\n"," " x ($depth*3));
      for my $i (0 .. $#$data) {
         if(ref($$data[$i]) =~ /^(ARRAY|HASH)$/) {
            print_var($$data[$i],$depth+1);
         } else {
            printf("%s%s -> '%s'\n"," " x (($depth+1) * 3),$i,$$data[$i]);
         }
      }
      printf("%s]\n"," " x ($depth*3));
   } else {
      printf("%sSTRING: '%s'\n"," " x ($depth * 3),$data);
   }
   printf("---- [  end  ]----\n") if $depth == 0;
}

#
# ts
#    Simple timestamp function
#
sub ts
{
   my $time = shift;

   $time = time() if $time eq undef;
   my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
                                                localtime($time);
   $mon++;

   return sprintf("%02d:%02d@%02d/%02d",$hour,$min,$mon,$mday);
}


#
# verify_config
#    Verify that the entries in the config file look roughly correct.
#
sub verify_config
{
   my $count = 0;

   for my $key ("port",
               "dos_all_max",
               "dos_user_max",
               "dos_time") {
      if(!defined @conf{$key}) {
         die("Fatal: $key not defined in websock.conf");
      }
   }
   for my $key (grep {/^remote\./} keys %conf) {
      $count++;
   }

   die("Fatal: No remote servers defined in websock.conf") if $count == 0;
}


#---[ main ]--------------------------------------------------------------#

#
# server_disconnect
#    A socket has disconnected or needs to be disconnected. This could
#    be a telnet socket or a websocket connection. Each are tied together
#    and will require handling of its parent / child connection.
#
sub server_disconnect
{
   my $s = shift;
   my $secondary;

   return if(!defined @sock{$s});

   if(ref($s) eq "IO::Socket::INET") {                        # telnet socket
      $s->close();
      $listener->{select_readable}->remove($s);           # close first socket

      if(defined @sock{$s}->{websock}) {          # close associated websocket
         $secondary = @sock{$s}->{websock};
         $secondary->disconnect();
         delete @sock{$secondary};
      }
      delete @sock{$s};
   } else {                                     # websocket connection closed
      if(defined @sock{$s}->{telnet}) {  # close associated telnet connection
         @sock{$s}->{telnet}->close();
         $listener->{select_readable}->remove(@sock{$s}->{telnet});
         delete @sock{@sock{$s}->{telnet}};
      }
      delete @sock{$s};                         # just clean up, don't close
   }
}

sub telnet_ch_init
{
   delete @telnet_ch{keys %telnet_ch};

   @state{IAC} = chr(255);
   @state{SB} = chr(250);
   @state{SE} = chr(240);
   @state{255} = 'IAC';
   @state{250} = 'SB';
   @state{240} = 'SE';
   @state{241} = 'NOP';

   @state{WILL} = chr(251);
   @state{WONT} = chr(252);
   @state{DO}   = chr(253);
   @state{DONT} = chr(254);
   @state{251} = 'WILL';
   @state{252} = 'WONT';
   @state{253} = 'DO';
   @state{254} = 'DONT';

   @telnet_ch{normal} =
      sub {
         my ($s,$ch) = @_;

         if($ch eq @state{IAC}) {
            return (undef, @state{IAC});
         } else {
            return $ch;
         }
      };

   @telnet_ch{@state{IAC}} =
      sub {
         my ($s,$ch) = @_;

         if($ch eq @state{IAC}) {
            return (@state{IAC}, 'normal');
         } elsif(is_in($ch,@state{DO},@state{DONT},@state{WILL},@state{WONT},
                 @state{SB})) {
            return (undef,$ch);
         } elsif($ch eq @state{NOP}) {                       # keep-a-live?
            return (undef, 'normal');
         } else {
            return (undef, 'normal');
         }
      };

   @telnet_ch{@state{DO}} =
      sub {
         my ($s,$opt, $mode) = @_;

#         loggit("telnet[$world]: %s %s",(@state{ord($mode)} || ord($mode)),
#             ($options[ord($opt)] || ord($opt)));
         my $wopt = $options[ord($opt)] || ord($opt);
         if(is_enabled((@state{ord($mode)} || ord($mode)) . "_" .
             ($options[ord($opt)] || ord($opt)))) {
            if ($mode eq @state{DO})   {
#                loggit("telnet_send: IAC WILL $wopt");
                out_noret($s,@state{IAC}.@state{WILL}.$opt);
            } elsif ($mode eq @state{DONT}) {
#                loggit("telnet_send: IAC WONT $wopt");
                out_noret($s,@state{IAC}.@state{WONT}.$opt);
            } elsif ($mode eq @state{WONT}) {
#                loggit("telnet_send: IAC DONT $wopt");
                out_noret($s,@state{IAC}.@state{DONT}.$opt);
            } elsif ($mode eq @state{WILL}) {
#                loggit("telnet_send: IAC DO $wopt");
                out_noret($s,@state{IAC}.@state{DO}  .$opt);
            }
         } else {
            if ($mode eq @state{DONT}) {
#                loggit("telnet_send: IAC WILL $wopt");
               out_noret($s,@state{IAC}.@state{WILL}.$opt);
            } elsif ($mode eq @state{DO}) {
#                loggit("telnet_send: IAC WONT $wopt");
               out_noret($s,@state{IAC}.@state{WONT}.$opt);
            } elsif ($mode eq @state{WILL}) {
#                loggit("telnet_send: IAC WILL $wopt");
               out_noret($s,@state{IAC}.@state{DONT}.$opt);
            } elsif ($mode eq @state{WONT}) {
#                loggit("telnet_send: IAC WONT $wopt");
               out_noret($s,@state{IAC}.@state{DO}  .$opt);
            }
         }
         return (undef, 'normal');
      };

   @telnet_ch{@state{SB}} =
      sub {
         my ($s,$c) = @_;
         return (undef, 'sbiac') if $c eq @state{IAC};
         @state{telnet_sb_buffer} .= $c;
         return;
       };

  @telnet_ch{@state{SB}} =
      sub {
         my ($s,$c) = @_;
         return (undef, 'sbiac') if $c eq @state{IAC};
         @state{telnet_sb_buffer} .= $c;
         return;
       };

   @telnet_ch{sbiac} =
       sub {
          my ($s,$c) = @_;

          if ($c eq @state{IAC}) {
              @state{telnet_sb_buffer} .= @state{IAC};
              return (undef, @state{SB});
          }

          if ($c eq @state{SE}) {
              _telnet_complex_callback(@state{telnet_sb_buffer});
              @state{telnet_sb_buffer} = '';
              return (undef, 'normal');
          }

          # IAC followed by something other than IAC and SE.. what??
          require Carp;
          Carp::croak "Invalid telnet stream: IAC SE ... IAC $c (chr ".chr($c).") ...";
      };
   $telnet_ch{@state{DONT}} =
       $telnet_ch{@state{WILL}} =
       $telnet_ch{@state{WONT}} =
       $telnet_ch{@state{DO}};
}


sub _parse
{
    my ($s,$in) = @_;
    my $out = '';

    # optimization: if we're in normal mode then we can quickly move all the
    # input up to the first IAC into the output buffer.
    if (@sock{$s}->{telnet_mode} eq 'normal') {
        # if there is no IAC then we can skip telnet entirely
        $in =~ s/^([^@state{IAC}]*)//o;
        return $1 if length $in == 0;
        $out = $1;
    }


    for my $c (split '', $in) {
        my ($o, $m) = $telnet_ch{@sock{$s}->{telnet_mode}}->
            ($s,$c, @sock{$s}->{telnet_mode});

        $out .= $o;
#        defined $o and $out .= $o;
        defined $m and @sock{$s}->{telnet_mode} = $m;
    }

    return $out;
}



#
# server_io
#    Handle any input/output coming into the server.
#
sub server_io
{
   my ($line,$buf);

   my ($sockets)=IO::Select->select($listener->{select_readable},undef,undef,1);

   foreach my $s (@$sockets) {
      if($s eq $http) {
         http_accept($s);
      } elsif($s == $websock || defined $listener->{conns}{$s}) {
         websock_io($s);
      } elsif(sysread($s,$buf,1024) <= 0) {
         server_disconnect($s);
      } else {
         @sock{$s}->{buf} .= $buf;

         while(defined @sock{$s} && @sock{$s}->{buf} =~ /\n/) {
            ($line,@sock{$s}->{buf}) = ($`,$');
            if(@sock{$s}->{type} eq "http") {
               $line =~ s/\r|\n//g;
               http_io($s,$line);
            } elsif(@sock{$s}->{type} eq "telnet") {
                @sock{$s}->{websock}->send(
                    '',
                    "t" . 
                    encode_utf8(decode(@sock{$s}->{decode},
                                _parse($s,$line))
                               )
                    );
            }
         }
      }
   }
}

sub is_enabled
{
    my $opt = shift;

    if(is_in($opt,"DO_SGA","DO_TTYPE","DO_NAWS","DO_ECHO","DONT_MXP",
             "DONT_MSP","WONT_MXP","WONT_MSP","WILL_SGA","WILL_TTYPE",
             "WILL_NAWS","WILL_ECHO")) {
       return 0;
    } else {
       return 0;
    }
}

sub is_in
{
   my ($txt,@list) = @_;

   for my $i (0 .. $#list) {
      return 1 if($txt eq @list[$i]);
   }
   return 0;
}


$SIG{HUP} = sub {                         # re-read config on HUP signal
   read_config("dirtysocks.conf");
};

read_config("dirtysocks.conf");
verify_config();

printf("# Remote Servers:\n");
for my $key (grep {/^remote\./} keys %conf) {
   printf("#    %-15s %s:%d\n",substr($key,7),@conf{$key}->{host},
      @conf{$key}->{port});
}


websock_init();
http_init();
http_data_init();
telnet_ch_init();

printf("# Listening: HTTP%s(%d), %sWEBSOCK(%d)\n",
       @conf{secure} ? "S" : "",
       @conf{port},
       @conf{secure} ? "SECURE " : "",
       @conf{port}+1
      );

while(1) {
#   eval {
      server_io();
#   };
}

__DATA__
START: muddler_ansi.css
   /* underlined text */
   .ansi-4 { text-decoration: underline; }
   
   /* blinking text */
   .ansi-5 {
       -webkit-animation: blink .75s linear infinite;
       -moz-animation: blink .75s linear infinite;
       -ms-animation: blink .75s linear infinite;
       -o-animation: blink .75s linear infinite;
       animation: blink .75s linear infinite;
   }

   /* standard 16 foreground colors */
   .ansi-30 { color: black; }
   .ansi-1-30 { color: gray; }
   .ansi-31 { color: maroon; }
   .ansi-1-31 { color: red; }
   .ansi-32 { color: green; }
   .ansi-1-32 { color: lime; }
   .ansi-33 { color: olive; }
   .ansi-1-33 { color: yellow; }
   .ansi-34 { color: navy; }
   .ansi-1-34 { color: blue; }
   .ansi-35 { color: purple; }
   .ansi-1-35 { color: fuchsia; }
   .ansi-36 { color: teal; }
   .ansi-1-36 { color: aqua; }
   .ansi-37 { color: black; }
   .ansi-1-37 { color: black; } 


   /* standard 16 background colors */
   .ansi-40 { background-color: black; }
   .ansi-1-40 { background-color: gray; }
   .ansi-41 { background-color: maroon; }
   .ansi-1-41 { background-color: red; }
   .ansi-42 { background-color: green; }
   .ansi-1-42 { background-color: lime; }
   .ansi-43 { background-color: olive; }
   .ansi-1-43 { background-color: yellow; }
   .ansi-44 { background-color: navy; }
   .ansi-1-44 { background-color: blue; }
   .ansi-45 { background-color: purple; }
   .ansi-1-45 { background-color: fuchsia; }
   .ansi-46 { background-color: teal; }
   .ansi-1-46 { background-color: aqua; }
   .ansi-47 { background-color: silver; }
   .ansi-1-47 { background-color: white; }
   
   .ansi-38-5-0     { color:            #000000; }
   .ansi-38-5-1     { color:            #cd0000; }
   .ansi-38-5-2     { color:            #00cd00; }
   .ansi-38-5-3     { color:            #cdcd00; }
   .ansi-38-5-4     { color:            #0000ee; }
   .ansi-38-5-5     { color:            #cd00cd; }
   .ansi-38-5-6     { color:            #00cdcd; }
   .ansi-38-5-7     { color:            #e5e5e5; }
   .ansi-38-5-8     { color:            #7f7f7f; }
   .ansi-38-5-9     { color:            #ff0000; }
   .ansi-38-5-10    { color:            #00ff00; }
   .ansi-38-5-11    { color:            #e8e800; }
   .ansi-38-5-12    { color:            #5c5cff; }
   .ansi-38-5-13    { color:            #ff00ff; }
   .ansi-38-5-14    { color:            #00ffff; }
   .ansi-38-5-15    { color:            #ffffff; }
   
   /* XTERM colors - 256 color mode */
   .ansi-38-5-16    { color:            #000000; }
   .ansi-38-5-17    { color:            #00005f; }
   .ansi-38-5-18    { color:            #000087; }
   .ansi-38-5-19    { color:            #0000af; }
   .ansi-38-5-20    { color:            #0000d7; }
   .ansi-38-5-21    { color:            #0000ff; }
   .ansi-38-5-22    { color:            #005f00; }
   .ansi-38-5-23    { color:            #005f5f; }
   .ansi-38-5-24    { color:            #005f87; }
   .ansi-38-5-25    { color:            #005faf; }
   .ansi-38-5-26    { color:            #005fd7; }
   .ansi-38-5-27    { color:            #005fff; }
   .ansi-38-5-28    { color:            #008700; }
   .ansi-38-5-29    { color:            #00875f; }
   .ansi-38-5-30    { color:            #008787; }
   .ansi-38-5-31    { color:            #0087af; }
   .ansi-38-5-32    { color:            #0087d7; }
   .ansi-38-5-33    { color:            #0087ff; }
   .ansi-38-5-34    { color:            #00af00; }
   .ansi-38-5-35    { color:            #00af5f; }
   .ansi-38-5-36    { color:            #00af87; }
   .ansi-38-5-37    { color:            #00afaf; }
   .ansi-38-5-38    { color:            #00afd7; }
   .ansi-38-5-39    { color:            #00afff; }
   .ansi-38-5-40    { color:            #00d700; }
   .ansi-38-5-41    { color:            #00d75f; }
   .ansi-38-5-42    { color:            #00d787; }
   .ansi-38-5-43    { color:            #00d7af; }
   .ansi-38-5-44    { color:            #00d7d7; }
   .ansi-38-5-45    { color:            #00d7ff; }
   .ansi-38-5-46    { color:            #00ff00; }
   .ansi-38-5-47    { color:            #00ff5f; }
   .ansi-38-5-48    { color:            #00ff87; }
   .ansi-38-5-49    { color:            #00ffaf; }
   .ansi-38-5-50    { color:            #00ffd7; }
   .ansi-38-5-51    { color:            #00ffff; }
   .ansi-38-5-52    { color:            #5f0000; }
   .ansi-38-5-53    { color:            #5f005f; }
   .ansi-38-5-54    { color:            #5f0087; }
   .ansi-38-5-55    { color:            #5f00af; }
   .ansi-38-5-56    { color:            #5f00d7; }
   .ansi-38-5-57    { color:            #5f00ff; }
   .ansi-38-5-58    { color:            #5f5f00; }
   .ansi-38-5-59    { color:            #5f5f5f; }
   .ansi-38-5-60    { color:            #5f5f87; }
   .ansi-38-5-61    { color:            #5f5faf; }
   .ansi-38-5-62    { color:            #5f5fd7; }
   .ansi-38-5-63    { color:            #5f5fff; }
   .ansi-38-5-64    { color:            #5f8700; }
   .ansi-38-5-65    { color:            #5f875f; }
   .ansi-38-5-66    { color:            #5f8787; }
   .ansi-38-5-67    { color:            #5f87af; }
   .ansi-38-5-68    { color:            #5f87d7; }
   .ansi-38-5-69    { color:            #5f87ff; }
   .ansi-38-5-70    { color:            #5faf00; }
   .ansi-38-5-71    { color:            #5faf5f; }
   .ansi-38-5-72    { color:            #5faf87; }
   .ansi-38-5-73    { color:            #5fafaf; }
   .ansi-38-5-74    { color:            #5fafd7; }
   .ansi-38-5-75    { color:            #5fafff; }
   .ansi-38-5-76    { color:            #5fd700; }
   .ansi-38-5-77    { color:            #5fd75f; }
   .ansi-38-5-78    { color:            #5fd787; }
   .ansi-38-5-79    { color:            #5fd7af; }
   .ansi-38-5-80    { color:            #5fd7d7; }
   .ansi-38-5-81    { color:            #5fd7ff; }
   .ansi-38-5-82    { color:            #5fff00; }
   .ansi-38-5-83    { color:            #5fff5f; }
   .ansi-38-5-84    { color:            #5fff87; }
   .ansi-38-5-85    { color:            #5fffaf; }
   .ansi-38-5-86    { color:            #5fffd7; }
   .ansi-38-5-87    { color:            #5fffff; }
   .ansi-38-5-88    { color:            #870000; }
   .ansi-38-5-89    { color:            #87005f; }
   .ansi-38-5-90    { color:            #870087; }
   .ansi-38-5-91    { color:            #8700af; }
   .ansi-38-5-92    { color:            #8700d7; }
   .ansi-38-5-93    { color:            #8700ff; }
   .ansi-38-5-94    { color:            #875f00; }
   .ansi-38-5-95    { color:            #875f5f; }
   .ansi-38-5-96    { color:            #875f87; }
   .ansi-38-5-97    { color:            #875faf; }
   .ansi-38-5-98    { color:            #875fd7; }
   .ansi-38-5-99    { color:            #875fff; }
   .ansi-38-5-100   { color:            #878700; }
   .ansi-38-5-101   { color:            #87875f; }
   .ansi-38-5-102   { color:            #878787; }
   .ansi-38-5-103   { color:            #8787af; }
   .ansi-38-5-104   { color:            #8787d7; }
   .ansi-38-5-105   { color:            #8787ff; }
   .ansi-38-5-106   { color:            #87af00; }
   .ansi-38-5-107   { color:            #87af5f; }
   .ansi-38-5-108   { color:            #87af87; }
   .ansi-38-5-109   { color:            #87afaf; }
   .ansi-38-5-110   { color:            #87afd7; }
   .ansi-38-5-111   { color:            #87afff; }
   .ansi-38-5-112   { color:            #87d700; }
   .ansi-38-5-113   { color:            #87d75f; }
   .ansi-38-5-114   { color:            #87d787; }
   .ansi-38-5-115   { color:            #87d7af; }
   .ansi-38-5-116   { color:            #87d7d7; }
   .ansi-38-5-117   { color:            #87d7ff; }
   .ansi-38-5-118   { color:            #87ff00; }
   .ansi-38-5-119   { color:            #87ff5f; }
   .ansi-38-5-120   { color:            #87ff87; }
   .ansi-38-5-121   { color:            #87ffaf; }
   .ansi-38-5-122   { color:            #87ffd7; }
   .ansi-38-5-123   { color:            #87ffff; }
   .ansi-38-5-124   { color:            #af0000; }
   .ansi-38-5-125   { color:            #af005f; }
   .ansi-38-5-126   { color:            #af0087; }
   .ansi-38-5-127   { color:            #af00af; }
   .ansi-38-5-128   { color:            #af00d7; }
   .ansi-38-5-129   { color:            #af00ff; }
   .ansi-38-5-130   { color:            #af5f00; }
   .ansi-38-5-131   { color:            #af5f5f; }
   .ansi-38-5-132   { color:            #af5f87; }
   .ansi-38-5-133   { color:            #af5faf; }
   .ansi-38-5-134   { color:            #af5fd7; }
   .ansi-38-5-135   { color:            #af5fff; }
   .ansi-38-5-136   { color:            #af8700; }
   .ansi-38-5-137   { color:            #af875f; }
   .ansi-38-5-138   { color:            #af8787; }
   .ansi-38-5-139   { color:            #af87af; }
   .ansi-38-5-140   { color:            #af87d7; }
   .ansi-38-5-141   { color:            #af87ff; }
   .ansi-38-5-142   { color:            #afaf00; }
   .ansi-38-5-143   { color:            #afaf5f; }
   .ansi-38-5-144   { color:            #afaf87; }
   .ansi-38-5-145   { color:            #afafaf; }
   .ansi-38-5-146   { color:            #afafd7; }
   .ansi-38-5-147   { color:            #afafff; }
   .ansi-38-5-148   { color:            #afd700; }
   .ansi-38-5-149   { color:            #afd75f; }
   .ansi-38-5-150   { color:            #afd787; }
   .ansi-38-5-151   { color:            #afd7af; }
   .ansi-38-5-152   { color:            #afd7d7; }
   .ansi-38-5-153   { color:            #afd7ff; }
   .ansi-38-5-154   { color:            #afff00; }
   .ansi-38-5-155   { color:            #afff5f; }
   .ansi-38-5-156   { color:            #afff87; }
   .ansi-38-5-157   { color:            #afffaf; }
   .ansi-38-5-158   { color:            #afffd7; }
   .ansi-38-5-159   { color:            #afffff; }
   .ansi-38-5-160   { color:            #d70000; }
   .ansi-38-5-161   { color:            #d7005f; }
   .ansi-38-5-162   { color:            #d70087; }
   .ansi-38-5-163   { color:            #d700af; }
   .ansi-38-5-164   { color:            #d700d7; }
   .ansi-38-5-165   { color:            #d700ff; }
   .ansi-38-5-166   { color:            #d75f00; }
   .ansi-38-5-167   { color:            #d75f5f; }
   .ansi-38-5-168   { color:            #d75f87; }
   .ansi-38-5-169   { color:            #d75faf; }
   .ansi-38-5-170   { color:            #d75fd7; }
   .ansi-38-5-171   { color:            #d75fff; }
   .ansi-38-5-172   { color:            #d78700; }
   .ansi-38-5-173   { color:            #d7875f; }
   .ansi-38-5-174   { color:            #d78787; }
   .ansi-38-5-175   { color:            #d787af; }
   .ansi-38-5-176   { color:            #d787d7; }
   .ansi-38-5-177   { color:            #d787ff; }
   .ansi-38-5-178   { color:            #d7af00; }
   .ansi-38-5-179   { color:            #d7af5f; }
   .ansi-38-5-180   { color:            #d7af87; }
   .ansi-38-5-181   { color:            #d7afaf; }
   .ansi-38-5-182   { color:            #d7afd7; }
   .ansi-38-5-183   { color:            #d7afff; }
   .ansi-38-5-184   { color:            #d7d700; }
   .ansi-38-5-185   { color:            #d7d75f; }
   .ansi-38-5-186   { color:            #d7d787; }
   .ansi-38-5-187   { color:            #d7d7af; }
   .ansi-38-5-188   { color:            #d7d7d7; }
   .ansi-38-5-189   { color:            #d7d7ff; }
   .ansi-38-5-190   { color:            #d7ff00; }
   .ansi-38-5-191   { color:            #d7ff5f; }
   .ansi-38-5-192   { color:            #d7ff87; }
   .ansi-38-5-193   { color:            #d7ffaf; }
   .ansi-38-5-194   { color:            #d7ffd7; }
   .ansi-38-5-195   { color:            #d7ffff; }
   .ansi-38-5-196   { color:            #ff0000; }
   .ansi-38-5-197   { color:            #ff005f; }
   .ansi-38-5-198   { color:            #ff0087; }
   .ansi-38-5-199   { color:            #ff00af; }
   .ansi-38-5-200   { color:            #ff00d7; }
   .ansi-38-5-201   { color:            #ff00ff; }
   .ansi-38-5-202   { color:            #ff5f00; }
   .ansi-38-5-203   { color:            #ff5f5f; }
   .ansi-38-5-204   { color:            #ff5f87; }
   .ansi-38-5-205   { color:            #ff5faf; }
   .ansi-38-5-206   { color:            #ff5fd7; }
   .ansi-38-5-207   { color:            #ff5fff; }
   .ansi-38-5-208   { color:            #ff8700; }
   .ansi-38-5-209   { color:            #ff875f; }
   .ansi-38-5-210   { color:            #ff8787; }
   .ansi-38-5-211   { color:            #ff87af; }
   .ansi-38-5-212   { color:            #ff87d7; }
   .ansi-38-5-213   { color:            #ff87ff; }
   .ansi-38-5-214   { color:            #ffaf00; }
   .ansi-38-5-215   { color:            #ffaf5f; }
   .ansi-38-5-216   { color:            #ffaf87; }
   .ansi-38-5-217   { color:            #ffafaf; }
   .ansi-38-5-218   { color:            #ffafd7; }
   .ansi-38-5-219   { color:            #ffafff; }
   .ansi-38-5-220   { color:            #ffd700; }
   .ansi-38-5-221   { color:            #ffd75f; }
   .ansi-38-5-222   { color:            #ffd787; }
   .ansi-38-5-223   { color:            #ffd7af; }
   .ansi-38-5-224   { color:            #ffd7d7; }
   .ansi-38-5-225   { color:            #ffd7ff; }
   .ansi-38-5-226   { color:            #ffff00; }
   .ansi-38-5-227   { color:            #ffff5f; }
   .ansi-38-5-228   { color:            #ffff87; }
   .ansi-38-5-229   { color:            #ffffaf; }
   .ansi-38-5-230   { color:            #ffffd7; }
   .ansi-38-5-231   { color:            #ffffff; }
   .ansi-38-5-232   { color:            #080808; }
   .ansi-38-5-233   { color:            #121212; }
   .ansi-38-5-234   { color:            #1c1c1c; }
   .ansi-38-5-235   { color:            #262626; }
   .ansi-38-5-236   { color:            #303030; }
   .ansi-38-5-237   { color:            #3a3a3a; }
   .ansi-38-5-238   { color:            #444444; }
   .ansi-38-5-239   { color:            #4e4e4e; }
   .ansi-38-5-240   { color:            #585858; }
   .ansi-38-5-241   { color:            #626262; }
   .ansi-38-5-242   { color:            #6c6c6c; }
   .ansi-38-5-243   { color:            #767676; }
   .ansi-38-5-244   { color:            #808080; }
   .ansi-38-5-245   { color:            #8a8a8a; }
   .ansi-38-5-246   { color:            #949494; }
   .ansi-38-5-247   { color:            #9e9e9e; }
   .ansi-38-5-248   { color:            #a8a8a8; }
   .ansi-38-5-249   { color:            #b2b2b2; }
   .ansi-38-5-250   { color:            #bcbcbc; }
   .ansi-38-5-251   { color:            #c6c6c6; }
   .ansi-38-5-252   { color:            #d0d0d0; }
   .ansi-38-5-253   { color:            #dadada; }
   .ansi-38-5-254   { color:            #e4e4e4; }
   .ansi-38-5-255   { color:            #eeeeee; }
   
   /* SYSTEM colors */
   
   .ansi-48-5-0   { background-color: #000000; }
   .ansi-48-5-1   { background-color: #cd0000; }
   .ansi-48-5-2   { background-color: #00cd00; }
   .ansi-48-5-3   { background-color: #cdcd00; }
   .ansi-48-5-4   { background-color: #0000ee; }
   .ansi-48-5-5   { background-color: #cd00cd; }
   .ansi-48-5-6   { background-color: #00cdcd; }
   .ansi-48-5-7   { background-color: #e5e5e5; }
   .ansi-48-5-8   { background-color: #7f7f7f; }
   .ansi-48-5-9   { background-color: #ff0000; }
   .ansi-48-5-10  { background-color: #00ff00; }
   .ansi-48-5-11  { background-color: #e8e800; }
   .ansi-48-5-12  { background-color: #5c5cff; }
   .ansi-48-5-13  { background-color: #ff00ff; }
   .ansi-48-5-14  { background-color: #00ffff; }
   .ansi-48-5-15  { background-color: #ffffff; }
   
   /* XTERM colors - 256 color mode */
   .ansi-48-5-16  { background-color: #000000; }
   .ansi-48-5-17  { background-color: #00005f; }
   .ansi-48-5-18  { background-color: #000087; }
   .ansi-48-5-19  { background-color: #0000af; }
   .ansi-48-5-20  { background-color: #0000d7; }
   .ansi-48-5-21  { background-color: #0000ff; }
   .ansi-48-5-22  { background-color: #005f00; }
   .ansi-48-5-23  { background-color: #005f5f; }
   .ansi-48-5-24  { background-color: #005f87; }
   .ansi-48-5-25  { background-color: #005faf; }
   .ansi-48-5-26  { background-color: #005fd7; }
   .ansi-48-5-27  { background-color: #005fff; }
   .ansi-48-5-28  { background-color: #008700; }
   .ansi-48-5-29  { background-color: #00875f; }
   .ansi-48-5-30  { background-color: #008787; }
   .ansi-48-5-31  { background-color: #0087af; }
   .ansi-48-5-32  { background-color: #0087d7; }
   .ansi-48-5-33  { background-color: #0087ff; }
   .ansi-48-5-34  { background-color: #00af00; }
   .ansi-48-5-35  { background-color: #00af5f; }
   .ansi-48-5-36  { background-color: #00af87; }
   .ansi-48-5-37  { background-color: #00afaf; }
   .ansi-48-5-38  { background-color: #00afd7; }
   .ansi-48-5-39  { background-color: #00afff; }
   .ansi-48-5-40  { background-color: #00d700; }
   .ansi-48-5-41  { background-color: #00d75f; }
   .ansi-48-5-42  { background-color: #00d787; }
   .ansi-48-5-43  { background-color: #00d7af; }
   .ansi-48-5-44  { background-color: #00d7d7; }
   .ansi-48-5-45  { background-color: #00d7ff; }
   .ansi-48-5-46  { background-color: #00ff00; }
   .ansi-48-5-47  { background-color: #00ff5f; }
   .ansi-48-5-48  { background-color: #00ff87; }
   .ansi-48-5-49  { background-color: #00ffaf; }
   .ansi-48-5-50  { background-color: #00ffd7; }
   .ansi-48-5-51  { background-color: #00ffff; }
   .ansi-48-5-52  { background-color: #5f0000; }
   .ansi-48-5-53  { background-color: #5f005f; }
   .ansi-48-5-54  { background-color: #5f0087; }
   .ansi-48-5-55  { background-color: #5f00af; }
   .ansi-48-5-56  { background-color: #5f00d7; }
   .ansi-48-5-57  { background-color: #5f00ff; }
   .ansi-48-5-58  { background-color: #5f5f00; }
   .ansi-48-5-59  { background-color: #5f5f5f; }
   .ansi-48-5-60  { background-color: #5f5f87; }
   .ansi-48-5-61  { background-color: #5f5faf; }
   .ansi-48-5-62  { background-color: #5f5fd7; }
   .ansi-48-5-63  { background-color: #5f5fff; }
   .ansi-48-5-64  { background-color: #5f8700; }
   .ansi-48-5-65  { background-color: #5f875f; }
   .ansi-48-5-66  { background-color: #5f8787; }
   .ansi-48-5-67  { background-color: #5f87af; }
   .ansi-48-5-68  { background-color: #5f87d7; }
   .ansi-48-5-69  { background-color: #5f87ff; }
   .ansi-48-5-70  { background-color: #5faf00; }
   .ansi-48-5-71  { background-color: #5faf5f; }
   .ansi-48-5-72  { background-color: #5faf87; }
   .ansi-48-5-73  { background-color: #5fafaf; }
   .ansi-48-5-74  { background-color: #5fafd7; }
   .ansi-48-5-75  { background-color: #5fafff; }
   .ansi-48-5-76  { background-color: #5fd700; }
   .ansi-48-5-77  { background-color: #5fd75f; }
   .ansi-48-5-78  { background-color: #5fd787; }
   .ansi-48-5-79  { background-color: #5fd7af; }
   .ansi-48-5-80  { background-color: #5fd7d7; }
   .ansi-48-5-81  { background-color: #5fd7ff; }
   .ansi-48-5-82  { background-color: #5fff00; }
   .ansi-48-5-83  { background-color: #5fff5f; }
   .ansi-48-5-84  { background-color: #5fff87; }
   .ansi-48-5-85  { background-color: #5fffaf; }
   .ansi-48-5-86  { background-color: #5fffd7; }
   .ansi-48-5-87  { background-color: #5fffff; }
   .ansi-48-5-88  { background-color: #870000; }
   .ansi-48-5-89  { background-color: #87005f; }
   .ansi-48-5-90  { background-color: #870087; }
   .ansi-48-5-91  { background-color: #8700af; }
   .ansi-48-5-92  { background-color: #8700d7; }
   .ansi-48-5-93  { background-color: #8700ff; }
   .ansi-48-5-94  { background-color: #875f00; }
   .ansi-48-5-95  { background-color: #875f5f; }
   .ansi-48-5-96  { background-color: #875f87; }
   .ansi-48-5-97  { background-color: #875faf; }
   .ansi-48-5-98  { background-color: #875fd7; }
   .ansi-48-5-99  { background-color: #875fff; }
   .ansi-48-5-100 { background-color: #878700; }
   .ansi-48-5-101 { background-color: #87875f; }
   .ansi-48-5-102 { background-color: #878787; }
   .ansi-48-5-103 { background-color: #8787af; }
   .ansi-48-5-104 { background-color: #8787d7; }
   .ansi-48-5-105 { background-color: #8787ff; }
   .ansi-48-5-106 { background-color: #87af00; }
   .ansi-48-5-107 { background-color: #87af5f; }
   .ansi-48-5-108 { background-color: #87af87; }
   .ansi-48-5-109 { background-color: #87afaf; }
   .ansi-48-5-110 { background-color: #87afd7; }
   .ansi-48-5-111 { background-color: #87afff; }
   .ansi-48-5-112 { background-color: #87d700; }
   .ansi-48-5-113 { background-color: #87d75f; }
   .ansi-48-5-114 { background-color: #87d787; }
   .ansi-48-5-115 { background-color: #87d7af; }
   .ansi-48-5-116 { background-color: #87d7d7; }
   .ansi-48-5-117 { background-color: #87d7ff; }
   .ansi-48-5-118 { background-color: #87ff00; }
   .ansi-48-5-119 { background-color: #87ff5f; }
   .ansi-48-5-120 { background-color: #87ff87; }
   .ansi-48-5-121 { background-color: #87ffaf; }
   .ansi-48-5-122 { background-color: #87ffd7; }
   .ansi-48-5-123 { background-color: #87ffff; }
   .ansi-48-5-124 { background-color: #af0000; }
   .ansi-48-5-125 { background-color: #af005f; }
   .ansi-48-5-126 { background-color: #af0087; }
   .ansi-48-5-127 { background-color: #af00af; }
   .ansi-48-5-128 { background-color: #af00d7; }
   .ansi-48-5-129 { background-color: #af00ff; }
   .ansi-48-5-130 { background-color: #af5f00; }
   .ansi-48-5-131 { background-color: #af5f5f; }
   .ansi-48-5-132 { background-color: #af5f87; }
   .ansi-48-5-133 { background-color: #af5faf; }
   .ansi-48-5-134 { background-color: #af5fd7; }
   .ansi-48-5-135 { background-color: #af5fff; }
   .ansi-48-5-136 { background-color: #af8700; }
   .ansi-48-5-137 { background-color: #af875f; }
   .ansi-48-5-138 { background-color: #af8787; }
   .ansi-48-5-139 { background-color: #af87af; }
   .ansi-48-5-140 { background-color: #af87d7; }
   .ansi-48-5-141 { background-color: #af87ff; }
   .ansi-48-5-142 { background-color: #afaf00; }
   .ansi-48-5-143 { background-color: #afaf5f; }
   .ansi-48-5-144 { background-color: #afaf87; }
   .ansi-48-5-145 { background-color: #afafaf; }
   .ansi-48-5-146 { background-color: #afafd7; }
   .ansi-48-5-147 { background-color: #afafff; }
   .ansi-48-5-148 { background-color: #afd700; }
   .ansi-48-5-149 { background-color: #afd75f; }
   .ansi-48-5-150 { background-color: #afd787; }
   .ansi-48-5-151 { background-color: #afd7af; }
   .ansi-48-5-152 { background-color: #afd7d7; }
   .ansi-48-5-153 { background-color: #afd7ff; }
   .ansi-48-5-154 { background-color: #afff00; }
   .ansi-48-5-155 { background-color: #afff5f; }
   .ansi-48-5-156 { background-color: #afff87; }
   .ansi-48-5-157 { background-color: #afffaf; }
   .ansi-48-5-158 { background-color: #afffd7; }
   .ansi-48-5-159 { background-color: #afffff; }
   .ansi-48-5-160 { background-color: #d70000; }
   .ansi-48-5-161 { background-color: #d7005f; }
   .ansi-48-5-162 { background-color: #d70087; }
   .ansi-48-5-163 { background-color: #d700af; }
   .ansi-48-5-164 { background-color: #d700d7; }
   .ansi-48-5-165 { background-color: #d700ff; }
   .ansi-48-5-166 { background-color: #d75f00; }
   .ansi-48-5-167 { background-color: #d75f5f; }
   .ansi-48-5-168 { background-color: #d75f87; }
   .ansi-48-5-169 { background-color: #d75faf; }
   .ansi-48-5-170 { background-color: #d75fd7; }
   .ansi-48-5-171 { background-color: #d75fff; }
   .ansi-48-5-172 { background-color: #d78700; }
   .ansi-48-5-173 { background-color: #d7875f; }
   .ansi-48-5-174 { background-color: #d78787; }
   .ansi-48-5-175 { background-color: #d787af; }
   .ansi-48-5-176 { background-color: #d787d7; }
   .ansi-48-5-177 { background-color: #d787ff; }
   .ansi-48-5-178 { background-color: #d7af00; }
   .ansi-48-5-179 { background-color: #d7af5f; }
   .ansi-48-5-180 { background-color: #d7af87; }
   .ansi-48-5-181 { background-color: #d7afaf; }
   .ansi-48-5-182 { background-color: #d7afd7; }
   .ansi-48-5-183 { background-color: #d7afff; }
   .ansi-48-5-184 { background-color: #d7d700; }
   .ansi-48-5-185 { background-color: #d7d75f; }
   .ansi-48-5-186 { background-color: #d7d787; }
   .ansi-48-5-187 { background-color: #d7d7af; }
   .ansi-48-5-188 { background-color: #d7d7d7; }
   .ansi-48-5-189 { background-color: #d7d7ff; }
   .ansi-48-5-190 { background-color: #d7ff00; }
   .ansi-48-5-191 { background-color: #d7ff5f; }
   .ansi-48-5-192 { background-color: #d7ff87; }
   .ansi-48-5-193 { background-color: #d7ffaf; }
   .ansi-48-5-194 { background-color: #d7ffd7; }
   .ansi-48-5-195 { background-color: #d7ffff; }
   .ansi-48-5-196 { background-color: #ff0000; }
   .ansi-48-5-197 { background-color: #ff005f; }
   .ansi-48-5-198 { background-color: #ff0087; }
   .ansi-48-5-199 { background-color: #ff00af; }
   .ansi-48-5-200 { background-color: #ff00d7; }
   .ansi-48-5-201 { background-color: #ff00ff; }
   .ansi-48-5-202 { background-color: #ff5f00; }
   .ansi-48-5-203 { background-color: #ff5f5f; }
   .ansi-48-5-204 { background-color: #ff5f87; }
   .ansi-48-5-205 { background-color: #ff5faf; }
   .ansi-48-5-206 { background-color: #ff5fd7; }
   .ansi-48-5-207 { background-color: #ff5fff; }
   .ansi-48-5-208 { background-color: #ff8700; }
   .ansi-48-5-209 { background-color: #ff875f; }
   .ansi-48-5-210 { background-color: #ff8787; }
   .ansi-48-5-211 { background-color: #ff87af; }
   .ansi-48-5-212 { background-color: #ff87d7; }
   .ansi-48-5-213 { background-color: #ff87ff; }
   .ansi-48-5-214 { background-color: #ffaf00; }
   .ansi-48-5-215 { background-color: #ffaf5f; }
   .ansi-48-5-216 { background-color: #ffaf87; }
   .ansi-48-5-217 { background-color: #ffafaf; }
   .ansi-48-5-218 { background-color: #ffafd7; }
   .ansi-48-5-219 { background-color: #ffafff; }
   .ansi-48-5-220 { background-color: #ffd700; }
   .ansi-48-5-221 { background-color: #ffd75f; }
   .ansi-48-5-222 { background-color: #ffd787; }
   .ansi-48-5-223 { background-color: #ffd7af; }
   .ansi-48-5-224 { background-color: #ffd7d7; }
   .ansi-48-5-225 { background-color: #ffd7ff; }
   .ansi-48-5-226 { background-color: #ffff00; }
   .ansi-48-5-227 { background-color: #ffff5f; }
   .ansi-48-5-228 { background-color: #ffff87; }
   .ansi-48-5-229 { background-color: #ffffaf; }
   .ansi-48-5-230 { background-color: #ffffd7; }
   .ansi-48-5-231 { background-color: #ffffff; }
   .ansi-48-5-232 { background-color: #080808; }
   .ansi-48-5-233 { background-color: #121212; }
   .ansi-48-5-234 { background-color: #1c1c1c; }
   .ansi-48-5-235 { background-color: #262626; }
   .ansi-48-5-236 { background-color: #303030; }
   .ansi-48-5-237 { background-color: #3a3a3a; }
   .ansi-48-5-238 { background-color: #444444; }
   .ansi-48-5-239 { background-color: #4e4e4e; }
   .ansi-48-5-240 { background-color: #585858; }
   .ansi-48-5-241 { background-color: #626262; }
   .ansi-48-5-242 { background-color: #6c6c6c; }
   .ansi-48-5-243 { background-color: #767676; }
   .ansi-48-5-244 { background-color: #808080; }
   .ansi-48-5-245 { background-color: #8a8a8a; }
   .ansi-48-5-246 { background-color: #949494; }
   .ansi-48-5-247 { background-color: #9e9e9e; }
   .ansi-48-5-248 { background-color: #a8a8a8; }
   .ansi-48-5-249 { background-color: #b2b2b2; }
   .ansi-48-5-250 { background-color: #bcbcbc; }
   .ansi-48-5-251 { background-color: #c6c6c6; }
   .ansi-48-5-252 { background-color: #d0d0d0; }
   .ansi-48-5-253 { background-color: #dadada; }
   .ansi-48-5-254 { background-color: #e4e4e4; }
   .ansi-48-5-255 { background-color: #eeeeee; }

START: muddler_dark_ansi.css
   .ansi-4 { text-decoration: underline; }
   
   /* blinking text */
   .ansi-5 {
       -webkit-animation: blink .75s linear infinite;
       -moz-animation: blink .75s linear infinite;
       -ms-animation: blink .75s linear infinite;
       -o-animation: blink .75s linear infinite;
       animation: blink .75s linear infinite;
   }
   
   /* standard 16 foreground colors */
   .ansi-30 { color: black; }
   .ansi-1-30 { color: gray; }
   .ansi-31 { color: maroon; }
   .ansi-1-31 { color: red; }
   .ansi-32 { color: green; }
   .ansi-1-32 { color: lime; }
   .ansi-33 { color: olive; }
   .ansi-1-33 { color: yellow; }
   .ansi-34 { color: navy; }
   .ansi-1-34 { color: blue; }
   .ansi-35 { color: purple; }
   .ansi-1-35 { color: fuchsia; }
   .ansi-36 { color: teal; }
   .ansi-1-36 { color: aqua; }
   .ansi-37 { color: black; }
   .ansi-1-37 { color: white; }
   
   /* standard 16 background colors */
   .ansi-40 { background-color: black; }
   .ansi-1-40 { background-color: gray; }
   .ansi-41 { background-color: maroon; }
   .ansi-1-41 { background-color: red; }
   .ansi-42 { background-color: green; }
   .ansi-1-42 { background-color: lime; }
   .ansi-43 { background-color: olive; }
   .ansi-1-43 { background-color: yellow; }
   .ansi-44 { background-color: navy; }
   .ansi-1-44 { background-color: blue; }
   .ansi-45 { background-color: purple; }
   .ansi-1-45 { background-color: fuchsia; }
   .ansi-46 { background-color: teal; }
   .ansi-1-46 { background-color: aqua; }
   .ansi-47 { background-color: silver; }
   .ansi-1-47 { background-color: white; }
   
   /* xterm256 foreground colors */
   .ansi-38-5-0 { color: #000000; }
   .ansi-38-5-1 { color: #800000; }
   .ansi-38-5-2 { color: #008000; }
   .ansi-38-5-3 { color: #808000; }
   .ansi-38-5-4 { color: #000080; }
   .ansi-38-5-5 { color: #800080; }
   .ansi-38-5-6 { color: #008080; }
   .ansi-38-5-7 { color: #c0c0c0; }
   .ansi-38-5-8 { color: #808080; }
   .ansi-38-5-9 { color: #ff0000; }
   .ansi-38-5-10 { color: #00ff00; }
   .ansi-38-5-11 { color: #ffff00; }
   .ansi-38-5-12 { color: #0000ff; }
   .ansi-38-5-13 { color: #ff00ff; }
   .ansi-38-5-14 { color: #00ffff; }
   .ansi-38-5-15 { color: #ffffff; }
   .ansi-38-5-16 { color: #000000; }
   .ansi-38-5-17 { color: #00005f; }
   .ansi-38-5-18 { color: #000087; }
   .ansi-38-5-19 { color: #0000af; }
   .ansi-38-5-20 { color: #0000d7; }
   .ansi-38-5-21 { color: #0000ff; }
   .ansi-38-5-22 { color: #005f00; }
   .ansi-38-5-23 { color: #005f5f; }
   .ansi-38-5-24 { color: #005f87; }
   .ansi-38-5-25 { color: #005faf; }
   .ansi-38-5-26 { color: #005fd7; }
   .ansi-38-5-27 { color: #005fff; }
   .ansi-38-5-28 { color: #008700; }
   .ansi-38-5-29 { color: #00875f; }
   .ansi-38-5-30 { color: #008787; }
   .ansi-38-5-31 { color: #0087af; }
   .ansi-38-5-32 { color: #0087d7; }
   .ansi-38-5-33 { color: #0087ff; }
   .ansi-38-5-34 { color: #00af00; }
   .ansi-38-5-35 { color: #00af5f; }
   .ansi-38-5-36 { color: #00af87; }
   .ansi-38-5-37 { color: #00afaf; }
   .ansi-38-5-38 { color: #00afd7; }
   .ansi-38-5-39 { color: #00afff; }
   .ansi-38-5-40 { color: #00d700; }
   .ansi-38-5-41 { color: #00d75f; }
   .ansi-38-5-42 { color: #00d787; }
   .ansi-38-5-43 { color: #00d7af; }
   .ansi-38-5-44 { color: #00d7d7; }
   .ansi-38-5-45 { color: #00d7ff; }
   .ansi-38-5-46 { color: #00ff00; }
   .ansi-38-5-47 { color: #00ff5f; }
   .ansi-38-5-48 { color: #00ff87; }
   .ansi-38-5-49 { color: #00ffaf; }
   .ansi-38-5-50 { color: #00ffd7; }
   .ansi-38-5-51 { color: #00ffff; }
   .ansi-38-5-52 { color: #5f0000; }
   .ansi-38-5-53 { color: #5f005f; }
   .ansi-38-5-54 { color: #5f0087; }
   .ansi-38-5-55 { color: #5f00af; }
   .ansi-38-5-56 { color: #5f00d7; }
   .ansi-38-5-57 { color: #5f00ff; }
   .ansi-38-5-58 { color: #5f5f00; }
   .ansi-38-5-59 { color: #5f5f5f; }
   .ansi-38-5-60 { color: #5f5f87; }
   .ansi-38-5-61 { color: #5f5faf; }
   .ansi-38-5-62 { color: #5f5fd7; }
   .ansi-38-5-63 { color: #5f5fff; }
   .ansi-38-5-64 { color: #5f8700; }
   .ansi-38-5-65 { color: #5f875f; }
   .ansi-38-5-66 { color: #5f8787; }
   .ansi-38-5-67 { color: #5f87af; }
   .ansi-38-5-68 { color: #5f87d7; }
   .ansi-38-5-69 { color: #5f87ff; }
   .ansi-38-5-70 { color: #5faf00; }
   .ansi-38-5-71 { color: #5faf5f; }
   .ansi-38-5-72 { color: #5faf87; }
   .ansi-38-5-73 { color: #5fafaf; }
   .ansi-38-5-74 { color: #5fafd7; }
   .ansi-38-5-75 { color: #5fafff; }
   .ansi-38-5-76 { color: #5fd700; }
   .ansi-38-5-77 { color: #5fd75f; }
   .ansi-38-5-78 { color: #5fd787; }
   .ansi-38-5-79 { color: #5fd7af; }
   .ansi-38-5-80 { color: #5fd7d7; }
   .ansi-38-5-81 { color: #5fd7ff; }
   .ansi-38-5-82 { color: #5fff00; }
   .ansi-38-5-83 { color: #5fff5f; }
   .ansi-38-5-84 { color: #5fff87; }
   .ansi-38-5-85 { color: #5fffaf; }
   .ansi-38-5-86 { color: #5fffd7; }
   .ansi-38-5-87 { color: #5fffff; }
   .ansi-38-5-88 { color: #870000; }
   .ansi-38-5-89 { color: #87005f; }
   .ansi-38-5-90 { color: #870087; }
   .ansi-38-5-91 { color: #8700af; }
   .ansi-38-5-92 { color: #8700d7; }
   .ansi-38-5-93 { color: #8700ff; }
   .ansi-38-5-94 { color: #875f00; }
   .ansi-38-5-95 { color: #875f5f; }
   .ansi-38-5-96 { color: #875f87; }
   .ansi-38-5-97 { color: #875faf; }
   .ansi-38-5-98 { color: #875fd7; }
   .ansi-38-5-99 { color: #875fff; }
   .ansi-38-5-100 { color: #878700; }
   .ansi-38-5-101 { color: #87875f; }
   .ansi-38-5-102 { color: #878787; }
   .ansi-38-5-103 { color: #8787af; }
   .ansi-38-5-104 { color: #8787d7; }
   .ansi-38-5-105 { color: #8787ff; }
   .ansi-38-5-106 { color: #87af00; }
   .ansi-38-5-107 { color: #87af5f; }
   .ansi-38-5-108 { color: #87af87; }
   .ansi-38-5-109 { color: #87afaf; }
   .ansi-38-5-110 { color: #87afd7; }
   .ansi-38-5-111 { color: #87afff; }
   .ansi-38-5-112 { color: #87d700; }
   .ansi-38-5-113 { color: #87d75f; }
   .ansi-38-5-114 { color: #87d787; }
   .ansi-38-5-115 { color: #87d7af; }
   .ansi-38-5-116 { color: #87d7d7; }
   .ansi-38-5-117 { color: #87d7ff; }
   .ansi-38-5-118 { color: #87ff00; }
   .ansi-38-5-119 { color: #87ff5f; }
   .ansi-38-5-120 { color: #87ff87; }
   .ansi-38-5-121 { color: #87ffaf; }
   .ansi-38-5-122 { color: #87ffd7; }
   .ansi-38-5-123 { color: #87ffff; }
   .ansi-38-5-124 { color: #af0000; }
   .ansi-38-5-125 { color: #af005f; }
   .ansi-38-5-126 { color: #af0087; }
   .ansi-38-5-127 { color: #af00af; }
   .ansi-38-5-128 { color: #af00d7; }
   .ansi-38-5-129 { color: #af00ff; }
   .ansi-38-5-130 { color: #af5f00; }
   .ansi-38-5-131 { color: #af5f5f; }
   .ansi-38-5-132 { color: #af5f87; }
   .ansi-38-5-133 { color: #af5faf; }
   .ansi-38-5-134 { color: #af5fd7; }
   .ansi-38-5-135 { color: #af5fff; }
   .ansi-38-5-136 { color: #af8700; }
   .ansi-38-5-137 { color: #af875f; }
   .ansi-38-5-138 { color: #af8787; }
   .ansi-38-5-139 { color: #af87af; }
   .ansi-38-5-140 { color: #af87d7; }
   .ansi-38-5-141 { color: #af87ff; }
   .ansi-38-5-142 { color: #afaf00; }
   .ansi-38-5-143 { color: #afaf5f; }
   .ansi-38-5-144 { color: #afaf87; }
   .ansi-38-5-145 { color: #afafaf; }
   .ansi-38-5-146 { color: #afafd7; }
   .ansi-38-5-147 { color: #afafff; }
   .ansi-38-5-148 { color: #afd700; }
   .ansi-38-5-149 { color: #afd75f; }
   .ansi-38-5-150 { color: #afd787; }
   .ansi-38-5-151 { color: #afd7af; }
   .ansi-38-5-152 { color: #afd7d7; }
   .ansi-38-5-153 { color: #afd7ff; }
   .ansi-38-5-154 { color: #afff00; }
   .ansi-38-5-155 { color: #afff5f; }
   .ansi-38-5-156 { color: #afff87; }
   .ansi-38-5-157 { color: #afffaf; }
   .ansi-38-5-158 { color: #afffd7; }
   .ansi-38-5-159 { color: #afffff; }
   .ansi-38-5-160 { color: #d70000; }
   .ansi-38-5-161 { color: #d7005f; }
   .ansi-38-5-162 { color: #d70087; }
   .ansi-38-5-163 { color: #d700af; }
   .ansi-38-5-164 { color: #d700d7; }
   .ansi-38-5-165 { color: #d700ff; }
   .ansi-38-5-166 { color: #d75f00; }
   .ansi-38-5-167 { color: #d75f5f; }
   .ansi-38-5-168 { color: #d75f87; }
   .ansi-38-5-169 { color: #d75faf; }
   .ansi-38-5-170 { color: #d75fd7; }
   .ansi-38-5-171 { color: #d75fff; }
   .ansi-38-5-172 { color: #d78700; }
   .ansi-38-5-173 { color: #d7875f; }
   .ansi-38-5-174 { color: #d78787; }
   .ansi-38-5-175 { color: #d787af; }
   .ansi-38-5-176 { color: #d787d7; }
   .ansi-38-5-177 { color: #d787ff; }
   .ansi-38-5-178 { color: #d7af00; }
   .ansi-38-5-179 { color: #d7af5f; }
   .ansi-38-5-180 { color: #d7af87; }
   .ansi-38-5-181 { color: #d7afaf; }
   .ansi-38-5-182 { color: #d7afd7; }
   .ansi-38-5-183 { color: #d7afff; }
   .ansi-38-5-184 { color: #d7d700; }
   .ansi-38-5-185 { color: #d7d75f; }
   .ansi-38-5-186 { color: #d7d787; }
   .ansi-38-5-187 { color: #d7d7af; }
   .ansi-38-5-188 { color: #d7d7d7; }
   .ansi-38-5-189 { color: #d7d7ff; }
   .ansi-38-5-190 { color: #d7ff00; }
   .ansi-38-5-191 { color: #d7ff5f; }
   .ansi-38-5-192 { color: #d7ff87; }
   .ansi-38-5-193 { color: #d7ffaf; }
   .ansi-38-5-194 { color: #d7ffd7; }
   .ansi-38-5-195 { color: #d7ffff; }
   .ansi-38-5-196 { color: #ff0000; }
   .ansi-38-5-197 { color: #ff005f; }
   .ansi-38-5-198 { color: #ff0087; }
   .ansi-38-5-199 { color: #ff00af; }
   .ansi-38-5-200 { color: #ff00d7; }
   .ansi-38-5-201 { color: #ff00ff; }
   .ansi-38-5-202 { color: #ff5f00; }
   .ansi-38-5-203 { color: #ff5f5f; }
   .ansi-38-5-204 { color: #ff5f87; }
   .ansi-38-5-205 { color: #ff5faf; }
   .ansi-38-5-206 { color: #ff5fd7; }
   .ansi-38-5-207 { color: #ff5fff; }
   .ansi-38-5-208 { color: #ff8700; }
   .ansi-38-5-209 { color: #ff875f; }
   .ansi-38-5-210 { color: #ff8787; }
   .ansi-38-5-211 { color: #ff87af; }
   .ansi-38-5-212 { color: #ff87d7; }
   .ansi-38-5-213 { color: #ff87ff; }
   .ansi-38-5-214 { color: #ffaf00; }
   .ansi-38-5-215 { color: #ffaf5f; }
   .ansi-38-5-216 { color: #ffaf87; }
   .ansi-38-5-217 { color: #ffafaf; }
   .ansi-38-5-218 { color: #ffafd7; }
   .ansi-38-5-219 { color: #ffafff; }
   .ansi-38-5-220 { color: #ffd700; }
   .ansi-38-5-221 { color: #ffd75f; }
   .ansi-38-5-222 { color: #ffd787; }
   .ansi-38-5-223 { color: #ffd7af; }
   .ansi-38-5-224 { color: #ffd7d7; }
   .ansi-38-5-225 { color: #ffd7ff; }
   .ansi-38-5-226 { color: #ffff00; }
   .ansi-38-5-227 { color: #ffff5f; }
   .ansi-38-5-228 { color: #ffff87; }
   .ansi-38-5-229 { color: #ffffaf; }
   .ansi-38-5-230 { color: #ffffd7; }
   .ansi-38-5-231 { color: #ffffff; }
   .ansi-38-5-232 { color: #080808; }
   .ansi-38-5-233 { color: #121212; }
   .ansi-38-5-234 { color: #1c1c1c; }
   .ansi-38-5-235 { color: #262626; }
   .ansi-38-5-236 { color: #303030; }
   .ansi-38-5-237 { color: #3a3a3a; }
   .ansi-38-5-238 { color: #444444; }
   .ansi-38-5-239 { color: #4e4e4e; }
   .ansi-38-5-240 { color: #585858; }
   .ansi-38-5-241 { color: #626262; }
   .ansi-38-5-242 { color: #6c6c6c; }
   .ansi-38-5-243 { color: #767676; }
   .ansi-38-5-244 { color: #808080; }
   .ansi-38-5-245 { color: #8a8a8a; }
   .ansi-38-5-246 { color: #949494; }
   .ansi-38-5-247 { color: #9e9e9e; }
   .ansi-38-5-248 { color: #a8a8a8; }
   .ansi-38-5-249 { color: #b2b2b2; }
   .ansi-38-5-250 { color: #bcbcbc; }
   .ansi-38-5-251 { color: #c6c6c6; }
   .ansi-38-5-252 { color: #d0d0d0; }
   .ansi-38-5-253 { color: #dadada; }
   .ansi-38-5-254 { color: #e4e4e4; }
   .ansi-38-5-255 { color: #eeeeee; }
   
   /* xterm256 background colors */
   .ansi-48-5-0 { background-color: #000000; }
   .ansi-48-5-1 { background-color: #800000; }
   .ansi-48-5-2 { background-color: #008000; }
   .ansi-48-5-3 { background-color: #808000; }
   .ansi-48-5-4 { background-color: #000080; }
   .ansi-48-5-5 { background-color: #800080; }
   .ansi-48-5-6 { background-color: #008080; }
   .ansi-48-5-7 { background-color: #c0c0c0; }
   .ansi-48-5-8 { background-color: #808080; }
   .ansi-48-5-9 { background-color: #ff0000; }
   .ansi-48-5-10 { background-color: #00ff00; }
   .ansi-48-5-11 { background-color: #ffff00; }
   .ansi-48-5-12 { background-color: #0000ff; }
   .ansi-48-5-13 { background-color: #ff00ff; }
   .ansi-48-5-14 { background-color: #00ffff; }
   .ansi-48-5-15 { background-color: #ffffff; }
   .ansi-48-5-16 { background-color: #000000; }
   .ansi-48-5-17 { background-color: #00005f; }
   .ansi-48-5-18 { background-color: #000087; }
   .ansi-48-5-19 { background-color: #0000af; }
   .ansi-48-5-20 { background-color: #0000d7; }
   .ansi-48-5-21 { background-color: #0000ff; }
   .ansi-48-5-22 { background-color: #005f00; }
   .ansi-48-5-23 { background-color: #005f5f; }
   .ansi-48-5-24 { background-color: #005f87; }
   .ansi-48-5-25 { background-color: #005faf; }
   .ansi-48-5-26 { background-color: #005fd7; }
   .ansi-48-5-27 { background-color: #005fff; }
   .ansi-48-5-28 { background-color: #008700; }
   .ansi-48-5-29 { background-color: #00875f; }
   .ansi-48-5-30 { background-color: #008787; }
   .ansi-48-5-31 { background-color: #0087af; }
   .ansi-48-5-32 { background-color: #0087d7; }
   .ansi-48-5-33 { background-color: #0087ff; }
   .ansi-48-5-34 { background-color: #00af00; }
   .ansi-48-5-35 { background-color: #00af5f; }
   .ansi-48-5-36 { background-color: #00af87; }
   .ansi-48-5-37 { background-color: #00afaf; }
   .ansi-48-5-38 { background-color: #00afd7; }
   .ansi-48-5-39 { background-color: #00afff; }
   .ansi-48-5-40 { background-color: #00d700; }
   .ansi-48-5-41 { background-color: #00d75f; }
   .ansi-48-5-42 { background-color: #00d787; }
   .ansi-48-5-43 { background-color: #00d7af; }
   .ansi-48-5-44 { background-color: #00d7d7; }
   .ansi-48-5-45 { background-color: #00d7ff; }
   .ansi-48-5-46 { background-color: #00ff00; }
   .ansi-48-5-47 { background-color: #00ff5f; }
   .ansi-48-5-48 { background-color: #00ff87; }
   .ansi-48-5-49 { background-color: #00ffaf; }
   .ansi-48-5-50 { background-color: #00ffd7; }
   .ansi-48-5-51 { background-color: #00ffff; }
   .ansi-48-5-52 { background-color: #5f0000; }
   .ansi-48-5-53 { background-color: #5f005f; }
   .ansi-48-5-54 { background-color: #5f0087; }
   .ansi-48-5-55 { background-color: #5f00af; }
   .ansi-48-5-56 { background-color: #5f00d7; }
   .ansi-48-5-57 { background-color: #5f00ff; }
   .ansi-48-5-58 { background-color: #5f5f00; }
   .ansi-48-5-59 { background-color: #5f5f5f; }
   .ansi-48-5-60 { background-color: #5f5f87; }
   .ansi-48-5-61 { background-color: #5f5faf; }
   .ansi-48-5-62 { background-color: #5f5fd7; }
   .ansi-48-5-63 { background-color: #5f5fff; }
   .ansi-48-5-64 { background-color: #5f8700; }
   .ansi-48-5-65 { background-color: #5f875f; }
   .ansi-48-5-66 { background-color: #5f8787; }
   .ansi-48-5-67 { background-color: #5f87af; }
   .ansi-48-5-68 { background-color: #5f87d7; }
   .ansi-48-5-69 { background-color: #5f87ff; }
   .ansi-48-5-70 { background-color: #5faf00; }
   .ansi-48-5-71 { background-color: #5faf5f; }
   .ansi-48-5-72 { background-color: #5faf87; }
   .ansi-48-5-73 { background-color: #5fafaf; }
   .ansi-48-5-74 { background-color: #5fafd7; }
   .ansi-48-5-75 { background-color: #5fafff; }
   .ansi-48-5-76 { background-color: #5fd700; }
   .ansi-48-5-77 { background-color: #5fd75f; }
   .ansi-48-5-78 { background-color: #5fd787; }
   .ansi-48-5-79 { background-color: #5fd7af; }
   .ansi-48-5-80 { background-color: #5fd7d7; }
   .ansi-48-5-81 { background-color: #5fd7ff; }
   .ansi-48-5-82 { background-color: #5fff00; }
   .ansi-48-5-83 { background-color: #5fff5f; }
   .ansi-48-5-84 { background-color: #5fff87; }
   .ansi-48-5-85 { background-color: #5fffaf; }
   .ansi-48-5-86 { background-color: #5fffd7; }
   .ansi-48-5-87 { background-color: #5fffff; }
   .ansi-48-5-88 { background-color: #870000; }
   .ansi-48-5-89 { background-color: #87005f; }
   .ansi-48-5-90 { background-color: #870087; }
   .ansi-48-5-91 { background-color: #8700af; }
   .ansi-48-5-92 { background-color: #8700d7; }
   .ansi-48-5-93 { background-color: #8700ff; }
   .ansi-48-5-94 { background-color: #875f00; }
   .ansi-48-5-95 { background-color: #875f5f; }
   .ansi-48-5-96 { background-color: #875f87; }
   .ansi-48-5-97 { background-color: #875faf; }
   .ansi-48-5-98 { background-color: #875fd7; }
   .ansi-48-5-99 { background-color: #875fff; }
   .ansi-48-5-100 { background-color: #878700; }
   .ansi-48-5-101 { background-color: #87875f; }
   .ansi-48-5-102 { background-color: #878787; }
   .ansi-48-5-103 { background-color: #8787af; }
   .ansi-48-5-104 { background-color: #8787d7; }
   .ansi-48-5-105 { background-color: #8787ff; }
   .ansi-48-5-106 { background-color: #87af00; }
   .ansi-48-5-107 { background-color: #87af5f; }
   .ansi-48-5-108 { background-color: #87af87; }
   .ansi-48-5-109 { background-color: #87afaf; }
   .ansi-48-5-110 { background-color: #87afd7; }
   .ansi-48-5-111 { background-color: #87afff; }
   .ansi-48-5-112 { background-color: #87d700; }
   .ansi-48-5-113 { background-color: #87d75f; }
   .ansi-48-5-114 { background-color: #87d787; }
   .ansi-48-5-115 { background-color: #87d7af; }
   .ansi-48-5-116 { background-color: #87d7d7; }
   .ansi-48-5-117 { background-color: #87d7ff; }
   .ansi-48-5-118 { background-color: #87ff00; }
   .ansi-48-5-119 { background-color: #87ff5f; }
   .ansi-48-5-120 { background-color: #87ff87; }
   .ansi-48-5-121 { background-color: #87ffaf; }
   .ansi-48-5-122 { background-color: #87ffd7; }
   .ansi-48-5-123 { background-color: #87ffff; }
   .ansi-48-5-124 { background-color: #af0000; }
   .ansi-48-5-125 { background-color: #af005f; }
   .ansi-48-5-126 { background-color: #af0087; }
   .ansi-48-5-127 { background-color: #af00af; }
   .ansi-48-5-128 { background-color: #af00d7; }
   .ansi-48-5-129 { background-color: #af00ff; }
   .ansi-48-5-130 { background-color: #af5f00; }
   .ansi-48-5-131 { background-color: #af5f5f; }
   .ansi-48-5-132 { background-color: #af5f87; }
   .ansi-48-5-133 { background-color: #af5faf; }
   .ansi-48-5-134 { background-color: #af5fd7; }
   .ansi-48-5-135 { background-color: #af5fff; }
   .ansi-48-5-136 { background-color: #af8700; }
   .ansi-48-5-137 { background-color: #af875f; }
   .ansi-48-5-138 { background-color: #af8787; }
   .ansi-48-5-139 { background-color: #af87af; }
   .ansi-48-5-140 { background-color: #af87d7; }
   .ansi-48-5-141 { background-color: #af87ff; }
   .ansi-48-5-142 { background-color: #afaf00; }
   .ansi-48-5-143 { background-color: #afaf5f; }
   .ansi-48-5-144 { background-color: #afaf87; }
   .ansi-48-5-145 { background-color: #afafaf; }
   .ansi-48-5-146 { background-color: #afafd7; }
   .ansi-48-5-147 { background-color: #afafff; }
   .ansi-48-5-148 { background-color: #afd700; }
   .ansi-48-5-149 { background-color: #afd75f; }
   .ansi-48-5-150 { background-color: #afd787; }
   .ansi-48-5-151 { background-color: #afd7af; }
   .ansi-48-5-152 { background-color: #afd7d7; }
   .ansi-48-5-153 { background-color: #afd7ff; }
   .ansi-48-5-154 { background-color: #afff00; }
   .ansi-48-5-155 { background-color: #afff5f; }
   .ansi-48-5-156 { background-color: #afff87; }
   .ansi-48-5-157 { background-color: #afffaf; }
   .ansi-48-5-158 { background-color: #afffd7; }
   .ansi-48-5-159 { background-color: #afffff; }
   .ansi-48-5-160 { background-color: #d70000; }
   .ansi-48-5-161 { background-color: #d7005f; }
   .ansi-48-5-162 { background-color: #d70087; }
   .ansi-48-5-163 { background-color: #d700af; }
   .ansi-48-5-164 { background-color: #d700d7; }
   .ansi-48-5-165 { background-color: #d700ff; }
   .ansi-48-5-166 { background-color: #d75f00; }
   .ansi-48-5-167 { background-color: #d75f5f; }
   .ansi-48-5-168 { background-color: #d75f87; }
   .ansi-48-5-169 { background-color: #d75faf; }
   .ansi-48-5-170 { background-color: #d75fd7; }
   .ansi-48-5-171 { background-color: #d75fff; }
   .ansi-48-5-172 { background-color: #d78700; }
   .ansi-48-5-173 { background-color: #d7875f; }
   .ansi-48-5-174 { background-color: #d78787; }
   .ansi-48-5-175 { background-color: #d787af; }
   .ansi-48-5-176 { background-color: #d787d7; }
   .ansi-48-5-177 { background-color: #d787ff; }
   .ansi-48-5-178 { background-color: #d7af00; }
   .ansi-48-5-179 { background-color: #d7af5f; }
   .ansi-48-5-180 { background-color: #d7af87; }
   .ansi-48-5-181 { background-color: #d7afaf; }
   .ansi-48-5-182 { background-color: #d7afd7; }
   .ansi-48-5-183 { background-color: #d7afff; }
   .ansi-48-5-184 { background-color: #d7d700; }
   .ansi-48-5-185 { background-color: #d7d75f; }
   .ansi-48-5-186 { background-color: #d7d787; }
   .ansi-48-5-187 { background-color: #d7d7af; }
   .ansi-48-5-188 { background-color: #d7d7d7; }
   .ansi-48-5-189 { background-color: #d7d7ff; }
   .ansi-48-5-190 { background-color: #d7ff00; }
   .ansi-48-5-191 { background-color: #d7ff5f; }
   .ansi-48-5-192 { background-color: #d7ff87; }
   .ansi-48-5-193 { background-color: #d7ffaf; }
   .ansi-48-5-194 { background-color: #d7ffd7; }
   .ansi-48-5-195 { background-color: #d7ffff; }
   .ansi-48-5-196 { background-color: #ff0000; }
   .ansi-48-5-197 { background-color: #ff005f; }
   .ansi-48-5-198 { background-color: #ff0087; }
   .ansi-48-5-199 { background-color: #ff00af; }
   .ansi-48-5-200 { background-color: #ff00d7; }
   .ansi-48-5-201 { background-color: #ff00ff; }
   .ansi-48-5-202 { background-color: #ff5f00; }
   .ansi-48-5-203 { background-color: #ff5f5f; }
   .ansi-48-5-204 { background-color: #ff5f87; }
   .ansi-48-5-205 { background-color: #ff5faf; }
   .ansi-48-5-206 { background-color: #ff5fd7; }
   .ansi-48-5-207 { background-color: #ff5fff; }
   .ansi-48-5-208 { background-color: #ff8700; }
   .ansi-48-5-209 { background-color: #ff875f; }
   .ansi-48-5-210 { background-color: #ff8787; }
   .ansi-48-5-211 { background-color: #ff87af; }
   .ansi-48-5-212 { background-color: #ff87d7; }
   .ansi-48-5-213 { background-color: #ff87ff; }
   .ansi-48-5-214 { background-color: #ffaf00; }
   .ansi-48-5-215 { background-color: #ffaf5f; }
   .ansi-48-5-216 { background-color: #ffaf87; }
   .ansi-48-5-217 { background-color: #ffafaf; }
   .ansi-48-5-218 { background-color: #ffafd7; }
   .ansi-48-5-219 { background-color: #ffafff; }
   .ansi-48-5-220 { background-color: #ffd700; }
   .ansi-48-5-221 { background-color: #ffd75f; }
   .ansi-48-5-222 { background-color: #ffd787; }
   .ansi-48-5-223 { background-color: #ffd7af; }
   .ansi-48-5-224 { background-color: #ffd7d7; }
   .ansi-48-5-225 { background-color: #ffd7ff; }
   .ansi-48-5-226 { background-color: #ffff00; }
   .ansi-48-5-227 { background-color: #ffff5f; }
   .ansi-48-5-228 { background-color: #ffff87; }
   .ansi-48-5-229 { background-color: #ffffaf; }
   .ansi-48-5-230 { background-color: #ffffd7; }
   .ansi-48-5-231 { background-color: #ffffff; }
   .ansi-48-5-232 { background-color: #080808; }
   .ansi-48-5-233 { background-color: #121212; }
   .ansi-48-5-234 { background-color: #1c1c1c; }
   .ansi-48-5-235 { background-color: #262626; }
   .ansi-48-5-236 { background-color: #303030; }
   .ansi-48-5-237 { background-color: #3a3a3a; }
   .ansi-48-5-248 { background-color: #444444; }
   .ansi-48-5-239 { background-color: #4e4e4e; }
   .ansi-48-5-240 { background-color: #585858; }
   .ansi-48-5-241 { background-color: #626262; }
   .ansi-48-5-242 { background-color: #6c6c6c; }
   .ansi-48-5-243 { background-color: #767676; }
   .ansi-48-5-244 { background-color: #808080; }
   .ansi-48-5-245 { background-color: #8a8a8a; }
   .ansi-48-5-246 { background-color: #949494; }
   .ansi-48-5-247 { background-color: #9e9e9e; }
   .ansi-48-5-248 { background-color: #a8a8a8; }
   .ansi-48-5-249 { background-color: #b2b2b2; }
   .ansi-48-5-250 { background-color: #bcbcbc; }
   .ansi-48-5-251 { background-color: #c6c6c6; }
   .ansi-48-5-252 { background-color: #d0d0d0; }
   .ansi-48-5-253 { background-color: #dadada; }
   .ansi-48-5-254 { background-color: #e4e4e4; }
   .ansi-48-5-255 { background-color: #eeeeee; }
__ANSI__

START: muddler_style.css
   html, body {
     width: 100%;
     height: 100%;
     margin: 0;
     overflow: hidden;
     background: #2667bd;
   /*     font-family: 'Courier New', monospace; */
   /*     font-family: 'termnine',Monospace; */
     font-family: Monospace;
     font-size: 10pt;
     font-weight: normal;
   }
   
   a {
     display: inline;
     text-decoration: none;
     border-bottom: 1px solid blue;
   }
   
   a:hover {
     cursor: pointer;
   }
   
   textarea {
     font-family: inherit;
     font-size: inherit;
   }
   
   ul {
     display: flex;
     flex-direction: column;
     list-style-type: none;
     margin: 0;
     padding: 0;
   }
   
   .localEcho {
     color: blue;
     font-weight: bold;
   }
   
   .logMessage {
     color: red;
     font-weight: bold;
   }
   
   #terminal {
     position: fixed;
     margin: 0;
     padding: 0;
     border: none;
     background: white;
     left: 0px;
     right: 0px;
     top: 0px;
     bottom: 0px;
     box-shadow: 0 0 0.2em 0.1em gray;
     overflow: hidden;
     /* display: none; */
   }
   
   #output {
     overflow: hidden;
     white-space: pre-wrap;
     word-wrap: break-word;
     position: absolute;
     margin: 0;
     border: 0;
     padding: 0.5em 0.5% 0.5em 0.5%;
     left: 0;
     width: 99%;
     top: 0;
     bottom: 6em;
     background: white; 
   }
   
   #bar {
     white-space: pre-wrap;
     color: red;
     font-weight: bold;
     display: table-cell;
     overflow: hidden;
     position: absolute;
     left: 0;
     width: 100%;
     bottom: 4em;
     height: 1.4em;
     vertical-align: middle;
     text-align: left;
     border-bottom: 1px solid black;
   }
   
   #prompt {
     overflow: hidden;
     white-space: pre-wrap;
     text-align: left;
     position: absolute;
     margin: 0;
     left: 0;
     width: 100%;
     bottom: 4em;
     height: 1em;
   }
   
   #input {
     position: absolute;
     margin: 0;
     background: white;
     color: black;
     border: none;
     outline: none;
     vertical-align: middle;
     padding: 0.5em 0.5% 0.5em 0.5%;
     resize: none;
     left: 0;
     width: 99%;
     bottom: 0;
     height: 3em;
   }
   #buttonbar {
     position: absolute;
     margin: 0;
     background: white;
     color: black;
     border: none;
     outline: none;
     vertical-align: middle;
     padding: 0px 0px 0px 0px;
     resize: none;
     left: 0;
     width: 100%;
     bottom: 0;
     height: 30px;
     float: left;
     display: none;
   }

   .triangle {
       border: 2px solid gray;
       position: absolute;
       height: 100px;
       width: 100px;
       z-index: 2; 
   }
   
   .inner-triangle {
      width: 0;
      height: 0;
      border-top: 70px solid #ffcc00;
      border-bottom: 70px solid transparent;
      border-left: 70px solid transparent;
      position:absolute;
      right:0;
      z-index: 2; 
   }

   .inner-triangle span {
      position:absolute;
      top: -50px;
      width: 70px;
      left: -60px;
      text-align: center;
      transform: rotate(45deg);
      display: block;
      z-index: 10;
   }

START: muddler_client.js
   //////////////////////////////////////////////////////////////////
   // WebSockClient for PennMUSH
   // There is no license. Just make a neato game with it.
   //////////////////////////////////////////////////////////////////
   
   var WSClient = (function (window, document, undefined) {
   
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
   
     // MU* protocol carried over the WebSocket API.


     function displaywheel(e){
         var evt=window.event || e //equalize event object
         var delta=evt.detail? evt.detail*(-500) : evt.wheelDelta 
         //check for detail first so Opera uses that instead of wheelDelta
         window.console.log(delta);
         if(delta < 0) {
             input.onEnter('/key_pgdn 5')
         } else {
             input.onEnter('/key_pgup 5');
         }
     }
 
     var mousewheelevt=(/Firefox/i.test(navigator.userAgent))? "DOMMouseScroll" : "mousewheel" //FF doesn't recognize mousewheel as of FF3.x
 
     if (document.attachEvent) //if IE (and Opera depending on user setting)
         document.attachEvent("on"+mousewheelevt, displaywheel)
     else if (document.addEventListener) //WC3 browsers
         document.addEventListener(mousewheelevt, displaywheel, false)

      var t

      window.onresize = () => {
          clearTimeout(t); 
          t = setTimeout(() => { t = undefined; resEnded() }, 500);
      }
      
      function resEnded() { 
          input.onEnter('/web_size ' + get_xy_size() + '\r\n' );
      }

     function get_xy_size() {
         var out = document.getElementById('output')
         var css = getComputedStyle(out,null);
         var ff  = css.getPropertyValue("font-family");
         var fs  = css.getPropertyValue("font-size");
         
         var temp = document.createElement('span');
         temp.style = "margin:0px;padding:0px;font-family:"+ff+
                       ";font-size:"+fs;
         temp.innerText = "0123456789";
         var element = document.body.appendChild(temp);
         var out = document.getElementById('output');
         var x = Math.round(out.offsetHeight / temp.offsetHeight);
         var y = Math.round(out.offsetWidth / (temp.offsetWidth / 10));
         temp.parentNode.removeChild(temp);
         return x + "," + y;
     }
   
     function Connection(url) {
       var that = this;
       
       this.url = url;
       this.socket = null;
       this.isOpen = false;
       
       Connection.reconnect(that);
     }
     
     Connection.CHANNEL_TEXT   = 't';
     Connection.CHANNEL_BAR    = 'b';
     Connection.CHANNEL_JSON   = 'j';
     Connection.CHANNEL_HTML   = 'h';
     Connection.CHANNEL_PUEBLO = 'p';
     Connection.CHANNEL_PROMPT = '>';
     Connection.CHANNEL_DO     = 'd';
   
     Connection.reconnect = function (that) {
       that.reconnect();
     };
     
     Connection.onopen = function (that, evt) {
       that.isOpen = true;
       that.onOpen && that.onOpen(evt);
     };
   
     Connection.onerror = function (that, evt) {
       that.isOpen = false;
       that.onError && that.onError(evt);
     };
   
     Connection.onclose = function (that, evt) {
       that.isOpen = false;
       that.onClose && that.onClose(evt);
     };
   
     Connection.onmessage = function (that, evt) {
       that.onMessage && that.onMessage(evt.data[0], evt.data.substring(1));
     };
   
     Connection.prototype.reconnect = function () {
       var that = this;
       
       // quit the old connection, if we have one
       if (this.isConnected()) {
         var old = this.socket;
         this.isOpen && setTimeout(old.close, 1000);
       }
   
       console.log('URL: ' + this.url);
       this.socket = new window.WebSocket(this.url);
       this.isOpen = false;
   
       this.socket.onopen = function (evt) {
         Connection.onopen(that, evt);
       };
   
       this.socket.onerror = function (evt) {
         Connection.onerror(that, evt);
       };
   
       this.socket.onclose = function (evt) {
         Connection.onclose(that, evt);
       };
   
       this.socket.onmessage = function (evt) {
         Connection.onmessage(that, evt);
       };
     };
     
     Connection.prototype.isConnected = function() {
       return (this.socket && this.isOpen && (this.socket.readyState === 1));
     };
   
     Connection.prototype.close = function () {
       this.socket && this.socket.close();
     };
   
     Connection.prototype.sendText = function (data) {
       this.isConnected() && this.socket.send(Connection.CHANNEL_TEXT + data + '\r\n');
     };
   
     Connection.prototype.sendBar = function (data) {
       this.isConnected() && this.socket.send(Connection.CHANNEL_BAR + data + '\r\n');
     };
   
     Connection.prototype.sendObject = function (data) {
       this.isConnected() && this.socket.send(Connection.CHANNEL_JSON + window.JSON.stringify(data));
     };
   
     Connection.prototype.onOpen = null;
     Connection.prototype.onError = null;
     Connection.prototype.onClose = null;
   
     Connection.prototype.onMessage = function (channel, data) {
       switch (channel) {
       case Connection.CHANNEL_TEXT:
         this.onText && this.onText(data);
         break;
   
       case Connection.CHANNEL_BAR:
         this.onBar && this.onBar(data);
         break;
   
       case Connection.CHANNEL_JSON:
         this.onObject && this.onObject(window.JSON.parse(data));
         break;
   
       case Connection.CHANNEL_HTML:
         this.onHTML && this.onHTML(data);
         break;
   
       case Connection.CHANNEL_PUEBLO:
         this.onPueblo && this.onPueblo(data);
         break;
       
       case Connection.CHANNEL_PROMPT:
         this.onPrompt && this.onPrompt(data);
         break;
  
       case Connection.CHANNEL_DO:
           data = data.replace(/[\r\n]+/g, '').trim();

           // console.log("request: " + data);

           if(data === "mobile on") {
              var obj = document.getElementById("output");
              document.querySelector('#terminal').style.bottom = "37px";
              document.querySelector('#buttonbar').style.display = 
                  "inline-block";
              obj.style.fontSize = "9pt";
              obj.scrollTop = obj.scrollHeight;
              get_xy_size();
           } else if(data === "mobile off") {
              var obj = document.getElementById("output");
              document.querySelector('#terminal').style.bottom = 0;
              document.querySelector('#buttonbar').style.display = "none";
              obj.style.fontSize = "10pt";
              obj.scrollTop = obj.scrollHeight;
              get_xy_size();
           } else if(data === "theme light") {
              document.querySelector('.ansi-37').style.color='black';
              document.getElementById('output').style.backgroundColor='white';
              document.getElementById('bar').style.backgroundColor='white';
              document.getElementById('input').style.backgroundColor = 'white';
              document.querySelector('#bar').style.borderBottom =
                  '1px solid black';
              document.querySelector('#terminal').style.background = 'white';
              document.querySelector('#input').style.color= 'black';
           } else if(data === "theme dark") {
              document.getElementById('output').style.backgroundColor=
                 '#131712';
              document.getElementById('bar').style.backgroundColor = '#131712';
              document.getElementById('input').style.backgroundColor='#131712';
              document.querySelector('#terminal').style.background = '#131712';
              document.querySelector('#bar').style.borderBottom=
                 '1px solid white';
              document.querySelector('.ansi-37').style.color  = 'white';
              document.querySelector('#input').style.color= 'white';
           } else if(data === "clear") {
              document.getElementById('output').innerHTML = ""
           } else if(data === "password") {
              sendCommand(window.prompt("Enter password","password"));
           } else {
              console.log("unknown do request: " + data);
           }
           break;
   
       default:
         window.console && window.console.log('unhandled message', data);
         return false;
       }
   
       return true;
     };
   
     Connection.prototype.onText = null;
     Connection.prototype.onClear = null;
     Connection.prototype.onBar = null;
     Connection.prototype.onObject = null;
     Connection.prototype.onHTML = null;
     Connection.prototype.onPueblo = null;
     Connection.prototype.onPrompt = null;
   
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
   
     // MU* terminal emulator.
     function Terminal(root) {
       this.root = root;
       
       if (root === null) {
         return null;
       }
       
       this.clear();
     }
   
     Terminal.PARSE_PLAIN = 0;
     Terminal.PARSE_CR = 1;
     Terminal.PARSE_ESC1 = 2;
     Terminal.PARSE_ESC2 = 3;
   
     Terminal.ANSI_NORMAL = 0;
     Terminal.ANSI_BRIGHT = 1;
     Terminal.ANSI_UNDERLINE = 4;
     Terminal.ANSI_BLINK = 5;
     Terminal.ANSI_INVERSE = 7;
     Terminal.ANSI_XTERM_FG = 38;
     Terminal.ANSI_XTERM_BG = 48;
   
     Terminal.DEFAULT_FG = 37;
     Terminal.DEFAULT_BG = 30;
     
     Terminal.UNCLOSED_TAGS = ['area', 'base', 'br', 'col', 'command', 'embed', 'hr', 'img',
             'input', 'keygen', 'link', 'menuitem', 'meta', 'param', 'source', 'track', 'wbr'];
   
   
     /////////////////////////////////////////////////////
     // ansi parsing routines
     
     Terminal.encodeState = function (state) {
       if (!state) {
         return '';
       }
   
       var classes = [];
   
       if (state[Terminal.ANSI_INVERSE]) {
         var value = state.fg;
         state.fg = state.bg;
         state.bg = value;
         
         value = state.fg256;
         state.fg256 = state.bg256;
         state.bg256 = value;
       }
       
       var fg = state.fg;
       var bg = state.bg;
       
       if (state[Terminal.ANSI_UNDERLINE]) {
         classes[classes.length] = 'ansi-' + Terminal.ANSI_UNDERLINE;
       }
   
       // make sure to avoid conflict with XTERM256 color's usage of blink (code 5)
       if (state.fg256) {
         classes[classes.length] = 'ansi-38-5-' + state.fg;
       } else {  
         if (state[Terminal.ANSI_BRIGHT]) {
           if (state[Terminal.ANSI_INVERSE]) {
             if (fg !== Terminal.DEFAULT_FG) {
               classes[classes.length] = 'ansi-' + fg;
             }
           } else {
             classes[classes.length] = 'ansi-1-' + fg;
           }
         } else if (fg !== Terminal.DEFAULT_FG) {
           classes[classes.length] = 'ansi-' + fg;
         }
       }
       
       if (state.bg256) {
         classes[classes.length] = 'ansi-48-5-' + state.bg;
       } else {
         if (state[Terminal.ANSI_BRIGHT]) {
           if (state[Terminal.ANSI_INVERSE]) {
             classes[classes.length] = 'ansi-1-' + (bg + 10);
           } else {
             if (bg !== Terminal.DEFAULT_BG) {
               classes[classes.length] = 'ansi-' + (bg + 10);
             }
           }
         } else if (bg !== Terminal.DEFAULT_BG) {
           classes[classes.length] = 'ansi-' + (bg + 10);
         }
       }
   
       if (state[Terminal.ANSI_BLINK] && !(state.fg256 || state.bg256)) {
         classes[classes.length] = 'ansi-' + Terminal.ANSI_BLINK;
       }
       
       return classes.join(' ');
     };
   
     Terminal.prototype.getANSI = function () {
       if (!this.ansiState) {
         this.ansiState = {
           fg: Terminal.DEFAULT_FG,
           bg: Terminal.DEFAULT_BG,
           fg256: false,
           bg256: false
         };
       }
   
       return this.ansiState;
     };
   
     Terminal.prototype.applyANSI = function (ansi) {
       switch (ansi.charCodeAt(ansi.length - 1)) {
       case 109: // m (SGR)
         var codes = ansi.substring(0, ansi.length - 1).split(';');
   
         var value, state;
         for (var ii = 0; (value = codes[ii]) !== undefined; ++ii) {
           if (value.length === 0) {
             // Empty is treated as the equivalent of 0.
             value = Terminal.ANSI_NORMAL;
           } else {
             value = parseInt(value);
           }
           
           state = this.getANSI();
           
           // check for xterm256 fg/bg first, fallback to standard codes otherwise
           if (state[Terminal.ANSI_XTERM_FG] && state[Terminal.ANSI_BLINK]) {
             if (value >= 0 && value <= 255) {
               state.fg = value;
               state.fg256 = true;
               state[Terminal.ANSI_XTERM_FG] = false;
               state[Terminal.ANSI_BLINK] = false;
             } else {
               // invalid xterm256, let's reset the ansi state due to bad codes
               this.ansiState = null;
             }
           } else if (state[Terminal.ANSI_XTERM_BG] && state[Terminal.ANSI_BLINK]) {
             if (value >= 0 && value <= 255) {
               state.bg = value;
               state.bg256 = true;
               state[Terminal.ANSI_XTERM_BG] = false;
               state[Terminal.ANSI_BLINK] = false;
             } else {
               // invalid xterm256, let's reset the ansi state due to bad codes
               this.ansiState = null;
             }
           } else {
             // detect regular ansi codes
             switch (value) {
             case Terminal.ANSI_NORMAL: // reset
               this.ansiState = null;
               break;
   
             case Terminal.ANSI_BRIGHT:
             case Terminal.ANSI_UNDERLINE:
             case Terminal.ANSI_BLINK:
             case Terminal.ANSI_INVERSE:
             case Terminal.ANSI_XTERM_FG:
             case Terminal.ANSI_XTERM_BG:
               state[value] = true;
               break;
   
             default:
               if (30 <= value && value <= 37) {
                 state.fg = value;
               } else if (40 <= value && value <= 47) {
                 state.bg = value - 10;
               }
              break;
             }
           }
   
           this.ansiDirty = true;
         }
         break;
       }
     };
   
     Terminal.prototype.write = function (value, start, end) {
       if (start === end) {
         return;
       }
   
       if (this.ansiDirty) {
         var next = Terminal.encodeState(this.ansiState);
   
         if (this.ansiClass !== next) {
           this.ansiClass = next;
           this.span = null;
         }
   
         this.ansiDirty = false;
       }
   
       if (this.ansiClass && !this.span) {
         this.span = document.createElement('span');
         this.span.className = this.ansiClass;
         this.stack[this.stack.length - 1].appendChild(this.span);
       }
   
       var text = document.createTextNode(value.substring(start, end));
       this.lineBuf[this.lineBuf.length] = text;
   
       this.appendChild(text);
     };
   
     Terminal.prototype.endLine = function () {
       var that = this;
       this.onLine && this.onLine(that, this.lineBuf);
   
       this.write('\n', 0, 1);
       this.lineBuf.length = 0;
     };
   
     Terminal.prototype.abortParse = function (value, start, end) {
       switch (this.state) {
       case Terminal.PARSE_PLAIN:
         this.write(value, start, end);
         break;
   
       case Terminal.PARSE_ESC1:
         this.write('\u001B', 0, 1);
         break;
   
       case Terminal.PARSE_ESC2:
         this.write('\u001B[', 0, 2);
         this.write(this.parseBuf, 0, this.parseBuf.length);
         this.parseBuf = '';
         break;
       }
     };
   
     /////////////////////////////////////////////////////
     // message appending routines
     
     // appends a text string to the terminal, parsing ansi escape codes into html/css
     Terminal.prototype.appendText = function (data) {
       var start = 0;
   
       // Scan for sequence start characters.
       // TODO: Could scan with RegExp; not convinced sufficiently simpler/faster.
       for (var ii = 0, ilen = data.length; ii < ilen; ++ii) {
         var ch = data.charCodeAt(ii);
   
         // Resynchronize at special characters.
         switch (ch) {
         case 10: // newline
           if (this.state !== Terminal.PARSE_CR) {
             this.abortParse(data, start, ii);
             this.endLine();
           }
   
           start = ii + 1;
           this.state = Terminal.PARSE_PLAIN;
           continue;
   
         case 13: // carriage return
           this.abortParse(data, start, ii);
           this.endLine();
           start = ii + 1;
           this.state = Terminal.PARSE_CR;
           continue;
   
         case 27: // escape
           this.abortParse(data, start, ii);
           start = ii + 1;
           this.state = Terminal.PARSE_ESC1;
           continue;
         }
   
         // Parse other characters.
         switch (this.state) {
         case Terminal.PARSE_CR:
           this.state = Terminal.PARSE_PLAIN;
           break;
   
         case Terminal.PARSE_ESC1:
           if (ch === 91) {
             // Start of escape sequence (\e[).
             start = ii + 1;
             this.state = Terminal.PARSE_ESC2;
           } else {
             // Not an escape sequence.
             this.abortParse(data, start, ii);
             start = ii;
             this.state = Terminal.PARSE_PLAIN;
           }
           break;
   
         case Terminal.PARSE_ESC2:
           if (64 <= ch && ch <= 126) {
             // End of escape sequence.
             this.parseBuf += data.substring(start, (start = ii + 1));
             this.applyANSI(this.parseBuf);
             this.parseBuf = '';
             this.state = Terminal.PARSE_PLAIN;
           }
           break;
         }
       }
   
       // Handle tail.
       switch (this.state) {
       case Terminal.PARSE_PLAIN:
         this.write(data, start, data.length);
         break;
   
       case Terminal.PARSE_ESC2:
         this.parseBuf += data.substring(start);
         break;
       }
     };
   
     Terminal.prototype.appendHTML = function (html) {
       var div = document.createElement('div');
       var fragment = document.createDocumentFragment();
   
       div.innerHTML = html;
   
       for (var child = div.firstChild; child; child = child.nextSibling) {
         var cmd = child.getAttribute('xch_cmd');
         if (cmd !== null && cmd !== '') {
           child.setAttribute('onClick', 'this.onCommand("' + cmd + '");');
           child.onCommand = this.onCommand;
           child.removeAttribute('xch_cmd');
         }
         fragment.appendChild(child);
       }
   
       this.appendChild(fragment);
     };
   
     // append an HTML fragment to the terminal
     Terminal.prototype.appendChild = function (fragment) {
       var last = (this.span || this.stack[this.stack.length - 1]);
       last.appendChild(fragment);
       
       this.scrollDown();
     };
     
     // append a log message to the terminal
     Terminal.prototype.appendMessage = function (classid, message) {
       var div = document.createElement('div');
       div.className = classid;
       
       // create a text node to safely append the string without rendering code
       var text = document.createTextNode(message);
       div.appendChild(text);
       
       this.appendChild(div);
     };
     
     // push a new html element onto the stack
     Terminal.prototype.pushElement = function (element) {
       this.span = null;
       this.stack[this.stack.length - 1].appendChild(element);
       this.stack[this.stack.length] = element;
     };
   
     // remove 1 level from the stack, check consistency 
     Terminal.prototype.popElement = function () {
       this.span = null;
   
       if (this.stack.length > 1) {
         --this.stack.length;
       } else {
         window.console && window.console.warn('element stack underflow');
       }
     };
   
     // append a pueblo tag to the terminal stack (or pop if an end tag)
     Terminal.prototype.appendPueblo = function (data) {
       var tag, attrs;
   
       var idx = data.indexOf(' ');
       if (idx !== -1) {
         tag = data.substring(0, idx);
         attrs = data.substring(idx + 1);
       } else {
         tag = data;
         attrs = '';
       }
       
       var html = '<' + tag + (attrs ? ' ' : '') + attrs + '>';
   
       var start;
       if (tag[0] !== '/') {
         start = true;
       } else {
         start = false;
         tag = tag.substring(1);
       }
       
       // detect a self closed tag
       var selfClosing = false;
       if ((tag.substring(-1) === '/') || (attrs.substring(-1) === '/')) {
         selfClosing = true;
       }
       
       if (Terminal.UNCLOSED_TAGS.indexOf(tag.toLowerCase()) > -1) {
         selfClosing = true;
       }
   
       if ((tag === 'XCH_PAGE') || 
           ((tag === 'IMG') && (attrs.search(/xch_graph=(("[^"]*")|('[^']*')|([^\s]*))/i) !== -1))) {
         //console.log("unhandled pueblo", html);
         return;
       }
   
       // we have a starting <tag> (not </tag>)
       if (start) {
         var div = document.createElement('div');
   
         html = html.replace(
           /xch_graph=(("[^"]*")|('[^']*')|([^\s]*))/i,
           ''
         );
   
         html = html.replace(
           /xch_mode=(("[^"]*")|('[^']*')|([^\s]*))/i,
           ''
         );
   
         html = html.replace(
           /xch_hint="([^"]*)"/i,
           'title="$1"'
         );
   
         div.innerHTML = html.replace(
           /xch_cmd="([^"]*)"/i,
           "onClick='this.onCommand(&quot;$1&quot;)'"
         );
         
         div.firstChild.onCommand = this.onCommand;
   
         div.setAttribute('target', '_blank');
         
         // add this tag to the stack to keep track of nested elements
         this.pushElement(div.firstChild);
   
         // automatically pop the tag if it is self closing
         if (selfClosing) {
           this.popElement();
         }
   
       } else {
         // we have an ending </tag> so remove the closed tag from the stack
         // don't bother for self closing tags with an explicit end tag, we already popped them
         if (!selfClosing) {
           this.popElement();
         }
       }
     };
     
     Terminal.prototype.clear = function() {
       this.root.innerHTML = '';
   
       this.stack = [this.root];
   
       this.state = Terminal.PARSE_PLAIN;
       this.line = null;
       this.lineBuf = [];
       this.span = null;
       this.parseBuf = '';
   
       this.ansiClass = '';
       this.ansiState = null;
       this.ansiDirty = false;
     };
     
     // animate scrolling the terminal window to the bottom
     Terminal.prototype.scrollDown = function() {
       // TODO: May want to animate this, to make it less abrupt.
       //this.root.scrollTop = this.root.scrollHeight;
       //return;
       
       var root = this.root;
       var scrollCount = 0;
       var scrollDuration = 500.0;
       var oldTimestamp = performance.now();
   
       function step (newTimestamp) {
         var bottom = root.scrollHeight - root.clientHeight;
         var delta = (bottom - root.scrollTop) / 2.0;
   
         scrollCount += Math.PI / (scrollDuration / (newTimestamp - oldTimestamp));
         if (scrollCount >= Math.PI) root.scrollTo(0, bottom);
         if (root.scrollTop === bottom) { return; }
         root.scrollTo(0, Math.round(root.scrollTop + delta));
         oldTimestamp = newTimestamp;
         window.requestAnimationFrame(step);
       }
       window.requestAnimationFrame(step);
     };
   
     // setup the pueblo xch_cmd callback
     Terminal.prototype.onCommand = null;
   
   
   
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
   
     // User input handler (command history, callback events)
     function UserInput(root) {
       var that = this;
       
       if (root === null) {
         return null;
       }
       
       this.root = root;
       
       this.clearHistory();
     
       this.root.onkeydown = function(evt) {
         UserInput.onkeydown(that, evt);
       };
       
       this.root.onkeyup = function(evt) {
         UserInput.onkeyup(that, evt);
       };
     }
     
     // clear the history for a given UserInput object
     UserInput.clearhistory = function(that) {
   
     };
     
     // passthrough to the local onKeyDown callback
     UserInput.onkeydown = function(that, evt) {
       that.onKeyDown && that.onKeyDown(evt);
     };
   
     // passthrough to the local onKeyUp callback
     UserInput.onkeyup = function(that, evt) {
       that.onKeyUp && that.onKeyUp(evt);
     };
     
     // set the default onKeyDown handler
     UserInput.prototype.onKeyDown = function(e) {
       PressKey(this, e);
     };
     
     // set the default onKeyUp handler
     UserInput.prototype.onKeyUp = function(e) {
       ReleaseKey(this, e);
     };
     
     UserInput.prototype.onEnter = null;
     UserInput.prototype.onEscape = null;
     
     // clear the command history
     UserInput.prototype.clearHistory = function() {
       this.history = [];
       this.ncommand = 0;
       this.save_current = '';
       this.current = -1;
     };
     
     // push a command onto the history list and clear the input box
     UserInput.prototype.saveCommand = function() {
       if (this.root.value !== '') {
         this.history[this.ncommand] = this.root.value;
         this.ncommand++;
         this.save_current = '';
         this.current = -1;
         this.root.value = '';
       }
     };
     
     // cycle the history backward
     UserInput.prototype.cycleBackward = function() {
       // save the current entry in case we come back
       console.log("cycle backwards");
       if (this.current < 0) {
         this.save_current = this.root.value;
       }
       
       // cycle command history backward
       if (this.current < this.ncommand - 1) {
         this.current++;
         this.root.value = this.history[this.ncommand - this.current - 1];
       }
     };
     
     // cycle the history forward
     UserInput.prototype.cycleForward = function () {
       // cycle command history forward
       console.log("cycle forwards");
       if (this.current > 0) {
         this.current--;
         this.root.value = this.history[this.ncommand - this.current - 1];
       } else if (this.current === 0) {
         // recall the current entry if they had typed something already
         this.current = -1;
         this.root.value = this.save_current;
       }
     };
     
     
     
     // move the input cursor to the end of the input elements current text
     UserInput.prototype.moveCursor = function() {
       if (typeof this.root.selectionStart === "number") {
           this.root.selectionStart = this.root.selectionEnd = this.root.value.length;
       } else if (typeof this.root.createTextRange !== "undefined") {
           this.focus();
           var range = this.root.createTextRange();
           range.collapse(false);
           range.select();
       }
     };
     
     
     
     // clear the current input text
     UserInput.prototype.clear = function() {
       this.root.value = '';
     };
     
     // get the current text in the input box
     UserInput.prototype.value = function() {
       return this.root.value;
     };
     
     // refocus the input box
     UserInput.prototype.focus = function() {
       var text = "";
       if (window.getSelection) {
         text = window.getSelection().toString();
       } else if (document.selection && document.selection.type != "Control") {
         text = document.selection.createRange().text;
       }
       
       if (text === "") {
         this.root.focus();
       }
     };
     
     // user-defined keys for command history
     UserInput.prototype.keyCycleForward = null;
     UserInput.prototype.keyCycleBackward = null;
    
     UserInput.ctl_u = function( that, key) {
        if(key.code === 85 && key.ctrl) {
           return 1;
        } else {
           return 0;
        }
     };

     UserInput.ctl_l = function( that, key) {
        if(key.code === 76 && key.ctrl) {
           return 1;
        } else {
           return 0;
        }
     };
 
     UserInput.isKeyCycleForward = function(that, key) {
       if (that && that.keyCycleForward) {
         return that.keyCycleForward(key);
       } else {
         // default key is ctrl+n
         return (key.code === 78 && key.ctrl);
       }
     };
     
     UserInput.isKeyCycleBackward = function (that, key) {
       if (that && that.keyCycleBackward) {
         return that.keyCycleBackward(key);
       } else {
         // default key is ctrl+p
         return (key.code === 80 && key.ctrl);
       }
     };
     
     
     
   
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     // some string helper functions for replacing links and user input tokens
   
     // Example onLine() handler that linkifies URLs in text.
     function LinkHandler(that, lineBuf) {
       // Merge text so we can scan it.
       if (!lineBuf.length) {
         return;
       }
   
       var line = '';
       for (var ii = 0, ilen = lineBuf.length; ii < ilen; ++ii) {
         line += lineBuf[ii].nodeValue;
       }
   
       // Scan the merged text for links.
       var links = LinkHandler.scan(line);
       if (!links.length) {
         return;
       }
   
       // Find the start and end text nodes.
       var nodeIdx = 0, nodeStart = 0, nodeEnd = lineBuf[0].nodeValue.length;
       for (var ii = 0, ilen = links.length; ii < ilen; ++ii) {
         var info = links[ii], startOff, startNode, endOff, endNode;
   
         while (nodeEnd <= info.start) {
           nodeStart = nodeEnd;
           nodeEnd += lineBuf[++nodeIdx].nodeValue.length;
         }
   
         startOff = info.start - nodeStart;
         startNode = lineBuf[nodeIdx];
   
         while (nodeEnd < info.end) {
           nodeStart = nodeEnd;
           nodeEnd += lineBuf[++nodeIdx].nodeValue.length;
         }
   
         endOff = info.end - nodeStart;
         endNode = lineBuf[nodeIdx];
   
         // Wrap the link text.
         // TODO: In this version, we won't try to cross text nodes.
         // TODO: Discard any text nodes that are already part of links?
         if (startNode !== endNode) {
           window.console && window.console.warn('link', info);
           continue;
         }
   
         lineBuf[nodeIdx] = endNode.splitText(endOff);
         nodeStart += endOff;
   
         var middleNode = startNode.splitText(startOff);
         var anchor = document.createElement('a');
         middleNode.parentNode.replaceChild(anchor, middleNode);
   
         anchor.target = '_blank';
         if (info.url === '' && info.xch_cmd !== '') {
           anchor.setAttribute('onClick', 'this.onCommand("'+info.xch_cmd+'");');
           anchor.onCommand = that.onCommand;
         } else {
           anchor.href = info.url;
         }
         anchor.appendChild(middleNode);
       }
     }
   
     // Link scanner function.
     // TODO: Customizers may want to replace this, since regular expressions
     // ultimately limit how clever our heuristics can be.
     LinkHandler.scan = function (line) {
       var links = [], result;
   
       LinkHandler.regex.lastIndex = 0;
       while ((result = LinkHandler.regex.exec(line))) {
         var info = {};
   
         info.start = result.index + result[1].length;
         info.xch_cmd = '';
         if (result[2]) {
           result = result[2];
           info.url = result;
         } else if (result[3]) {
           result = result[3];
           info.url = 'mailto:' + result;
         } else if (result[4]) {
           result = result[4];
           info.url = '';
           info.xch_cmd = 'help ' + result;
           info.className = "ansi-1-37";
         }
   
         info.end = info.start + result.length;
   
         links[links.length] = info;
       }
   
       return links;
     };
   
     // LinkHandler regex:
     //
     // 1. Links must be preceded by a non-alphanumeric delimiter.
     // 2. Links are matched greedily.
     // 3. URLs must start with a supported scheme.
     // 4. E-mail addresses are also linkified.
     // 5. Twitter users and hash tags are also linkified.
     //
     // TODO: This can be improved (but also customized). One enhancement might be
     // to support internationalized syntax.
     LinkHandler.regex = /(^|[^a-zA-Z0-9]+)(?:((?:http|https):\/\/[-a-zA-Z0-9_.~:\/?#[\]@!$&'()*+,;=%]+[-a-zA-Z0-9_~:\/?#@!$&*+;=%])|([-.+a-zA-Z0-9_]+@[-a-zA-Z0-9]+(?:\.[-a-zA-Z0-9]+)+)|(@[a-zA-Z]\w*))/g;
   
     // set the default line handler for the terminal to use the LinkHandler
     Terminal.prototype.onLine = LinkHandler;
   
     // detect if more user input is required for a pueblo command
     function ReplaceToken(command) {
       var cmd = command;
       var regex = /\?\?/;
       
       // check for the search token '??'
       if (cmd.search(regex) !== -1) {
         var val = prompt(command);
         
         if (val === null) {
           // user cancelled the prompt, don't send any command
           cmd = '';
         } else {
           // replace the ?? token with the prompt value
           cmd = cmd.replace(regex, val);
         }
       }
       
       return cmd;
     };
   
   
   
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
   
     // default handler for key press events
     function PressKey(that, e) {
       var key = { code: (e.keyCode ? e.keyCode : e.which),
                   ctrl: e.ctrlKey,
                   shift: e.shiftKey,
                   alt: e.altKey };
   
       var prevent = true;
//       console.log('key: ' + key.code);
      
       if(UserInput.ctl_u(that,key)) {
          that.root.value = '';
       } else if(UserInput.ctl_l(that,key)) {
          that.onEnter('/key_ctl_l\r\n');
       } else if (UserInput.isKeyCycleBackward(that, key)) {
         console.log('cycle backwards');
         // cycle history backward
         that.cycleBackward();
       } else if (UserInput.isKeyCycleForward(that, key)) {
         // cycle history forward
         console.log('cycle forward');
         that.cycleForward();
   
       } else if (key.code === 13) {
         // enter key
         
         // save the command string and clear the input box
         var cmd = that.root.value;
         that.saveCommand();
   
         // pass through to the local callback for sending data
         that.onEnter && that.onEnter(cmd);
           
       } else if (key.code === 27) {
   
         // pass through to the local callback for the escape key
   //      that.onEscape && that.onEscape();
   
   //    } else if  (that.last_key === 27 && key.code === 119) {
       } else if (that.last_key == 27 && key.code === 87) {
         that.onEnter('/key_esc_w\r\n');
       } else if  (that.last_key == 27 && key.code === 76) {
         that.onEnter('/key_ctl_l\r\n');
       } else if (key.code === 9) {
         that.onEnter('/key_tab\r\n');
       } else if (key.code === 38) {
         that.onEnter('/key_up\r\n' );
       } else if (key.code === 40) {
         that.onEnter('/key_down\r\n');
       } else if (key.code === 34) {
         that.onEnter('/key_pgdn\r\n');
       } else if (key.code === 33) {
         that.onEnter('/key_pgup\r\n');
       } else { 
         // didn't capture anything, pass it through
         prevent = false;
   
       }
       
       that.last_key = key.code; 
   
       if (prevent) {
         e.preventDefault();
       }
   
       // make sure input retains focus
       that.focus();
     };
   
   
   
     // default handler for key release events
     function ReleaseKey(that, e) {
       var key = { code: (e.keyCode ? e.keyCode : e.which),
                   ctrl: e.ctrlKey,
                   shift: e.shiftKey,
                   alt: e.altKey };
   
       if (UserInput.isKeyCycleBackward(that, key) ||
           UserInput.isKeyCycleForward(that, key)) {
   
         // move the cursor to end of the input text after a history change
         that.moveCursor();
       }
     };
   
   
   
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
     //////////////////////////////////////////////////////////////////
   
     // Module exports.
     var exports = {};
   
     // open a websocket connection to url
     exports.connect = function (url) {
       return new Connection(url);
     };
   
     // create a terminal emulator that appends output to root
     exports.output = function (root) {
       return new Terminal(root);
     };
     
     // create an input handler that saves and recalls command history
     exports.input = function (root) {
       return new UserInput(root);
     };
     
     // default key event callback handlers
     exports.pressKey = PressKey;
     exports.releaseKey = ReleaseKey;
     
     // helper for replacing ?? in string with user input
     exports.parseCommand = ReplaceToken;
     
     // export the LinkHandler just in case it's useful elsewhere
     exports.parseLinks = LinkHandler;
   
    return exports;
   })(window, document);
START: muddler_client.html
   <!DOCTYPE html>
   <html><head><meta name="viewport" content="width=device-width, maximum-scale=1" charset="UTF-8">


   
   <link rel="stylesheet" href="muddler_ansi.css">
   <link rel="stylesheet" href="muddler_style.css">
   <base target="_blank">
   <title>Muddler</title></head>
   
   <body onLoad="input.focus()"
          setTimeout(conn.close, 1000);"
         onClick="input.focus()">
   
   <div id="terminal">
     <div id="output" class="ansi-37 ansi-40"></div>
     <div id="bar" class="ansi-37 ansi-1-37"></div>
     <div id="prompt" class="ansi-37 ansi-1-37"></div>
     <textarea id="input" autocomplete="off" autofocus></textarea>
   </div>
     <div id="buttonbar" "class=buttonbar" style=width:100%>
         <button style="display:inline-block;width:25%;height:35px;border: 1px solid black;border-width:1px 0px 1px 1px;padding:0;float:left" onclick="input.onEnter('/key_pgup 5')">PgUP</button>
         <button style="display:inline-block;width:25%;height:35px;border: 1px solid black;border-width:1px 0px 1px 1px;padding:0;float:left" onclick="input.onEnter('/key_pgdn 5')">PgDN</button>
         <button style="display: inline-block;width:25%;height:35px;border: 1px solid black;border-width:1px 0px 1px 1px;padding 0;float:left" onclick="input.onEnter('/key_up')">NextWld</button>
         <button style="display: inline-block;width:25%;height:35px;border: 1px solid black;border-width:1px 1px 1px 1px;padding 0;float:left" onclick="input.onEnter('/key_down')">PrevWld</button>
     </div>
     </div class=triangle>
        <div class="inner-triangle" onclick="input.onEnter('/mobile')"><span>muddler</span></div>
        <div class="outer-triangle"></div>
     </div>
   
   <script type="text/javascript" src="muddler_client.js"></script>
   <script type="text/javascript">
     var serverAddress = window.location.hostname;
     var serverSSL = window.location.protocol == "https:";
     var serverProto = serverSSL ? "wss://" : "wss://";
     var serverPort = serverSSL ? '9001' : '9001';
     
     var customUrl = window.location.search.substring(1) ? window.location.search.substring(1) : serverAddress + ":" + serverPort;
     // The connection URL is ws://host:port/wsclient (or wss:// for SSL connections)
   //  var serverUrl = serverProto + customUrl + '/wsclient'
     var serverUrl = serverProto + customUrl + '/connect'
     // define the input box, output terminal, and network connection
     var output = WSClient.output(document.getElementById('output'));
     var cmdprompt = WSClient.output(document.getElementById('prompt'));
     var bar = WSClient.output(document.getElementById('bar'));
     var input = WSClient.input(document.getElementById('input'));
     var conn = WSClient.connect(serverUrl);
     // function to send a command string to the server
     function sendCommand(cmd) {
       if (conn.isConnected()) {
         if (cmd !== '') {
           conn.sendText(cmd);
   //        output.appendMessage('localEcho', cmd);
         }
       } else {
         // connection was broken, let's reconnect
         conn.reconnect();
         output.appendMessage('logMessage', '%% Reconnecting to server...');
       }
     }
  
     function get_xy_size() {
         var out = document.getElementById('output')
         var css = getComputedStyle(out,null);
         var ff  = css.getPropertyValue("font-family");
         var fs  = css.getPropertyValue("font-size");
   
         var temp = document.createElement('span');
         temp.style = "margin:0px;padding:0px;font-family:"+ff+
                       ";font-size:"+fs;
         temp.innerText = "0123456789";
         var element = document.body.appendChild(temp);
         var out = document.getElementById('output');
         var x = Math.round(out.offsetHeight / temp.offsetHeight);
         var y = Math.round(out.offsetWidth / (temp.offsetWidth / 10));
         temp.parentNode.removeChild(temp);
         return x + "," + y;
     }
   
     
     // just log a standard message on these socket status events
     conn.onOpen = function (evt) { 
         output.appendMessage('logMessage', '%% Connected.');
         sendCommand('#-# world WORLD_NAME #-#\r\n');
         // sendCommand(window.prompt("Enter password","xyzzy"));
     };
     conn.onError = function (evt) { output.appendMessage('logMessage', '%% Connection error!'); console.log(evt); };
     conn.onClose = function (evt) { output.appendMessage('logMessage', '%% Connection closed.'); };
     // handle incoming text, html, pueblo, or command prompts
   
   //        conn.onMessage = function (code,text) {
    //              output.appendText('### ' + code + ' : ' + text);
     //      };
   
     conn.onText = function (text) { output.appendText(text); };
     conn.onHTML = function (html) { output.appendHTML(html); };
     conn.onPueblo = function (html) { output.appendPueblo(html); };
     conn.onBar = function (text) { bar.clear();bar.appendText(text); };
     conn.onPrompt = function (text) { cmdprompt.clear(); cmdprompt.appendText(text + '\r\n'); };
     
     // handle incoming JSON objects. requires server specific implementation
     conn.onObject = function (obj) { console.log('unhandled JSON object' + obj); };
     // pueblo command links, prompt for user input and replace ?? token if present
     output.onCommand = function(cmd) { sendCommand(WSClient.parseCommand(cmd)); };
     // enter key passthrough from WSClient.pressKey
     input.onEnter = function(cmd) { sendCommand(cmd); };
     
     // escape key passthrough from WSClient.pressKey
     input.onEscape = function () { this.clear(); };
     
     // input key event callbacks. here we show the defaults
     // provided by WSClient.pressKey and WSClient.releaseKey
     // input.onKeyDown = function(e) { WSClient.pressKey(this, e); };
     // input.onKeyUp = function(e) { WSClient.releaseKey(this, e); };
     
     // which keys are used for cycling through command history?
     // here we show the default keys, ctrl+p and ctrl+n
     // input.keyCycleForward = function(key) { return (key.code === 78 && key.ctrl); }; // ctrl+n
     // input.keyCycleBackward = function(key) { return (key.code === 80 && key.ctrl); }; // ctrl+p
     
   </script>
   
   </body>
   </html>
