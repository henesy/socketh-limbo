implement SocketH;

include "sys.m";
	sys: Sys;

include "dial.m";
	dial: Dial;

include "draw.m";
include "arg.m";

SocketH: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};


maxmsg:		con int			256;	# Max message size in bytes
maxconns:	con int 		100;	# Max clients
maxusrname:	con int			25;		# Max username length
maxbuf:		con int			8;		# Max channel buffer size
stderr:		ref sys->FD;			# Stderr shortcut

chatty:		int				= 0;	# Verbose debug output
broadcast:	chan of string;			# Input for message broadcast
pool:		chan of ref Sys->FD;	# Input for adding connections


# An implementation of the SocketH chat protocol
init(nil: ref Draw->Context, argv: list of string) {
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		raise "could not load arg";
	dial = load Dial Dial->PATH;
	if(dial == nil)
		raise "could not load dial";

	stderr = sys->fildes(2);

	broadcast = chan[maxbuf] of string;
	pool = chan[maxbuf] of ref Sys->FD;

	addr: string = "tcp!*!9090";

	# Commandline flags

	arg->init(argv);
	arg->setusage("socketh [-D] [-a addr]");

	while((c := arg->opt()) != 0)
		case c {
		'D' =>
			chatty++;

		'a' =>
			addr = arg->earg();

		* =>
			arg->usage();
		}

	argv = arg->argv();

	# Network listening

	spawn manager();

	ac := dial->announce(addr);
	if(ac == nil){
		err := sys->sprint("err: could not announce - %r");
		raise err;
	}

	for(;;){
		listener := dial->listen(ac);
		if(listener == nil){
			err := sys->sprint("err: could not listen - %r");
			raise err;
		}

		conn := dial->accept(listener);
		if(conn == nil){
			err := sys->sprint("err: could not accept - %r");
			raise err;
		}

		spawn handler(conn);
	}

	exit;
}

# Manage connections and messages
manager() {
	conns := array[maxconns] of ref Sys->FD;

	loop:
	for(;;)
		alt{
			fd := <- pool =>
				# Add a new connection
				for(i := 0; i < len conns; i++) {
					if(conns[i] != nil)
						continue;

					conns[i] = fd;
					continue loop;
				}

				sys->fprint(stderr, "fail: max conns reached");

			msg := <- broadcast =>
				msg += "\n";
				sys->print("%s", string msg);

				# Incoming message to chat
				for(i := 0; i < len conns; i++) {
					if(conns[i] == nil)
						continue;

					buf := array of byte msg;

					sys->write(conns[i], buf, len buf);
				}

			* =>
				sys->sleep(5);
		}
}

# Handle a connection
handler(conn: ref Sys->FD) {
	sprint: import sys;
	namebuf := array[maxmsg] of byte;
	s := array of byte "What is your username?: ";

	sys->write(conn, s, len s);
	n := sys->read(conn, namebuf, len namebuf);

	username := minimize(string namebuf[:n]);

	broadcast <-= sprint("→ %s", username);

	pool <-= conn;

	loop:
	for(;;){
		buf := array[maxmsg] of byte;
		n = sys->read(conn, buf, len buf);
		msg := minimize(string buf[:n]);

		# EOF
		if(n == 0){
			break loop;
		}

		# Error
		if(n < 0){
			sys->fprint(stderr, "fail: connection ended - %r");
			break loop;
		}

		case msg {
		"!quit" => 
			break loop;

		* =>
			broadcast <-= sprint("%s → %s", username, msg);
		}

		sys->sleep(1);
	}

	broadcast <-= sprint("← %s", username);
}

# Truncate up to and not including {\n \r}
minimize(s: string): string {
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == '\r')
			break;

	return s[:i];
}
