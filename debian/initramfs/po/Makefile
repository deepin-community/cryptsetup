XGETTEXT = xgettext
MSGFMT = msgfmt
MSGMERGE = msgmerge

LOCALEDIR = /usr/share/locale

.SUFFIXES: .po .mo .pot

%.mo: %.po
	$(MSGFMT) -o $@ $<

PO = $(wildcard *.po)
LANG = $(basename $(PO))
MO = $(addsuffix .mo,$(LANG))
SOURCES = ../scripts/local-top/cryptroot

all: update $(MO)
update: cryptroot.pot
	-@for po in $(PO); do \
	echo -n "Updating $$po"; \
	$(MSGMERGE) -U $$po cryptroot.pot; \
	done;

cryptroot.pot: $(SOURCES)
	$(XGETTEXT) -c -L Shell --keyword=get_loc_str \
	-o $@ $(SOURCES)

install: all
	for i in $(MO) ; do \
	  t=$(DESTDIR)/$(LOCALEDIR)/`basename $$i .mo`/LC_MESSAGES ;\
	  install -d $$t ;\
	  install -m 644 $$i $$t/cryptroot.mo ;\
	done

clean:
	$(RM) $(MO) *~

.PHONY: update
