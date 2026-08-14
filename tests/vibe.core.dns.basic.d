/+ dub.sdl:
	name "tests"
	description "DNS resolver integration test"
	copyright "Copyright © 2025, Sönke Ludwig"
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.core;
import vibe.core.dns;
import vibe.core.log;

void main()
{
	runTask({
		scope (exit) exitEventLoop();

		try {
			auto txt = lookupTXT("google.com");
			assert(txt.length > 0, "google.com should have TXT records");
			logInfo("TXT ok: %s", txt);

			auto srv = lookupSRV("_xmpp-server._tcp.jabber.org");
			assert(srv.length > 0, "jabber.org should have an XMPP SRV record");
			assert(srv[0].port > 0, "an SRV record carries a port");
			assert(srv[0].target.length > 0, "an SRV record carries a target host");
			logInfo("SRV ok: %s", srv);
		} catch (Exception e) {
			logInfo("DNS integration test skipped (no network?): %s", e.msg);
		}
	});

	runApplication();
}
