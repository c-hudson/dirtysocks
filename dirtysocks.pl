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
use strict;
use Carp;
use IO::Select;
use IO::Socket;
use Net::WebSocket::Server;
use Errno qw(EINTR EIO :POSIX);
my ($listener,$websock,$http,%sock,%conf,%mapping,%dos,$tmp);

#---[ http routines ]------------------------------------------------------#

#
# http_init
#    Turn on the listening on the http socket and tell the listener
#    to monitor it.
#
sub http_init
{
   $http = IO::Socket::INET->new(LocalPort => @conf{http_port},
                                 Listen    =>1,
                                 Reuse     =>1
                                );
   $listener->{select_readable}->add($http);
}

#
# http_accept
#    Someone is attempting to connect, lets accept it.
#
sub http_accept
{
   my $s = shift;

   my $new = $http->accept();

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
      if(defined @conf{"remote.$$data{get}"}) {        # which config to use 
        # if multiple people connect from the same ip to different
        # servers, this mapping could be wrong... but I haven't figured out
        # a better way of dealing with things.
        @mapping{@sock{$s}->{addr}} = { instance => $$data{get},
                                        time     => time(),
                                      };
        $$data{get} = "index.html";
      }

      if(defined $$data{get} && !-e $$data{get}) {
         http_error($s,"Page not found.");            # file doesn't exist
      } elsif(defined $$data{get} && $$data{get} =~ /\.([^.]+)$/) {
         my $type = $1;
         if($$data{get} eq "index.html" && 
            @conf{grapenutfix} =~ /^\s*(y|yes)\s*$/) {
            $page = join("\n",grapenutfix(get_file($$data{get})));
         } else {
            $page = join("\n",get_file($$data{get}));
            $page =~ s/WEBSOCK_PORT/@conf{websock_port}/g;
         }
         http_reply($s,"200 Default Request",$type,$page);
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


#---[ websocket ]----------------------------------------------------------#

#
# websock_init
#    Start listening on the websocket port and create the listener.
#
sub websock_init
{
   $websock = IO::Socket::INET->new( Listen    => 5,
                                     LocalPort => @conf{websock_port},
                                     Proto     => 'tcp',
                                     Domain    => AF_INET,
                                     ReuseAddr => 1,
                                   )
   or die "failed to set up TCP listener: $!";

   $listener= Net::WebSocket::Server->new(          # start websocket server
      listen => $websock,
      tick_period => 1,
      on_connect => 
         sub { my( $serv, $conn ) = @_;
               $conn->on( ready      => sub { telnet_open(@_);       },
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

   if($msg =~ /^t/) {            # grapenut messages should all start with 't'
      my $s = @sock{$conn}->{telnet};       # so send it to the telnet socket
      printf($s "%s",$');
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
   my $s = shift;

   for my $key (keys %mapping) {               # clean up orphaned mappings
      delete @mapping{$key} if(time() - @mapping{$key}->{time} > 600);
   }

   if(is_DOS($s)) {                                        # check for DOS
      return err($s,"To many connections attempted by you or everyone");
   }

   if(!defined @sock{$s} ||
      !@sock{$s}->{host} ||
      !defined @mapping{@sock{$s}->{host}} ||
      !defined @mapping{@sock{$s}->{host}}->{instance}) {
      return err($s,"Previous http call required to specify remote server");
   }

   my $instance = @mapping{@sock{$s}->{host}}->{instance};

   if(!defined @conf{"remote.$instance"}) {
     return err($s,"Invalid instance '$instance' specified");
   }

   my $inst = @conf{"remote.$instance"};

   my $new = IO::Socket::INET->new(Proto=>'tcp',            # create socket
                                   Type => SOCK_STREAM,
                                   blocking=>0,
                                   Timeout => 2) ||
      return err($s,"Could not open socket");
   my $addr = inet_aton($$inst{host}) ||
      return err($s,"Invalid hostname '%s' specified.",$$inst{host});
   my $sockaddr = sockaddr_in($$inst{port}, $addr) ||
      return err($s,"Could not find remote server.");

   delete @mapping{@sock{$s}->{host}};            # mapping no longer needed

   connect($new,$sockaddr) or                        # start connect to host
      $! == EWOULDBLOCK or $! == EINPROGRESS or           # and check status
      return err($s,"Could not open connection. $!");

   @sock{$new} = { type    => "telnet",                     # hook up socket
                   websock => $s,
                   pending => 0,
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
# grapenutfix
#    A few minor changes need to be done for grapenet's webclient
#
#    1. Change the server address to whatever it is detected at
#       by the broswer. We could populate this with a real value,
#       but this is easier.
#
#    2. Change the port being used to what is defined in the config
#       file. Easy peezey.
#
sub grapenutfix
{
   my @file = @_;

   for my $i (0 .. $#file) {
      if(@file[$i] =~ /^\s*var serverAddress/) {
         @file[$i] = "var serverAddress = window.location.hostname;";
      } elsif(@file[$i] =~ /^\s*var serverPort/) {
         @file[$i] = "var serverPort = serverSSL ? '@conf{websock_port}'" .
            " : '@conf{websock_port}'";
      }
   }
   return @file;
}

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
      } elsif($line =~ /^\s*([^ ]+)\s*:\s*/ && $1 ne "remote") {
         @conf{$1} = trim($');
      } elsif($line =~ /^\s*remote\s*:\s*/) {
         my (@data) = split(',',trim($'));
         @conf{"remote." . trim(lc(@data[0]))} = {
            host => @data[1],
            port => @data[2]
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

   for my $key ("websock_port",
               "http_port",
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

#
# server_io
#    Handle any input/output coming into the server.
#
sub server_io
{
   my ($line,$buf);

#   printf("server_io: start\n");
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
                $line =~ tr/\x80-\xFF//d;
                @sock{$s}->{websock}->send('',"t$line\n");
            }
         }
      }
   }
#   printf("server_io: end\n");
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

printf("# Listening: HTTP(%d), WEBSOCK(%d)\n",
   @conf{http_port},@conf{websock_port});

while(1) {
#   eval {
      server_io();
#   };
}
