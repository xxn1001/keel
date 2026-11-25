CC ?= cc
CFLAGS ?= -O2 -std=c99 -Wall -Wextra -Werror
CPPFLAGS ?=
LDFLAGS ?=

CPPFLAGS += -I../lib
SOURCES = main.c ../lib/keel/proc.c ../lib/keel/fs.c ../lib/keel/mount.c
HEADERS = installer.h ../lib/keel/proc.h ../lib/keel/fs.h ../lib/keel/mount.h

all: keel-install

keel-install: $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS)

clean:
	rm -f keel-install

.PHONY: all clean
