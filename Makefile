PROJECT = etorrent_core

DEPS = gproc lager hackney lhttpc cowboy rlimit azdht mdns upnp
TEST_DEPS = meck proper

dep_gproc = https://github.com/uwiger/gproc.git master
dep_lager = https://github.com/basho/lager.git 2.0.0
dep_hackney = https://github.com/benoitc/hackney.git master
dep_lhttpc = https://github.com/esl/lhttpc.git master
dep_meck = https://github.com/eproxus/meck.git master
dep_proper = https://github.com/manopapad/proper.git master
dep_cowboy = https://github.com/extend/cowboy.git master
dep_rlimit = https://github.com/jlouis/rlimit.git master
dep_azdht = https://github.com/jlouis/azdht.git master
dep_mdns = https://github.com/jlouis/mdns.git master
dep_upnp = https://github.com/jlouis/upnp.git master

ERLC_OPTS = +debug_info +'{parse_transform, lager_transform}'

include erlang.mk
